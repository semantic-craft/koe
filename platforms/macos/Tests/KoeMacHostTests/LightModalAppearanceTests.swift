import AppKit
import Foundation
import KoeAppleShared
import SwiftUI
import Testing
@testable import Koe

extension SerializedMacHostSuites {
@Suite("Light modal appearance under dark system mode", .serialized)
@MainActor
struct LightModalAppearanceTests {
    @Test("Connect guide sheet stays light under a darkAqua window")
    func connectGuideSheetStaysLight() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HostSessionStore(workspacePath: dir.path)
        defer { store.shutdown() }
        store.send(.deviceOpenGuide)

        let view = ConnectGuideSheet(store: store)
        let rendered = try renderOffscreen(view, fallbackSize: CGSize(width: 520, height: 520), snapshotName: "connect-guide.png")

        let corners = sampleCornerLuminances(in: rendered.bitmap, inset: 20)
        #expect(corners.allSatisfy { $0 > 0.85 }, "ConnectGuideSheet corner luminances \(corners) should stay > 0.85")
    }

    @Test("ItemEditor task and memory sheets stay light including TextEditor interior")
    func itemEditorSheetsStayLight() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HostSessionStore(workspacePath: dir.path)
        defer { store.shutdown() }

        for (isTask, fileName) in [(true, "item-editor-task.png"), (false, "item-editor-memory.png")] {
            let view = ItemEditor(
                store: store,
                id: isTask ? "task-1" : "memory-1",
                initialText: isTask ? "验证待办编辑" : "验证记忆编辑",
                initialDue: nil,
                isTask: isTask
            )
            let rendered = try renderOffscreen(view, fallbackSize: CGSize(width: 470, height: 280), snapshotName: fileName)

            let corners = sampleCornerLuminances(in: rendered.bitmap, inset: 14)
            #expect(corners.allSatisfy { $0 > 0.85 }, "ItemEditor(isTask=\(isTask)) corner luminances \(corners) should stay > 0.85")

            let editorView = try #require(
                findFirstSubview(in: rendered.hostingView, matching: { $0 is NSTextView || $0 is NSScrollView }),
                "Expected TextEditor backing view inside ItemEditor"
            )
            let editorRect = rendered.hostingView.convert(editorView.bounds, from: editorView)
            let editorSampleX = editorRect.minX + editorRect.width * 0.78
            let editorSampleY = editorRect.minY + editorRect.height * 0.65
            let editorLum = try sampleLuminance(
                in: rendered.bitmap,
                viewPoint: CGPoint(x: editorSampleX, y: editorSampleY),
                viewSize: rendered.hostingView.bounds.size,
                isFlipped: rendered.hostingView.isFlipped
            )
            #expect(editorLum > 0.85, "ItemEditor(isTask=\(isTask)) TextEditor interior luminance \(editorLum) should stay > 0.85")
        }
    }

    @Test("NativeQuitPanel keeps aqua appearance and white background when app is darkAqua")
    func nativeQuitPanelStaysLight() throws {
        let app = NSApplication.shared
        let priorAppearance = app.appearance
        app.appearance = NSAppearance(named: .darkAqua)
        defer { app.appearance = priorAppearance }

        let quitPanel = NativeQuitPanel(cancel: {})
        defer { quitPanel.close() }
        quitPanel.update(LifecycleSnapshot(keepAwake: true, quitPhase: "draining", message: "正在保存，完成后将自动退出。"))

        let resolvedMatch = quitPanel.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        #expect(resolvedMatch == .aqua, "NativeQuitPanel effectiveAppearance should resolve to .aqua")

        var panelBgLuminance = 0.0
        quitPanel.panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let srgb = quitPanel.panel.backgroundColor.usingColorSpace(.sRGB) {
                panelBgLuminance = relativeLuminance(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
            }
        }
        #expect(panelBgLuminance > 0.85, "NativeQuitPanel background luminance \(panelBgLuminance) should stay > 0.85")

        if let contentView = quitPanel.panel.contentView {
            contentView.layoutSubtreeIfNeeded()
            let bitmap = try captureViewBitmap(contentView, backdropColor: resolvedPanelBackground(quitPanel.panel))
            try saveSnapshotIfEnabled(bitmap, fileName: "quit-panel.png")
            let corners = sampleCornerLuminances(in: bitmap, inset: 12)
            #expect(corners.allSatisfy { $0 > 0.85 }, "NativeQuitPanel content corner luminances \(corners) should stay > 0.85")
        }
    }

    private struct RenderedView {
        let window: NSWindow
        let hostingView: NSView
        let bitmap: NSBitmapImageRep
    }

    private func renderOffscreen<V: View>(
        _ view: V,
        fallbackSize: CGSize,
        snapshotName: String
    ) throws -> RenderedView {
        let hostingView = NSHostingView(rootView: view)
        let fitting = hostingView.fittingSize
        let size = CGSize(
            width: max(fitting.width, fallbackSize.width),
            height: max(fitting.height, fallbackSize.height)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try captureViewBitmap(hostingView, backdropColor: .black)
        try saveSnapshotIfEnabled(bitmap, fileName: snapshotName)
        return RenderedView(window: window, hostingView: hostingView, bitmap: bitmap)
    }

    private func captureViewBitmap(_ view: NSView, backdropColor: NSColor) throws -> NSBitmapImageRep {
        let bounds = view.bounds
        let rawRep = try #require(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: rawRep)

        let width = max(Int(bounds.width), 1)
        let height = max(Int(bounds.height), 1)
        let composited = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        composited.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        let context = try #require(NSGraphicsContext(bitmapImageRep: composited))
        NSGraphicsContext.current = context
        backdropColor.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: bounds.size)).fill()
        rawRep.draw(
            in: NSRect(origin: .zero, size: bounds.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: false,
            hints: nil
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return composited
    }

    private func resolvedPanelBackground(_ panel: NSPanel) -> NSColor {
        var resolved = NSColor.black
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = panel.backgroundColor.usingColorSpace(.sRGB) ?? panel.backgroundColor
        }
        return resolved
    }

    private func saveSnapshotIfEnabled(_ bitmap: NSBitmapImageRep, fileName: String) throws {
        guard let dirPath = ProcessInfo.processInfo.environment["KOE_MODAL_SNAPSHOT_DIR"], !dirPath.isEmpty else {
            return
        }
        let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: dirURL.appendingPathComponent(fileName))
    }

    private func sampleCornerLuminances(in bitmap: NSBitmapImageRep, inset: CGFloat) -> [Double] {
        let w = CGFloat(bitmap.pixelsWide)
        let h = CGFloat(bitmap.pixelsHigh)
        let points = [
            (Int(inset), Int(inset)),
            (Int(max(w - inset - 1, 0)), Int(inset)),
            (Int(inset), Int(max(h - inset - 1, 0))),
            (Int(max(w - inset - 1, 0)), Int(max(h - inset - 1, 0)))
        ]
        return points.compactMap { point in
            pixelLuminance(in: bitmap, pixelX: point.0, pixelY: point.1)
        }
    }

    private func sampleLuminance(in bitmap: NSBitmapImageRep, viewPoint: CGPoint, viewSize: CGSize, isFlipped: Bool) throws -> Double {
        let scaleX = CGFloat(bitmap.pixelsWide) / max(viewSize.width, 1)
        let scaleY = CGFloat(bitmap.pixelsHigh) / max(viewSize.height, 1)
        let px = min(max(Int(viewPoint.x * scaleX), 0), bitmap.pixelsWide - 1)
        let normalizedY = isFlipped ? viewPoint.y : (viewSize.height - viewPoint.y)
        let py = min(max(Int(normalizedY * scaleY), 0), bitmap.pixelsHigh - 1)
        return try #require(pixelLuminance(in: bitmap, pixelX: px, pixelY: py))
    }

    private func pixelLuminance(in bitmap: NSBitmapImageRep, pixelX: Int, pixelY: Int) -> Double? {
        guard let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.sRGB) else {
            return nil
        }
        return relativeLuminance(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }

    private func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> Double {
        func linearize(_ channel: CGFloat) -> Double {
            let clamped = min(max(Double(channel), 0.0), 1.0)
            return clamped <= 0.03928 ? clamped / 12.92 : pow((clamped + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    private func findFirstSubview(in root: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(root) { return root }
        for child in root.subviews {
            if let hit = findFirstSubview(in: child, matching: predicate) {
                return hit
            }
        }
        return nil
    }
}
}
