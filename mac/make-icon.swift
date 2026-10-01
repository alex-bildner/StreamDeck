import AppKit
import Foundation

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let slots: [(CGFloat, CGFloat, CGFloat)] = [
    (25, 36, 1), (46, 36, 1), (67, 36, 1),
    (25, 57, 1), (46, 57, 1), (67, 57, 0.7),
]

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSColor(srgbRed: 17 / 255, green: 17 / 255, blue: 19 / 255, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
    let scale = size / 108
    for (x, y, alpha) in slots {
        NSColor.white.withAlphaComponent(alpha).setFill()
        let rect = NSRect(
            x: x * scale,
            y: size - (y + 16) * scale,
            width: 16 * scale,
            height: 16 * scale
        )
        NSBezierPath(roundedRect: rect, xRadius: 4 * scale, yRadius: 4 * scale).fill()
    }
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DeckIcon", code: 1)
    }
    try png.write(to: url)
}

let names: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in names {
    try writePNG(render(size: size), to: iconset.appendingPathComponent(name))
}
