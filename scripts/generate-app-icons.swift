import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("assets/artwork/koe-schoolgirl-b-cheerful.png")
let macArtworkInsetRatio: CGFloat = 100.0 / 1024.0
let androidAdaptiveForegroundMarginRatio: CGFloat = 1.0 / 18.0
let monochromeOpaqueLuminance = 0.25
let monochromeTransparentLuminance = 0.55
guard let image = NSImage(contentsOf: source),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Cannot read approved icon artwork: \(source.path)")
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(pixels: Int, alpha: CGImageAlphaInfo) -> CGContext {
    let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: srgb,
        bitmapInfo: alpha.rawValue
    )!
    context.interpolationQuality = .high
    return context
}

func pngData(from context: CGContext) -> Data {
    NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

func writeIfChanged(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? Data(contentsOf: url)) == data {
        return
    }
    try data.write(to: url, options: .atomic)
}

func renderMacIcon(pixels: Int) -> Data {
    let context = makeContext(pixels: pixels, alpha: .premultipliedLast)
    let side = CGFloat(pixels)
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    let inset = side * macArtworkInsetRatio
    let bounds = canvas.insetBy(dx: inset, dy: inset)
    context.addPath(
        CGPath(
            roundedRect: bounds,
            cornerWidth: bounds.width * 2 / 9,
            cornerHeight: bounds.height * 2 / 9,
            transform: nil
        )
    )
    context.clip()
    context.draw(cgImage, in: bounds)
    return pngData(from: context)
}

func renderIOSIcon(pixels: Int) -> Data {
    let context = makeContext(pixels: pixels, alpha: .noneSkipLast)
    let side = CGFloat(pixels)
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
    return pngData(from: context)
}

func renderAndroidAdaptiveIcons(pixels: Int) -> (foreground: Data, monochrome: Data) {
    let context = makeContext(pixels: pixels, alpha: .premultipliedLast)
    let side = CGFloat(pixels)
    let margin = side * androidAdaptiveForegroundMarginRatio
    let bounds = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: margin, dy: margin)
    context.draw(cgImage, in: bounds)
    let foreground = pngData(from: context)

    let monoRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bitmapFormat: .alphaNonpremultiplied,
        bytesPerRow: pixels * 4,
        bitsPerPixel: 32
    )!.retagging(with: .sRGB)!

    let fgBytes = context.data!.assumingMemoryBound(to: UInt8.self)
    let monoBytes = monoRep.bitmapData!
    let monochromeLuminanceRange = monochromeTransparentLuminance - monochromeOpaqueLuminance
    for idx in 0..<(pixels * pixels) {
        let off = idx * 4
        guard fgBytes[off + 3] > 0 else {
            monoBytes[off] = 0
            monoBytes[off + 1] = 0
            monoBytes[off + 2] = 0
            monoBytes[off + 3] = 0
            continue
        }
        let lum = (0.2126 * Double(fgBytes[off]) + 0.7152 * Double(fgBytes[off + 1]) + 0.0722 * Double(fgBytes[off + 2])) / 255.0
        let t = max(0.0, min(1.0, (monochromeTransparentLuminance - lum) / monochromeLuminanceRange))
        let alpha = UInt8((t * 255.0).rounded())
        if alpha == 0 {
            monoBytes[off] = 0
            monoBytes[off + 1] = 0
            monoBytes[off + 2] = 0
            monoBytes[off + 3] = 0
        } else {
            monoBytes[off] = 255
            monoBytes[off + 1] = 255
            monoBytes[off + 2] = 255
            monoBytes[off + 3] = alpha
        }
    }
    let monochrome = monoRep.representation(using: .png, properties: [:])!
    return (foreground, monochrome)
}

let iconsetDir = root.appendingPathComponent("build/macos/AppIcon.iconset", isDirectory: true)
let macSpecs: [(String, Int)] = [
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

for (filename, pixels) in macSpecs {
    try writeIfChanged(renderMacIcon(pixels: pixels), to: iconsetDir.appendingPathComponent(filename))
    print("macos: \(filename) (\(pixels) px)")
}

let iosIconPath = root.appendingPathComponent("platforms/ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try writeIfChanged(renderIOSIcon(pixels: 1024), to: iosIconPath)
print("ios: AppIcon.png (1024 px)")

let androidResDir = root.appendingPathComponent("platforms/android/gradle-app/app/src/main/res", isDirectory: true)
let androidSpecs: [(String, Int)] = [
    ("mdpi", 108),
    ("hdpi", 162),
    ("xhdpi", 216),
    ("xxhdpi", 324),
    ("xxxhdpi", 432),
]

for (density, pixels) in androidSpecs {
    let dir = androidResDir.appendingPathComponent("mipmap-\(density)", isDirectory: true)
    let layers = renderAndroidAdaptiveIcons(pixels: pixels)
    try writeIfChanged(layers.foreground, to: dir.appendingPathComponent("ic_launcher_foreground.png"))
    try writeIfChanged(layers.monochrome, to: dir.appendingPathComponent("ic_launcher_monochrome.png"))
    print("android: mipmap-\(density)/ic_launcher_{foreground,monochrome}.png (\(pixels) px)")
}
