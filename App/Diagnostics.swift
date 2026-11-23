import Foundation
import ImageIO
import Photos

/// Solo al abrir con `-diagnostico YES` (desde la Mac con devicectl): describe las 12 fotos más recientes
/// en Documents/diagnostico.json para revisar que las convertidas sí son Live Photos.
enum Diagnostics {
    static func runIfAsked() {
        DispatchQueue.global().async { run() }
    }

    private static func run() {
        if let name = UserDefaults.standard.string(forKey: "exportar") { export(name) }
        guard UserDefaults.standard.bool(forKey: "diagnostico"), PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
        options.fetchLimit = 12
        var rows: [[String: Any]] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { a, _, _ in
            var hdr: Any = "-", bytes: Any = "-"
            if a.mediaSubtypes.contains(.photoLive), let photo = PHAssetResource.assetResources(for: a).first(where: { $0.type == .photo }) {
                let done = DispatchSemaphore(value: 0)
                var data = Data()
                PHAssetResourceManager.default().requestData(for: photo, options: nil) { data.append($0) } completionHandler: { _ in done.signal() }
                done.wait()
                bytes = data.count
                hdr = CGImageSourceCreateWithData(data as CFData, nil).map { CGImageSourceCopyAuxiliaryDataInfoAtIndex($0, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil } ?? false
            }
            rows.append([
                "hdr": hdr, "bytes": bytes,
                "live": a.mediaSubtypes.contains(.photoLive),
                "creada": a.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "ubicacion": a.location != nil,
                "favorita": a.isFavorite,
                "recursos": PHAssetResource.assetResources(for: a).map { "\($0.type.rawValue):\($0.originalFilename)" },
            ])
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diagnostico.json")
        try? JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted).write(to: url)
    }

    /// `-exportar <nombre>`: copia a Documents el archivo original de esa foto (para reproducir un error en la Mac).
    private static func export(_ name: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects { a, _, stop in
            guard let r = PHAssetResource.assetResources(for: a).first(where: { $0.type == .photo && $0.originalFilename.hasPrefix(name) }) else { return }
            stop.pointee = true
            let done = DispatchSemaphore(value: 0)
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: r, toFile: docs.appendingPathComponent(r.originalFilename), options: options) { _ in done.signal() }
            done.wait()
        }
    }
}
