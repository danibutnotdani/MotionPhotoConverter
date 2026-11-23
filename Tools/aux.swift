import Foundation
import ImageIO
for p in CommandLine.arguments.dropFirst() {
  let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
  let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [CFString: Any]
  let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
  print(URL(fileURLWithPath: p).lastPathComponent, "gainmap:", CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil,
        "apple17:", (props[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?["17"] ?? "-", "modelo:", (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] ?? "-",
        "fecha:", exif?[kCGImagePropertyExifDateTimeOriginal] ?? "-", "pxX:", exif?[kCGImagePropertyExifPixelXDimension] ?? "-", "gps:", props[kCGImagePropertyGPSDictionary] != nil)
}
