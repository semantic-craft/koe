import CoreAudio
import Foundation

/// Heartbeats distinguish an unused microphone from an unavailable query.
final class MicrophoneUsers {
  var onChange: (([String: Any]) -> Void)?
  private var timer: Timer?
  private var watching = false
  func watch(_ on: Bool) {
    guard on != watching else { return }
    watching = on; timer?.invalidate(); timer = nil
    guard on else { return }
    guard #available(macOS 14.2, *) else {
      onChange?(["available": false, "users": []]); return
    }
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    RunLoop.main.add(timer, forMode: .common); self.timer = timer; check()
  }
  @available(macOS 14.2, *) private func check() {
    onChange?(Self.snapshot() ?? ["available": false, "users": []])
  }
  private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }
  private static func scalar(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
  }
  private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
    var address = address(selector, scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
    if size == 0 { return [] }
    var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else { return nil }
    return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
  }
  private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = address(selector), value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }
  @available(macOS 14.2, *) private static func snapshot() -> [String: Any]? {
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard let processes = objects(system, kAudioHardwarePropertyProcessObjectList),
          let input = scalar(system, kAudioHardwarePropertyDefaultInputDevice), input != 0,
          let defaultUID = string(input, kAudioDevicePropertyDeviceUID) else { return nil }
    var users = Set<String>(), devices = Set<String>()
    devices.insert("default:\(defaultUID)")
    for process in processes {
      guard let running = scalar(process, kAudioProcessPropertyIsRunningInput) else { return nil }
      if running == 0 { continue }
      guard let bundle = string(process, kAudioProcessPropertyBundleID),
            let inputs = objects(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput), !inputs.isEmpty else { return nil }
      users.insert(bundle)
      for device in inputs {
        guard let uid = string(device, kAudioDevicePropertyDeviceUID) else { return nil }
        devices.insert(uid)
      }
    }
    return ["available": true, "users": users.sorted(), "device": devices.sorted().joined(separator: "|")]
  }
  deinit { timer?.invalidate() }
}
