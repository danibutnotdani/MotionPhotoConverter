// Compara píxel por píxel dos imágenes (decodificadas a RGBA8).
import CoreGraphics
import Foundation
import ImageIO
func pixels(_ path: String) -> (Int, Int, [UInt8]) {
    let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!, 0, nil)!
    var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
    let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return (img.width, img.height, buf)
}
let a = pixels(CommandLine.arguments[1]), b = pixels(CommandLine.arguments[2])
let diff = zip(a.2, b.2).filter { $0 != $1 }.count
print("\(a.0)x\(a.1) vs \(b.0)x\(b.1): bytes distintos = \(diff)")
