// Prueba en la Mac: convierte cada archivo y pide a Photos que arme el Live Photo con el par.
import AVFoundation
import Foundation
import ImageIO
import Photos
import PhotosUI

@main struct Check {
    static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        for path in CommandLine.arguments.dropFirst(2) {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let pair = try await LivePhotoMaker.make(from: data, name: name, in: out)
                let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(pair.image as CFURL, nil)!, 0, nil) as! [CFString: Any]
                let apple = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
                let asset = AVURLAsset(url: pair.video)
                let meta = try await asset.load(.metadata).first { $0.identifier?.rawValue.contains("content.identifier") == true }
                let movId = try await meta?.load(.stringValue)
                let dur = try await asset.load(.duration).seconds
                let tracks = try await asset.load(.tracks).map { $0.mediaType.rawValue }
                let ok = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                    var resumed = false
                    PHLivePhoto.request(withResourceFileURLs: [pair.image, pair.video], placeholderImage: nil, targetSize: CGSize.zero, contentMode: PHImageContentMode.aspectFit) { live, info in
                        if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                        if !resumed { resumed = true; c.resume(returning: live != nil ? "sí" : "no \(info)") }
                    }
                }
                print("\(name): still=\(LivePhotoMaker.videoRange(in: data).flatMap { LivePhotoMaker.stillTime(in: data, before: $0.lowerBound)?.seconds } ?? -1) id foto=\(apple?["17"] ?? "-") id video=\(movId ?? "-") dur=\(String(format: "%.2f", dur))s pistas=\(tracks) exif=\(props[kCGImagePropertyExifDictionary] != nil) gps=\(props[kCGImagePropertyGPSDictionary] != nil) livePhoto=\(ok)")
            } catch { print("\(name): \(error.localizedDescription)") }
        }
    }
}
