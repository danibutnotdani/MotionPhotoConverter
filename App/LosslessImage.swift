import CoreGraphics
import Foundation
import ImageIO

/// Agrega el ContentIdentifier de Apple (MakerApple 17) sin tocar la imagen: los datos de imagen, el mapa
/// HDR y todo lo demás se copian byte por byte; solo se reemplaza el bloque EXIF por uno igual + el identificador.
/// El EXIF nuevo lo genera ImageIO sobre una imagen de 1×1 con los mismos metadatos.
enum LosslessImage {
    static func write(_ data: Data, imageEnd: Int, id: String, type: CFString, to url: URL) throws {
        let image = data.prefix(imageEnd)
        guard let exif = try newExif(from: data, id: id, type: type) else { throw LivePhotoMaker.Failure.imageWrite }
        let out: Data
        switch type as String {
        case "public.heic", "public.heif": out = try heic(Data(image), exif: exif)
        case "public.jpeg": out = try jpeg(Data(image), app1: exif)
        default: throw LivePhotoMaker.Failure.imageWrite
        }
        try out.write(to: url)
    }

    /// EXIF de una imagen 1×1 con los metadatos del original + MakerApple 17 (HEIC: payload del ítem Exif; JPEG: segmento APP1).
    private static func newExif(from data: Data, id: String, type: CFString) throws -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let pixel = ctx.makeImage() else { return nil }
        var apple = (props[kCGImagePropertyMakerAppleDictionary] as? [String: Any]) ?? [:]
        apple["17"] = id
        props[kCGImagePropertyMakerAppleDictionary] = apple
        let tiny = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(tiny, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, pixel, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let bytes = tiny as Data
        return (type as String) == "public.jpeg" ? JPEG.segments(bytes).first(where: JPEG.isExif(bytes)).map { bytes.subdata(in: $0) }
                                                 : try HEIF(bytes).exifItem().map { bytes.subdata(in: $0.range) }
    }

    private static func heic(_ image: Data, exif: Data) throws -> Data {
        let heif = try HEIF(image)
        guard let item = try heif.exifItem() else { throw LivePhotoMaker.Failure.imageWrite }
        var out = image
        // El EXIF nuevo va en un mdat extra al final; el iloc del ítem Exif apunta ahí.
        let newOffset = out.count + 8
        guard newOffset <= Int(UInt32.max) else { throw LivePhotoMaker.Failure.imageWrite }
        out.write(be: UInt64(newOffset), at: item.offsetField, size: item.offsetSize)
        out.write(be: UInt64(exif.count), at: item.lengthField, size: item.lengthSize)
        var box = Data(); box.append(be: UInt32(8 + exif.count)); box.append(contentsOf: Array("mdat".utf8)); box.append(exif)
        return out + box
    }

    private static func jpeg(_ image: Data, app1: Data) throws -> Data {
        guard let old = JPEG.segments(image).first(where: JPEG.isExif(image)) else { throw LivePhotoMaker.Failure.imageWrite }
        var out = image
        out.replaceSubrange(old, with: app1)
        return out
    }
}

/// Lo mínimo de HEIF (ISO BMFF) para hallar el ítem Exif y su entrada en iloc.
struct HEIF {
    struct Item { var range: Range<Int>; var offsetField: Int; var offsetSize: Int; var lengthField: Int; var lengthSize: Int }
    let d: Data
    init(_ d: Data) throws { self.d = d }

    /// Hasta antes del video de Samsung (cajas `mpvd`/`sefd`, que van al final).
    static func imageEnd(_ d: Data) -> Int? {
        let h = HEIF(unchecked: d)
        return h.boxes(0, d.count).first { $0.type == "mpvd" || $0.type == "sefd" }?.start
    }
    init(unchecked d: Data) { self.d = d }

