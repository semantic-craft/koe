import AppKit

// Package the approved artwork without changing the illustration.
// Run from the repository root: swift scripts/generate-app-icons.swift
// Writes the iOS and macOS AppIcon sets and the Android launcher mipmaps.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("assets/artwork/koe-schoolgirl-b-cheerful.png")
guard let image = NSImage(contentsOf: source) else {
    fatalError("Cannot read approved icon artwork: \(source.path)")
}

func render(pixels: Int, mac: Bool) -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha = mac ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let context = CGContext(data: nil, width: pixels, height: pixels,
                            bitsPerComponent: 8, bytesPerRow: pixels * 4,
                            space: colorSpace, bitmapInfo: alpha.rawValue)!
    context.interpolationQuality = .high
    let side = CGFloat(pixels)
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    let bounds = mac ? canvas.insetBy(dx: side * 0.05, dy: side * 0.05) : canvas
    if mac {
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: side * 0.20,
                              cornerHeight: side * 0.20, transform: nil))
        context.clip()
    }
    let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    context.draw(cgImage, in: bounds)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for platform in ["ios", "macos"] {
    let directory = root.appendingPathComponent("\(platform)/Runner/Assets.xcassets/AppIcon.appiconset")
    let data = try Data(contentsOf: directory.appendingPathComponent("Contents.json"))
    let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var written = Set<String>()
    for entry in manifest["images"] as! [[String: String]] {
        guard let name = entry["filename"], written.insert(name).inserted else { continue }
        let points = Double(entry["size"]!.split(separator: "x")[0])!
        let scale = Double(entry["scale"]!.dropLast())!
        let pixels = Int(points * scale)
        try render(pixels: pixels, mac: platform == "macos").write(to: directory.appendingPathComponent(name))
        print("\(platform): \(name) (\(pixels) px)")
    }
}

// Android launcher icons: full-bleed square like iOS, one file per density.
let androidDensities: [(String, Int)] = [
    ("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192),
]
for (density, pixels) in androidDensities {
    let file = root.appendingPathComponent("android/app/src/main/res/mipmap-\(density)/ic_launcher.png")
    try render(pixels: pixels, mac: false).write(to: file)
    print("android: mipmap-\(density)/ic_launcher.png (\(pixels) px)")
}
