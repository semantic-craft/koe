import AppKit

// Package the approved artwork into a macOS AppIcon.iconset without changing the illustration.
// Run from the repository root: swift scripts/generate-app-icons.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("assets/artwork/koe-schoolgirl-b-cheerful.png")
guard let image = NSImage(contentsOf: source) else {
    fatalError("Cannot read approved icon artwork: \(source.path)")
}

func renderMacIcon(pixels: Int) -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha = CGImageAlphaInfo.premultipliedLast
    let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: colorSpace,
        bitmapInfo: alpha.rawValue
    )!
    context.interpolationQuality = .high
    let side = CGFloat(pixels)
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    let bounds = canvas.insetBy(dx: side * 0.05, dy: side * 0.05)
    context.addPath(
        CGPath(
            roundedRect: bounds,
            cornerWidth: side * 0.20,
            cornerHeight: side * 0.20,
            transform: nil
        )
    )
    context.clip()
    let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    context.draw(cgImage, in: bounds)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconsetDir = root.appendingPathComponent("build/macos/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
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

for (filename, pixels) in specs {
    try renderMacIcon(pixels: pixels).write(to: iconsetDir.appendingPathComponent(filename))
    print("macos: \(filename) (\(pixels) px)")
}
