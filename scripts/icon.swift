import AppKit
import Foundation

// Asset packaging only: preserve the generated source artwork and its alpha.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("build/AppIcon.iconset")
let catalog = root.appendingPathComponent("Resources/Assets.xcassets")
let appSet = catalog.appendingPathComponent("MemoryGuardIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: appSet, withIntermediateDirectories: true)
guard let source = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.png")) else { fatalError("AppIcon.png missing") }
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context; context.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    if [16, 32, 128, 256, 512].contains(size) { try data.write(to: output.appendingPathComponent("icon_\(size)x\(size).png")) }
    if [32, 64, 256, 512, 1024].contains(size) { try data.write(to: output.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
}
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        let destination = appSet.appendingPathComponent(name)
        try Data(contentsOf: output.appendingPathComponent(name)).write(to: destination)
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let info: [String: Any] = ["author": "xcode", "version": 1]
try JSONSerialization.data(withJSONObject: ["images": entries, "info": info], options: [.prettyPrinted, .sortedKeys]).write(to: appSet.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted]).write(to: catalog.appendingPathComponent("Contents.json"))

// A 32-point UI mark gets display-scale-specific pixels at build time. SwiftUI never
// minifies the full-size nebula texture on a live view or guesses the display scale.
let mark = catalog.appendingPathComponent("SidebarMark.imageset")
try FileManager.default.createDirectory(at: mark, withIntermediateDirectories: true)
var markEntries: [[String: String]] = []
for scale in [1, 2] {
    let file = scale == 1 ? "icon_32x32.png" : "icon_32x32@2x.png"
    try Data(contentsOf: output.appendingPathComponent(file)).write(to: mark.appendingPathComponent(file))
    markEntries.append(["idiom": "mac", "scale": "\(scale)x", "filename": file])
}
try JSONSerialization.data(withJSONObject: ["images": markEntries, "info": info, "properties": ["template-rendering-intent": "original"]], options: [.prettyPrinted, .sortedKeys]).write(to: mark.appendingPathComponent("Contents.json"))
