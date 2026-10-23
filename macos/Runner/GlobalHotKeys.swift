import Carbon.HIToolbox

/// Koe's global hot keys, ⌃⌥⌘R and ⌃⌥⌘B, which work while another app is in
/// front and need no Accessibility permission (#405). Registered through
/// Carbon's `RegisterEventHotKey` exclusively, as Shiyin does
/// (`Services/GlobalHotKey.swift`), so a key another app holds is reported
/// as taken rather than firing in both apps.
final class GlobalHotKeys {
  /// Runs on the main thread with the name of the key pressed.
  var onPress: ((String) -> Void)?

  /// The names Dart uses and their keys; a key's hot key ID is its place
  /// here plus one.
  private static let keys: [(name: String, code: Int)] = [
    ("record", kVK_ANSI_R), ("highlight", kVK_ANSI_B),
  ]
  private static let signature: OSType = 0x4B6F_6548  // 'KoeH'
  private var held: [String: EventHotKeyRef] = [:]
  private var handler: EventHandlerRef?

  init() {
    var pressed = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr else { return status }
        let hotKeys = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
        return hotKeys.pressed(id) ? noErr : OSStatus(eventNotHandledErr)
      }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }

  deinit {
    _ = hold([])
    if let handler { RemoveEventHandler(handler) }
  }

  /// Holds the keys in [names] and lets the others go. Returns those another
  /// app holds, tried again on every call.
  func hold(_ names: Set<String>) -> [String] {
    for (name, ref) in held where !names.contains(name) {
      UnregisterEventHotKey(ref)
      held[name] = nil
    }
    var taken: [String] = []
    for (index, key) in Self.keys.enumerated() where names.contains(key.name) {
      guard held[key.name] == nil else { continue }
      var ref: EventHotKeyRef?
      let status = RegisterEventHotKey(
        UInt32(key.code), UInt32(cmdKey | optionKey | controlKey),
        EventHotKeyID(signature: Self.signature, id: UInt32(index + 1)),
        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
      if status == noErr, let ref {
        held[key.name] = ref
      } else {
        taken.append(key.name)
      }
    }
    return taken
  }

  private func pressed(_ id: EventHotKeyID) -> Bool {
    let index = Int(id.id) - 1
    guard id.signature == Self.signature, Self.keys.indices.contains(index) else { return false }
    onPress?(Self.keys[index].name)
    return true
  }
}
