import Cocoa

/// A question put to the user while another app is in front, such as
/// whether to record the meeting that app just started (#406): a small
/// panel at the top right of the screen that leaves that app active and
/// closes by itself after 30 seconds, as Shiyin's `MeetingPromptPanel`.
final class PromptPanel: NSObject {
  /// Runs with the id of the button pressed, once the panel has closed.
  var onChoose: ((String) -> Void)?
  private var panel: NSPanel?
  private var closing: Timer?

  /// Shows [message] with [actions] as buttons, the last one the answer
  /// expected, in place of the panel shown.
  func show(message: String, actions: [(id: String, title: String)]) {
    close()
    let width: CGFloat = 360
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
    icon.contentTintColor = .controlAccentColor
    let text = NSTextField(wrappingLabelWithString: message)
    text.preferredMaxLayoutWidth = width - 32 - 28
    let question = NSStackView(views: [icon, text])
    question.alignment = .top
    question.spacing = 8

    let buttons = actions.enumerated().map { index, action in
      let button = NSButton(title: action.title, target: self, action: #selector(choose(_:)))
      button.identifier = NSUserInterfaceItemIdentifier(action.id)
      if index == actions.count - 1 {
        button.keyEquivalent = "\r"
        button.bezelColor = .controlAccentColor
      }
      return button
    }
    let answers = NSStackView(views: buttons)
    answers.spacing = 8

    let content = NSStackView(views: [question, answers])
    content.orientation = .vertical
    content.alignment = .trailing
    content.spacing = 12
    content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    content.widthAnchor.constraint(equalToConstant: width).isActive = true
    question.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered,
      defer: false)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      panel.standardWindowButton(button)?.isHidden = true
    }
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.contentView = content
    panel.setContentSize(content.fittingSize)
    if let screen = NSScreen.main?.visibleFrame {
      panel.setFrameOrigin(
        NSPoint(
          x: screen.maxX - panel.frame.width - 16, y: screen.maxY - panel.frame.height - 16))
    }
    panel.orderFrontRegardless()
    self.panel = panel

    let closing = Timer(timeInterval: 30, repeats: false) { [weak self] _ in self?.close() }
    RunLoop.main.add(closing, forMode: .common)
    self.closing = closing
  }

  func close() {
    closing?.invalidate()
    closing = nil
    panel?.orderOut(nil)
    panel = nil
  }

  @objc private func choose(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue else { return }
    close()
    onChoose?(id)
  }
}
