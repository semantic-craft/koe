#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

#if KOE_STANDALONE_SWIFTUI
@main
struct KoeNativeStandaloneApp: App {
  @StateObject private var host: KoeNativeHost

  init() {
    if CommandLine.arguments.contains("--verify-self") {
      Self.runSelfVerificationAndExit()
    }
    #if os(macOS)
    NSApplication.shared.setActivationPolicy(.regular)
    #endif
    let h = KoeNativeHost()
    if CommandLine.arguments.contains("--mute-tts") {
      h.interpreting.ttsEnabled = false
    }
    if h.playback.recordings.isEmpty || CommandLine.arguments.contains("--auto-demo") {
      h.sidebar.runSimulatedRealtimeSession()
    }
    _host = StateObject(wrappedValue: h)
  }

  var body: some Scene {
    WindowGroup("Koe (SwiftUI + Rust)") {
      #if os(macOS)
      KoeNativeHostView(host: host)
        .frame(minWidth: 1080, minHeight: 680)
        .onAppear {
          NSApplication.shared.activate(ignoringOtherApps: true)
        }
      #else
      KoeNativeHostView(host: host)
      #endif
    }
  }

  private static func runSelfVerificationAndExit() -> Never {
    Task { @MainActor in
      let exportDir = BeanTransportActor.defaultExportDirectory()
      let host = KoeNativeHost(exportDirectory: exportDir)
      host.interpreting.ttsEnabled = false
      guard let saved = await host.transport.simulateBeanRealtimePipeline(destinationDirectory: exportDir) else {
        fputs("FAIL: simulateBeanRealtimePipeline returned nil\n", stderr)
        exit(1)
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
      let opusData = (try? Data(contentsOf: saved.opusFileURL)) ?? Data()
      let wavData = (saved.playableWAVURL.flatMap { try? Data(contentsOf: $0) }) ?? Data()
      host.playback.jumpToMark(direction: .next)
      let firstJumpMs = host.playback.playbackState.positionMs
      host.playback.jumpToMark(direction: .next)
      let secondJumpMs = host.playback.playbackState.positionMs
      let keychainMode = KeychainStore().mode.rawValue
      let summary = """
      {"status":"ok","keychainMode":"\(keychainMode)","connected":\(host.sidebar.connectionPhase.isConnected),"recordingId":"\(saved.id.rawValue)","opusBytes":\(opusData.count),"wavBytes":\(wavData.count),"marks":\(saved.marks.map(\.rawValue)),"firstJumpMs":\(firstJumpMs),"secondJumpMs":\(secondJumpMs),"captionCount":\(host.interpreting.segments.count)}
      """
      print(summary)
      exit(0)
    }
    RunLoop.main.run()
    exit(0)
  }
}
#endif
