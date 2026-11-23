import AVFoundation
import Foundation
import ImageIO

/// Convierte una Motion Photo de Samsung (HEIC/JPEG con un MP4 pegado al final) en el par de archivos
/// que Fotos reconoce como Live Photo: la misma imagen con el ContentIdentifier de Apple en su MakerNote
/// y un .MOV con ese identificador y la marca de "foto fija".
enum LivePhotoMaker {
    enum Failure: LocalizedError {
        case noVideo, unreadableImage, imageWrite, videoWrite(String)
        var errorDescription: String? {
            switch self {
            case .noVideo: "No trae video: no es Motion Photo"
            case .unreadableImage: "No se pudo leer la imagen"
            case .imageWrite: "No se pudo escribir la imagen"
            case .videoWrite(let m): "No se pudo escribir el video: \(m)"
            }
        }
    }

    /// Bytes del MP4 incrustado: el primer "ftyp" de video después de la imagen, con sus cajas seguidas.
    /// Lo que viene después (el remolque SEF de Samsung) se descarta.
    static func videoRange(in d: Data) -> Range<Int>? {
        let bytes = [UInt8](d)
        func u32(_ i: Int) -> Int { Int(bytes[i]) << 24 | Int(bytes[i+1]) << 16 | Int(bytes[i+2]) << 8 | Int(bytes[i+3]) }
        let videoBrands: Set<String> = ["mp41", "mp42", "isom", "iso2", "iso4", "iso5", "iso6", "avc1", "qt  ", "hvc1", "MSNV"]
        var i = 16
        while i + 12 <= bytes.count {
            guard bytes[i] == 0x66, bytes[i+1] == 0x74, bytes[i+2] == 0x79, bytes[i+3] == 0x70,
                  let brand = String(bytes: bytes[(i+4)..<(i+8)], encoding: .ascii), videoBrands.contains(brand) else { i += 1; continue }
            let start = i - 4
            var pos = start, sawMoov = false
            while pos + 8 <= bytes.count {
                var size = u32(pos)
                let type = String(bytes: bytes[(pos+4)..<(pos+8)], encoding: .ascii) ?? ""
                guard type.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " }) else { break }
                if size == 1, pos + 16 <= bytes.count { size = u32(pos + 8) << 32 | u32(pos + 12) }
                if size == 0 { size = bytes.count - pos }
                guard size >= 8, pos + size <= bytes.count else { break }
                if type == "moov" { sawMoov = true }
                pos += size
            }
            if sawMoov { return start..<pos }
            i += 4
        }
        return nil
    }

