import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var macApp: MacAppChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    else { return }
    macApp = MacAppChannel(
      binaryMessenger: controller.engine.binaryMessenger, window: mainFlutterWindow)
    addCloseWindowItem()
  }

  /// ⌘W closes the window, as in other Mac apps; Flutter's main menu has no
  /// File menu to hold it.
  private func addCloseWindowItem() {
    guard let mainMenu = NSApp.mainMenu else { return }
    let file = NSMenu(title: "File")
    file.addItem(
      withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let item = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    item.submenu = file
    mainMenu.insertItem(item, at: min(1, mainMenu.numberOfItems))
  }

  /// Closing the window leaves takes and transcription running; the Dock
  /// icon and the menu bar item bring it back.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    guard !flag, let macApp else { return true }
    macApp.showWindow()
    return false
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return macApp?.confirmQuit() ?? super.applicationShouldTerminate(sender)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// Koe's app-level Mac controls, driven from Dart (`lib/platform/mac_app.dart`)
/// over `com.semanticcraft.koe/mac_app`: the menu bar item, keeping the Mac
/// awake while Koe records or transcribes, the question before quitting then,
/// and the space left for takes. Kept in this file while #389 changes the
/// Xcode project.
final class MacAppChannel: NSObject, NSMenuDelegate {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private var status = Status()
  private var activity: NSObjectProtocol?
  private var activityReason: String?
  private var takeItem: NSMenuItem?
  private var clock: Timer?
  private var quitting = false

  /// What Dart last reported; see `MacAppStatus` there.
  private struct Status {
    var state = "idle"
    var take: String?
    var elapsed: TimeInterval = 0
    var running = false
    var since = Date()
    var lines: [String] = []
    var actions: [(id: String, title: String)] = []
    var keepAwake: String?
    var quitMessage: String?
    var quitInfo = ""
    var saving = false
  }

  init(binaryMessenger: FlutterBinaryMessenger, window: NSWindow?) {
    channel = FlutterMethodChannel(
      name: "com.semanticcraft.koe/mac_app", binaryMessenger: binaryMessenger)
    self.window = window
    super.init()
    menu.delegate = self
    menu.autoenablesItems = false
    statusItem.menu = menu
    showState()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    // Dart may have reported before this handler existed.
    channel.invokeMethod("ready", arguments: nil)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "update":
      update(args)
      result(nil)
    case "availableSpace":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "invalid_argument", message: "参数无效", details: nil))
        return
      }
      result(availableSpace(at: path))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func update(_ args: [String: Any]) {
    var next = Status()
    next.state = args["state"] as? String ?? "idle"
    next.take = args["take"] as? String
    next.elapsed = ((args["elapsedMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
    next.running = args["running"] as? Bool ?? false
    next.lines = args["lines"] as? [String] ?? []
    next.actions = (args["actions"] as? [[String: String]] ?? []).compactMap { action in
      guard let id = action["id"], let title = action["title"] else { return nil }
      return (id, title)
    }
    next.keepAwake = args["keepAwake"] as? String
    next.quitMessage = args["quitMessage"] as? String
    next.quitInfo = args["quitInfo"] as? String ?? ""
    next.saving = args["saving"] as? Bool ?? false
    status = next
    showState()
    holdAwake(next.keepAwake)
    if clock != nil { rebuildMenu() }
  }

  private func showState() {
    let symbol: String
    let label: String
    switch status.state {
    case "recording":
      (symbol, label) = ("record.circle.fill", "Koe 正在录音")
    case "paused":
      (symbol, label) = ("pause.circle.fill", "Koe 录音已暂停")
    case "working":
      (symbol, label) = ("waveform.circle.fill", "Koe 正在处理")
    default:
      (symbol, label) = ("waveform", "Koe")
    }
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    image?.isTemplate = true
    statusItem.button?.image = image
    statusItem.button?.toolTip = label
  }

  /// Keeps the Mac from idle sleep, and Koe out of App Nap, while [reason]
  /// is set: recording and transcribing go on with the lid open and the
  /// window closed.
  private func holdAwake(_ reason: String?) {
    guard reason != activityReason else { return }
    if let activity {
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }
    activityReason = reason
    if let reason {
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .userInitiated], reason: reason)
    }
  }

  /// Space for new takes on the volume holding [path]. Space for important
  /// use counts files macOS can purge but is 0 on disk images and some
  /// external volumes, so the larger of the two counts, as in Shiyin
  /// (`Capture/Recorder.swift:405-410`).
  private func availableSpace(at path: String) -> Int64? {
    guard
      let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
      ])
    else { return nil }
    return max(
      values.volumeAvailableCapacityForImportantUsage ?? 0,
      Int64(values.volumeAvailableCapacity ?? 0))
  }

  func showWindow() {
    NSApp.activate(ignoringOtherApps: true)
    guard let window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }

  /// Asks before quitting while Koe records or transcribes. On 退出, Dart
  /// saves the take and stops listening, and Koe quits once it answers or
  /// after ten seconds. A take or text already being saved is waited for
  /// the same way, without asking. Nil when there is nothing to ask about
  /// or wait for.
  func confirmQuit() -> NSApplication.TerminateReply? {
    if quitting { return .terminateLater }
    if let message = status.quitMessage {
      let alert = NSAlert()
      alert.messageText = message
      alert.informativeText = status.quitInfo
      alert.addButton(withTitle: "退出")
      alert.addButton(withTitle: "取消")
      NSApp.activate(ignoringOtherApps: true)
      guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
    } else if !status.saving {
      return nil
    }
    quitting = true
    channel.invokeMethod("quit", arguments: nil) { [weak self] _ in self?.finishQuit() }
    // The app waits in the modal panel run loop mode until it is answered;
    // the common modes include it.
    perform(#selector(finishQuit), with: nil, afterDelay: 10, inModes: [.common])
    return .terminateLater
  }

  @objc private func finishQuit() {
    guard quitting else { return }
    quitting = false
    NSObject.cancelPreviousPerformRequests(
      withTarget: self, selector: #selector(finishQuit), object: nil)
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  // MARK: Menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuildMenu()
  }

  func menuWillOpen(_ menu: NSMenu) {
    let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      guard let self, let item = self.takeItem else { return }
      item.title = self.takeTitle()
    }
    RunLoop.main.add(clock, forMode: .common)
    self.clock = clock
  }

  func menuDidClose(_ menu: NSMenu) {
    clock?.invalidate()
    clock = nil
  }

  private func rebuildMenu() {
    menu.removeAllItems()
    takeItem = nil
    if status.take != nil {
      let item = NSMenuItem(title: takeTitle(), action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
      takeItem = item
    }
    for line in status.lines {
      let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    if !status.actions.isEmpty { menu.addItem(.separator()) }
    for action in status.actions {
      let item = NSMenuItem(title: action.title, action: #selector(choose(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = action.id
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let open = NSMenuItem(title: "打开 Koe", action: #selector(openWindow), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    menu.addItem(.separator())
    // Quits through applicationShouldTerminate, which asks first when it
    // should.
    menu.addItem(
      NSMenuItem(
        title: "退出 Koe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
  }

  private func takeTitle() -> String {
    guard let take = status.take else { return "" }
    let elapsed = status.elapsed + (status.running ? Date().timeIntervalSince(status.since) : 0)
    let seconds = Int(elapsed)
    let clock =
      seconds >= 3600
      ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
      : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    return "\(take)  \(clock)"
  }

  @objc private func choose(_ item: NSMenuItem) {
    guard let id = item.representedObject as? String else { return }
    // A take starts from the recording sheet, which needs the window.
    if id == "start" { showWindow() }
    channel.invokeMethod("menu", arguments: id)
  }

  @objc private func openWindow() {
    showWindow()
  }
}
