import CoreAudio
import Foundation

/// The apps using the microphone, by bundle ID, for Koe's meeting prompts
/// (#406). Core Audio's process objects tell without a permission from
/// macOS 14.2; they are checked every 2 seconds, as Shiyin does
/// (`Services/MeetingDetector.swift`). Which apps are meeting apps is
/// Dart's to say.
final class MicrophoneUsers {
  /// Runs on the main thread with the bundle IDs whenever they change, and
  /// once when watching starts.
  var onChange: (([String]) -> Void)?
  private var timer: Timer?
  private var last: [String]?

  func watch(_ on: Bool) {
    guard on != (timer != nil) else { return }
    timer?.invalidate()
    timer = nil
    last = nil
    guard on else { return }
    guard #available(macOS 14.2, *) else { return }
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    check()
  }

  @available(macOS 14.2, *)
  private func check() {
    let users = Self.users()
    guard users != last else { return }
    last = users
    onChange?(users)
  }

  @available(macOS 14.2, *)
  private static func users() -> [String] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
      return []
    }
    var objects = [AudioObjectID](
      repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else {
      return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    let users = objects.prefix(count).compactMap { object in
      isRunningInput(object) ? bundleID(object) : nil
    }
    return Set(users).sorted()
  }

  @available(macOS 14.2, *)
  private static func isRunningInput(_ object: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningInput,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
      && value != 0
  }

  @available(macOS 14.2, *)
  private static func bundleID(_ object: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyBundleID,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    let bundleID = value.takeRetainedValue() as String
    return bundleID.isEmpty ? nil : bundleID
  }
}