    /// Momento de la foto dentro del video (XMP de Google/Samsung), si viene. En HEIC el XMP va al final de
    /// la imagen, justo antes del video: por eso se busca en todo lo anterior al video.
    static func stillTime(in d: Data, before videoStart: Int? = nil) -> CMTime? {
        guard let text = String(data: d.prefix(videoStart ?? d.count), encoding: .isoLatin1),
              let r = text.range(of: #"MotionPhotoPresentationTimestampUs\W{1,3}(\d+)"#, options: .regularExpression),
              let us = Int64(text[r].filter(\.isNumber)), us > 0 else { return nil }
        return CMTime(value: us, timescale: 1_000_000)
    }

    /// Escribe `<nombre>.HEIC|JPG` y `<nombre>.MOV` en `dir`. Devuelve sus URLs.
    static func make(from data: Data, name: String, in dir: URL) async throws -> (image: URL, video: URL) {
        guard let range = videoRange(in: data) else { throw Failure.noVideo }
        let id = UUID().uuidString
        let image = try writeImage(data, videoStart: range.lowerBound, id: id, name: name, in: dir)
        let mp4 = dir.appendingPathComponent("\(name)-raw.mp4")
        try data.subdata(in: range).write(to: mp4)
        defer { try? FileManager.default.removeItem(at: mp4) }
        let mov = dir.appendingPathComponent("\(name).MOV")
        try? FileManager.default.removeItem(at: mov)
        try await writeVideo(from: mp4, to: mov, id: id, still: stillTime(in: data, before: range.lowerBound))
        return (image, mov)
    }

    private static func writeImage(_ data: Data, videoStart: Int, id: String, name: String, in dir: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(src) else { throw Failure.unreadableImage }
        let ext = (type as String) == "public.jpeg" ? "JPG" : "HEIC"
        let url = dir.appendingPathComponent("\(name).\(ext)")
        try? FileManager.default.removeItem(at: url)
        // Sin recodificar: misma imagen y mapa HDR, byte por byte; solo cambia el EXIF.
        let imageEnd = (type as String) == "public.jpeg" ? videoStart : (HEIF.imageEnd(data) ?? videoStart)
        try LosslessImage.write(data, imageEnd: imageEnd, id: id, type: type, to: url)
        return url
    }

    /// El único cuadro de la pista de video (tabla de muestras: stsz + stco/co64), como muestra de `duration`.
    static func singleFrame(in mp4: Data, format: CMFormatDescription, duration: CMTime) -> CMSampleBuffer? {
        let h = HEIF(unchecked: mp4)
        func find(_ type: String, in range: (Int, Int)) -> (start: Int, size: Int, header: Int)? {
            h.boxes(range.0, range.1).first { $0.type == type }.map { ($0.start, $0.size, $0.header) }
        }
        guard let moov = find("moov", in: (0, mp4.count)) else { return nil }
        for trak in h.boxes(moov.start + moov.header, moov.start + moov.size) where trak.type == "trak" {
            guard let mdia = find("mdia", in: (trak.start + trak.header, trak.start + trak.size)),
                  let hdlr = find("hdlr", in: (mdia.start + mdia.header, mdia.start + mdia.size)),
                  String(decoding: mp4[(mp4.startIndex + hdlr.start + 16)..<(mp4.startIndex + hdlr.start + 20)], as: UTF8.self) == "vide",
                  let minf = find("minf", in: (mdia.start + mdia.header, mdia.start + mdia.size)),
                  let stbl = find("stbl", in: (minf.start + minf.header, minf.start + minf.size)),
                  let stsz = find("stsz", in: (stbl.start + stbl.header, stbl.start + stbl.size)) else { continue }
            let inner = (stbl.start + stbl.header, stbl.start + stbl.size)
            let fixed = h.u(stsz.start + 12, 4), count = h.u(stsz.start + 16, 4)
            guard count >= 1 else { return nil }
            let size = fixed > 0 ? fixed : h.u(stsz.start + 20, 4)
            let offset: Int
            if let co64 = find("co64", in: inner) { offset = h.u(co64.start + 16, 8) }
            else if let stco = find("stco", in: inner) { offset = h.u(stco.start + 16, 4) }
            else { return nil }
            guard offset + size <= mp4.count else { return nil }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil, customBlockSource: nil,
                                                     offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
                  let block else { return nil }
            let bytes = mp4.subdata(in: offset..<(offset + size))
            _ = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) }
            var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .zero)
            var sampleSize = size
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                      sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
            return sample
        }
        return nil
    }

    private static func writeVideo(from mp4: URL, to mov: URL, id: String, still: CMTime?) async throws {
        let asset = AVURLAsset(url: mp4)
        let duration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: mov, fileType: .mov)
        let idItem = AVMutableMetadataItem()
        idItem.keySpace = .quickTimeMetadata
        idItem.key = "com.apple.quicktime.content.identifier" as NSString
        idItem.value = id as NSString
        idItem.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [idItem]

        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        var stillFrame: (AVAssetWriterInput, CMSampleBuffer)?
        for track in try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio) {
            // Hay Motion Photos cuyo "video" es un solo cuadro sin duración (más el audio): el lector no lo entrega
            // y Fotos rechaza un par sin video. Ese cuadro se lee directo del MP4 y dura todo el video.
            if track.mediaType == .video, try await track.load(.timeRange).duration == .zero {
                let hint = try await track.load(.formatDescriptions).first
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
                input.transform = try await track.load(.preferredTransform)
                if let hint, let frame = singleFrame(in: try Data(contentsOf: mp4), format: hint, duration: duration), writer.canAdd(input) {
                    writer.add(input); stillFrame = (input, frame)
                }
                continue
            }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            guard reader.canAdd(out), writer.canAdd(input) else { continue }
            reader.add(out); writer.add(input); pairs.append((out, input))
        }

        // Marca de foto fija: en qué instante del video está la foto.
        let spec: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
                                   kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String]
        var desc: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                                                                    metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &desc)
        let metaInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaInput)
        writer.add(metaInput)

        guard reader.startReading(), writer.startWriting() else { throw Failure.videoWrite((writer.error ?? reader.error)?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)

        let stillAt = min(still ?? CMTimeMultiplyByFloat64(duration, multiplier: 0.5), duration - CMTime(value: 1, timescale: 30))
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.keySpace = .quickTimeMetadata
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        adaptor.append(AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: max(stillAt, .zero), duration: CMTime(value: 1, timescale: 100))))
        metaInput.markAsFinished()

        if let (input, frame) = stillFrame {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            input.append(frame); input.markAsFinished()
        }
        await withTaskGroup(of: Void.self) { group in
            for (i, (out, input)) in pairs.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        input.requestMediaDataWhenReady(on: DispatchQueue(label: "mov.\(i)")) {
                            while input.isReadyForMoreMediaData {
                                if let sample = out.copyNextSampleBuffer() { input.append(sample) } else {
                                    input.markAsFinished(); done.resume(); return
                                }
                            }
                        }
                    }
                }
            }
        }
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.videoWrite(writer.error?.localizedDescription ?? "estado \(writer.status.rawValue)") }
    }
}
