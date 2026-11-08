import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func render(_ size: Int, at url: URL, inset: Bool) throws {
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  let scale = CGFloat(size) / 1024
  let context = NSGraphicsContext.current!.cgContext
  context.scaleBy(x: scale, y: scale)
  let margin: CGFloat = inset ? 80 : 0
  NSColor(red: 0.659, green: 0.718, blue: 1, alpha: 1).setFill()
  NSBezierPath(roundedRect: NSRect(x: margin, y: margin, width: 1024 - 2 * margin, height: 1024 - 2 * margin), xRadius: inset ? 196 : 0, yRadius: inset ? 196 : 0).fill()
  NSColor(red: 0.067, green: 0.090, blue: 0.169, alpha: 1).setFill()
  let play = NSBezierPath()
  play.move(to: NSPoint(x: 410, y: 304))
  play.line(to: NSPoint(x: 714, y: 512))
  play.line(to: NSPoint(x: 410, y: 720))
  play.close()
  play.fill()
  NSGraphicsContext.restoreGraphicsState()
  try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
let manager = FileManager.default
// The iOS/iPadOS launcher icon is maintained in ios/Runner/AppIcon.icon.
let mac = root.appendingPathComponent("macos/Runner/Assets.xcassets/AppIcon.appiconset")
for file in try manager.contentsOfDirectory(at: mac, includingPropertiesForKeys: nil) where file.pathExtension == "png" {
  let original = NSBitmapImageRep(data: try Data(contentsOf: file))!
  try render(original.pixelsWide, at: file, inset: true)
}
for (folder, size) in [("mdpi",48), ("hdpi",72), ("xhdpi",96), ("xxhdpi",144), ("xxxhdpi",192)] {
  try render(size, at: root.appendingPathComponent("android/app/src/main/res/mipmap-\(folder)/ic_launcher.png"), inset: true)
}
try render(1024, at: root.appendingPathComponent("assets/brand/orvex-icon.png"), inset: true)
try render(256, at: root.appendingPathComponent("assets/brand/orvex-icon-256.png"), inset: true)
