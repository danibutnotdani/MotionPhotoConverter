import Photos
import SwiftUI

/// Una foto elegida y en qué va.
struct Item: Identifiable {
    enum State: Equatable { case checking, motion, notMotion, converting, done, failed(String) }
    let id: String
    var asset: PHAsset?
    /// Archivo suelto (en la Mac, lo que llega por AirDrop se queda en Descargas, no en Fotos).
    var file: URL?
    var name = ""
    var state = State.checking
}

@MainActor @Observable
final class Converter {
    var items: [Item] = []
    var running = false
    var replaceOriginals = true
    var message: String?
    var progress: String?
    /// Las que ya se revisaron y no traen video: no se vuelven a descargar en la siguiente búsqueda.
    private var withoutVideo = Set(UserDefaults.standard.stringArray(forKey: "sinVideo") ?? [])

    var pending: [Item] { items.filter { $0.state == .motion } }

    /// Busca Motion Photos sin convertir. `all: false` mira las 300 que entraron al último (por AirDrop),
    /// aunque se hayan tomado hace semanas; `all: true` revisa toda la fototeca.
    /// Candidatas: nombre de cámara Samsung (20261102_141123) que aún no son Live Photo; luego se confirma el video.
    func scan(all: Bool) async {
        running = true
        defer { running = false }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: all ? "creationDate" : "modificationDate", ascending: false)]
        if !all { options.fetchLimit = 300 }
        var ids: [String] = []
        let skip = withoutVideo
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { a, _, _ in
            guard !a.mediaSubtypes.contains(.photoLive), !skip.contains(a.localIdentifier),
                  let name = PHAssetResource.assetResources(for: a).first(where: { $0.type == .photo })?.originalFilename,
                  name.range(of: #"^\d{8}_\d{6}"#, options: .regularExpression) != nil else { return }
            ids.append(a.localIdentifier)
        }
        await load(ids)
        items.removeAll { $0.state == .notMotion }
    }

    func load(_ ids: [String]) async {
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var list: [Item] = []
        found.enumerateObjects { a, _, _ in list.append(Item(id: a.localIdentifier, asset: a)) }
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        list.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        items = list
        message = nil
        for i in items.indices {
            guard let asset = items[i].asset else { continue }
            items[i].name = original(asset)?.originalFilename ?? "Foto"
            if asset.mediaSubtypes.contains(.photoLive) { items[i].state = .notMotion; continue }
            progress = items.count > 1 ? "Revisando \(i + 1) de \(items.count)…" : nil
            guard let data = try? await Self.data(of: asset) else { items[i].state = .failed("No se pudo descargar"); continue }
            items[i].state = LivePhotoMaker.videoRange(in: data) == nil ? .notMotion : .motion
            if items[i].state == .notMotion { withoutVideo.insert(asset.localIdentifier) }
        }
        progress = nil
        UserDefaults.standard.set(Array(withoutVideo), forKey: "sinVideo")
    }

    /// Archivos elegidos o arrastrados (HEIC/JPG del S24).
    func loadFiles(_ urls: [URL]) async {
        message = nil
        items = urls.map { Item(id: $0.path, file: $0, name: $0.lastPathComponent) }
        for i in items.indices {
            let data = try? Self.data(of: items[i].file!)
            items[i].state = data.flatMap(LivePhotoMaker.videoRange) == nil ? .notMotion : .motion
        }
    }

    private static func data(of file: URL) throws -> Data {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: file)
    }

    func convertAll() async {
        running = true
        defer { running = false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var converted: [PHAsset] = []
        var files: [URL] = []
        for i in items.indices where items[i].state == .motion {
            items[i].state = .converting
            let asset = items[i].asset
            do {
                let data = if let asset { try await Self.data(of: asset) } else { try Self.data(of: items[i].file!) }
                let stem = (items[i].name as NSString).deletingPathExtension
                let pair = try await LivePhotoMaker.make(from: data, name: stem, in: dir)
                let previous = asset.map { earlierConversions(of: $0, name: stem) } ?? []
                try await save(pair, like: asset)
                items[i].state = .done
                if let asset { converted.append(asset) } else if let file = items[i].file { files.append(file) }
                converted += previous
            } catch {
                items[i].state = .failed(error.localizedDescription)
            }
        }
        guard replaceOriginals else { return }
        // Archivos sueltos: a la Papelera (se pueden recuperar).
        for file in files {
            let scoped = file.startAccessingSecurityScopedResource()
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
            if scoped { file.stopAccessingSecurityScopedResource() }
        }
        guard !converted.isEmpty else { return }
        // Fotos pide confirmación y las manda a "Eliminado recientemente" (30 días para recuperarlas).
        do { try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(converted as NSArray) } }
        catch { message = "Se guardaron las Live Photos, pero las originales siguen ahí (no se confirmó el borrado)." }
    }

    /// Guarda el par como Live Photo con la fecha, ubicación, favorito y álbumes de la original.
    /// De un archivo suelto, Fotos toma fecha y ubicación del propio EXIF.
    private func save(_ pair: (image: URL, video: URL), like asset: PHAsset?) async throws {
        let albums = asset.map { PHAssetCollection.fetchAssetCollectionsContaining($0, with: .album, options: nil) }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let photo = PHAssetResourceCreationOptions(); photo.originalFilename = pair.image.lastPathComponent
            let video = PHAssetResourceCreationOptions(); video.originalFilename = pair.video.lastPathComponent
            request.addResource(with: .photo, fileURL: pair.image, options: photo)
            request.addResource(with: .pairedVideo, fileURL: pair.video, options: video)
            guard let asset else { return }
            request.creationDate = asset.creationDate
            request.location = asset.location
            request.isFavorite = asset.isFavorite
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            albums?.enumerateObjects { album, _, _ in
                if album.canPerform(.addContent) { PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray) }
            }
        }
    }

    /// Live Photos que ya se habían hecho de esta misma foto (misma fecha y nombre): se reemplazan junto con la original.
    private func earlierConversions(of asset: PHAsset, name: String) -> [PHAsset] {
        guard let date = asset.creationDate else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate == %@", date as NSDate)
        var found: [PHAsset] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { a, _, _ in
            guard a.localIdentifier != asset.localIdentifier, a.mediaSubtypes.contains(.photoLive),
                  let file = self.original(a)?.originalFilename, (file as NSString).deletingPathExtension == name else { return }
            found.append(a)
        }
        return found
    }

    private func original(_ asset: PHAsset) -> PHAssetResource? {
        PHAssetResource.assetResources(for: asset).first { $0.type == .photo }
    }

    /// Bytes originales (con el video pegado), bajándolos de iCloud si hace falta.
    private static func data(of asset: PHAsset) async throws -> Data {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else { throw LivePhotoMaker.Failure.unreadableImage }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { c in
            var data = Data()
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data.append($0) } completionHandler: { error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data) }
            }
        }
    }
}
