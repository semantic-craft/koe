import AppKit
import FlutterMacOS

/// Presentation only. Dart owns recognition, translation and persistence.
final class CaptionsPanel {
    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hover: Timer?
    private var revision = -1
    func configure(_ messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: "com.semanticcraft.koe/captions", binaryMessenger: messenger)
            .setMethodCallHandler { [weak self] call, result in
                guard call.method == "show", let args = call.arguments as? [String: Any] else {
                    result(FlutterMethodNotImplemented); return
                }
                self?.show(args); result(nil)
            }
    }
    private func show(_ args: [String: Any]) {
        let incoming = args["revision"] as? Int ?? 0
        guard incoming >= revision else { return }; revision = incoming
        let mode = args["mode"] as? String ?? "hidden"
        hover?.invalidate(); hover = nil
        guard mode != "hidden" else { panel?.orderOut(nil); return }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 180),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false; window.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94)
            window.hasShadow = true; window.sharingType = .none // Best effort only; never promise capture exclusion.
            label.font = NSFont.systemFont(ofSize: 19); label.textColor = .labelColor
            label.maximumNumberOfLines = 0; label.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(label)
            if let content = window.contentView {
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
                    label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
                    label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                    label.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16)])
            }
            panel = window
        }
        guard let panel, let screen = NSScreen.main else { return }
        let width = min(680, screen.visibleFrame.width - 40)
        let height: CGFloat = mode == "minutes" ? min(480, screen.visibleFrame.height - 80) : 180
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.minY + 30, width: width, height: height), display: true)
        panel.ignoresMouseEvents = true
        let original = args["original"] as? String ?? ""
        let translation = args["translation"] as? String ?? ""
        label.stringValue = mode == "minutes" ? String((args["minutes"] as? String ?? "速记尚未生成").prefix(6000)) : "\(original)\n\(translation)"
        panel.alphaValue = 1; panel.orderFrontRegardless()
        hover = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let panel = self?.panel else { return }
            panel.alphaValue = panel.frame.contains(NSEvent.mouseLocation) ? 0.25 : 1
        }
    }
    deinit { hover?.invalidate(); panel?.orderOut(nil) }
}