    func u(_ at: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 << 8 | Int(d[d.startIndex + at + $1]) } }

    func boxes(_ start: Int, _ end: Int) -> [(type: String, start: Int, size: Int, header: Int)] {
        var out: [(String, Int, Int, Int)] = [], p = start
        while p + 8 <= end {
            var size = u(p, 4), header = 8
            if size == 1 { size = u(p + 8, 8); header = 16 }
            if size == 0 { size = end - p }
            guard size >= 8, p + size <= end else { break }
            out.append((String(decoding: d[(d.startIndex + p + 4)..<(d.startIndex + p + 8)], as: UTF8.self), p, size, header))
            p += size
        }
        return out
    }

    func exifItem() throws -> Item? {
        guard let meta = boxes(0, d.count).first(where: { $0.type == "meta" }) else { return nil }
        let kids = boxes(meta.start + meta.header + 4, meta.start + meta.size)
        guard let iinf = kids.first(where: { $0.type == "iinf" }), let iloc = kids.first(where: { $0.type == "iloc" }) else { return nil }
        // iinf → id del ítem de tipo Exif.
        let iinfVersion = u(iinf.start + iinf.header, 1)
        var exifId: Int?
        for infe in boxes(iinf.start + iinf.header + 4 + (iinfVersion == 0 ? 2 : 4), iinf.start + iinf.size) where infe.type == "infe" {
            let v = u(infe.start + infe.header, 1)
            guard v >= 2 else { continue }
            let idSize = v == 2 ? 2 : 4, at = infe.start + infe.header + 4
            if String(decoding: d[(d.startIndex + at + idSize + 2)..<(d.startIndex + at + idSize + 6)], as: UTF8.self) == "Exif" { exifId = u(at, idSize) }
        }
        guard let exifId else { return nil }
        // iloc → dónde están sus bytes (un solo tramo, en el archivo).
        var p = iloc.start + iloc.header
        let version = u(p, 1); p += 4
        let offsetSize = u(p, 1) >> 4, lengthSize = u(p, 1) & 0xF, baseSize = u(p + 1, 1) >> 4, indexSize = version > 0 ? u(p + 1, 1) & 0xF : 0
        p += 2
        let count = u(p, version < 2 ? 2 : 4); p += version < 2 ? 2 : 4
        for _ in 0..<count {
            let itemId = u(p, version < 2 ? 2 : 4); p += version < 2 ? 2 : 4
            let method = version > 0 ? u(p, 2) & 0xF : 0; if version > 0 { p += 2 }
            p += 2 // data_reference_index
            let base = u(p, baseSize); p += baseSize
            let extents = u(p, 2); p += 2
            for e in 0..<extents {
                p += indexSize
                let offsetField = p, offset = u(p, offsetSize); p += offsetSize
                let lengthField = p, length = u(p, lengthSize); p += lengthSize
                if itemId == exifId, e == 0 {
                    guard extents == 1, method == 0, base == 0, offsetSize >= 4, lengthSize >= 4 else { return nil }
                    return Item(range: (base + offset)..<(base + offset + length), offsetField: offsetField, offsetSize: offsetSize,
                                lengthField: lengthField, lengthSize: lengthSize)
                }
            }
        }
        return nil
    }
}

enum JPEG {
    /// Rangos de los segmentos de cabecera (de cada marcador hasta el inicio de los datos de imagen).
    static func segments(_ d: Data) -> [Range<Int>] {
        var out: [Range<Int>] = [], p = 2
        let b = [UInt8](d)
        while p + 4 <= b.count, b[p] == 0xFF, b[p + 1] != 0xDA {
            let len = Int(b[p + 2]) << 8 | Int(b[p + 3])
            out.append(p..<(p + 2 + len)); p += 2 + len
        }
        return out
    }
    static func isExif(_ d: Data) -> (Range<Int>) -> Bool {
        { r in r.count > 10 && d[d.startIndex + r.lowerBound + 1] == 0xE1 && d.subdata(in: (r.lowerBound + 4)..<(r.lowerBound + 8)) == Data("Exif".utf8) }
    }
}

extension Data {
    mutating func write(be value: UInt64, at offset: Int, size: Int) {
        for i in 0..<size { self[startIndex + offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(size - 1 - i))) }
    }
    mutating func append(be value: UInt32) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
}
