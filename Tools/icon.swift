// Genera App/Assets.xcassets/AppIcon.appiconset/icon-1024.png: símbolo Live Photo blanco sobre degradado.
import AppKit
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 0, y: 0, width: px, height: px)
NSGradient(colors: [NSColor(red: 0.20, green: 0.47, blue: 0.96, alpha: 1), NSColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)])!.draw(in: rect, angle: -45)
let cfg = NSImage.SymbolConfiguration(pointSize: 560, weight: .regular).applying(.init(paletteColors: [.white]))
let sym = NSImage(systemSymbolName: "livephoto", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let s = sym.size
sym.draw(in: NSRect(x: (CGFloat(px) - s.width) / 2, y: (CGFloat(px) - s.height) / 2, width: s.width, height: s.height))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
