import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let checkOnly: Bool
switch arguments {
case []:
    checkOnly = false
case ["--check"]:
    checkOnly = true
default:
    fputs("Usage: swift scripts/generate-app-icons.swift [--check]\n", stderr)
    exit(2)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("assets/artwork/koe-schoolgirl-b-cheerful.png")
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

func relativePath(of url: URL) -> String {
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
}

struct DecodedImage: Equatable {
    let width: Int
    let height: Int
    let rgba: Data
}

func decodedPixels(from data: Data) -> DecodedImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return nil }
    let bytesPerRow = width * 4
    var rgba = Data(count: bytesPerRow * height)
    let drawn = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
        guard let baseAddress = rawBuffer.baseAddress,
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: srgb,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return false
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }
    return DecodedImage(width: width, height: height, rgba: rgba)
}

func imagesMatch(expected: Data, actual: Data) -> Bool {
    if expected == actual {
        return true
    }
    guard let expectedPixels = decodedPixels(from: expected),
          let actualPixels = decodedPixels(from: actual) else {
        return false
    }
    return expectedPixels == actualPixels
}

func syncTrackedIcon(_ data: Data, to url: URL, mismatches: inout [String]) throws {
    if checkOnly {
        guard let existing = try? Data(contentsOf: url), imagesMatch(expected: data, actual: existing) else {
            mismatches.append(relativePath(of: url))
            return
        }
        return
    }
    try writeIfChanged(data, to: url)
}

func renderMacIcon(pixels: Int) -> Data {
    let context = makeContext(pixels: pixels, alpha: .premultipliedLast)
    let side = CGFloat(pixels)
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    // Match the legacy macOS 824 px artwork frame on a 1024 px canvas.
    let bounds = canvas.insetBy(dx: side * 100 / 1024, dy: side * 100 / 1024)
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
    // Android adaptive foreground keeps a 1/18 transparent margin so artwork fills the centered 8/9 square.
    let bounds = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side / 18, dy: side / 18)
    context.draw(cgImage, in: bounds)
    let foreground = pngData(from: context)

    // Material You themed monochrome mask maps Rec.709 luminance [0.25, 0.55] onto opaque-to-transparent white.
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
        let t = max(0.0, min(1.0, (0.55 - lum) / 0.30))
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

var trackedMismatches: [String] = []

let iosIconPath = root.appendingPathComponent("platforms/ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try syncTrackedIcon(renderIOSIcon(pixels: 1024), to: iosIconPath, mismatches: &trackedMismatches)
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
    try syncTrackedIcon(layers.foreground, to: dir.appendingPathComponent("ic_launcher_foreground.png"), mismatches: &trackedMismatches)
    try syncTrackedIcon(layers.monochrome, to: dir.appendingPathComponent("ic_launcher_monochrome.png"), mismatches: &trackedMismatches)
    print("android: mipmap-\(density)/ic_launcher_{foreground,monochrome}.png (\(pixels) px)")
}

if !trackedMismatches.isEmpty {
    for path in trackedMismatches {
        fputs("FAIL: tracked icon out of sync with artwork: \(path)\n", stderr)
    }
    fputs("Run `swift scripts/generate-app-icons.swift` to regenerate tracked icons.\n", stderr)
    exit(1)
}
