import AppKit

// Package the approved artwork without changing the illustration.
// Run from the repository root: swift scripts/generate-app-icons.swift
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

// Android adaptive icon (minSdk 34, so no legacy PNGs). The illustration is
// full-bleed, so the foreground carries it on a background sampled from its
// own corner; it spans 96 of the 108 dp so the launcher mask (about 72 dp)
// keeps the face and the recorder clip, and parallax never shows a seam.
// The monochrome layer keeps the dark ink (hair, eyes, collar) as alpha for
// Android 13+ themed icons.
let cgSource = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let sourceRep = NSBitmapImageRep(cgImage: cgSource)
let corner = sourceRep.colorAt(x: sourceRep.pixelsWide - 4, y: 4)!.usingColorSpace(.sRGB)!
let backgroundHex = String(format: "#FF%02X%02X%02X",
                           Int(round(corner.redComponent * 255)),
                           Int(round(corner.greenComponent * 255)),
                           Int(round(corner.blueComponent * 255)))

func renderAdaptive(pixels: Int, monochrome: Bool) -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels,
                            bitsPerComponent: 8, bytesPerRow: pixels * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let side = CGFloat(pixels)
    let inset = side * 6 / 108
    context.draw(cgSource, in: CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: inset, dy: inset))
    if monochrome {
        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: pixels * pixels * 4)
        for index in stride(from: 0, to: pixels * pixels * 4, by: 4) {
            let alpha = Double(buffer[index + 3]) / 255
            guard alpha > 0 else { continue }
            // Un-premultiply, then map luminance 0.25…0.55 to opaque…clear.
            let luminance = (0.2126 * Double(buffer[index]) + 0.7152 * Double(buffer[index + 1])
                + 0.0722 * Double(buffer[index + 2])) / 255 / alpha
            let ink = min(1, max(0, (0.55 - luminance) / 0.30)) * alpha
            let value = UInt8(round(ink * 255))
            buffer[index] = value
            buffer[index + 1] = value
            buffer[index + 2] = value
            buffer[index + 3] = value
        }
    }
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let res = root.appendingPathComponent("android/app/src/main/res")
for (density, scale) in [("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2.0), ("xxhdpi", 3.0), ("xxxhdpi", 4.0)] {
    let directory = res.appendingPathComponent("mipmap-\(density)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pixels = Int(108 * scale)
    try renderAdaptive(pixels: pixels, monochrome: false)
        .write(to: directory.appendingPathComponent("ic_launcher_foreground.png"))
    try renderAdaptive(pixels: pixels, monochrome: true)
        .write(to: directory.appendingPathComponent("ic_launcher_monochrome.png"))
    print("android: mipmap-\(density) (\(pixels) px)")
}
try """
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by scripts/generate-app-icons.swift -->
<resources>
    <color name="ic_launcher_background">\(backgroundHex)</color>
</resources>

""".write(to: res.appendingPathComponent("values/ic_launcher_background.xml"), atomically: true, encoding: .utf8)
print("android: ic_launcher_background \(backgroundHex)")
