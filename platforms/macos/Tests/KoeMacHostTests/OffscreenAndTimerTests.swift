import AppKit
import AVFoundation
import Foundation
import KoeAppleShared
import Observation
import SwiftUI
import Testing
@testable import Koe

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
private func armObservation(_ read: @escaping @MainActor () -> Void) -> ObservationCounter {
    let counter = ObservationCounter()
    withObservationTracking {
        read()
    } onChange: {
        counter.increment()
    }
    return counter
}

@MainActor
private final class CountingHostingView<Content: View>: NSHostingView<Content> {
    var layoutPasses = 0

    override func layout() {
        super.layout()
        layoutPasses += 1
    }
}

private final class TestWorkspaceWindow: NSWindow {
    var simulatedMiniaturized = false

    override var isMiniaturized: Bool {
        simulatedMiniaturized || super.isMiniaturized
    }
}

private final class SteppingAVPlayer: AVPlayer {
    var simulatedTime: CMTime = .zero
    private var simulatedPlaying = false

    override func currentTime() -> CMTime {
        simulatedTime
    }

    override var rate: Float {
        get { simulatedPlaying ? 1.0 : 0.0 }
        set { simulatedPlaying = newValue > 0 }
    }

    override func play() {
        simulatedPlaying = true
    }

    override func pause() {
        simulatedPlaying = false
    }
}

private final class MockCoreAudioPropertyListener: CoreAudioPropertyListening, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var listenerQueue: DispatchQueue?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startListening(queue: DispatchQueue, onPropertyChanged: @escaping @Sendable () -> Void) {
        lock.lock()
        startCount += 1
        listenerQueue = queue
        callback = onPropertyChanged
        lock.unlock()
    }

    func stopListening(queue: DispatchQueue) {
        lock.lock()
        stopCount += 1
        callback = nil
        listenerQueue = nil
        lock.unlock()
    }

    func firePropertyChange() {
        lock.lock()
        let handler = callback
        let queue = listenerQueue
        lock.unlock()
        if let queue, let handler {
            queue.async { handler() }
        } else {
            handler?()
        }
    }
}

@Suite("Serialized macOS window and audio host suites", .serialized)
enum SerializedMacHostSuites {}

extension SerializedMacHostSuites {
@Suite("Offscreen window gate, batched capture drain, and CoreAudio input monitor", .serialized)
struct OffscreenAndTimerTests {
    @MainActor
    private func createPlayableSixSecondRecord(in store: HostSessionStore) throws -> String {
        let nowSec: UInt64 = 1_800_100_000
        store.send("start_microphone", ["inputId": "fixture", "clockNs": 1_000_000_000], nowEpochSec: nowSec)
        let mic = try #require(store.snapshot.microphone)
        store.send("microphone_started", [
            "recordId": mic.recordId,
            "sessionId": mic.sessionId,
            "lane": "microphone",
            "sampleRate": 16_000
        ], nowEpochSec: nowSec)
        let halfSecondSamples = [Int16](repeating: 900, count: 8_000)
        for seq: UInt64 in 0..<12 {
            let receipt = store.ingestMicrophonePCM(
                recordId: mic.recordId,
                sessionId: mic.sessionId,
                lane: "microphone",
                sequence: seq,
                epoch: 0,
                capturedStartNs: 1_000_000_000 + seq * 500_000_000,
                samples: halfSecondSamples,
                nowEpochSec: nowSec
            )
            #expect(receipt.status == .accepted)
        }
        store.refreshSnapshot(nowEpochSec: nowSec)
        store.send("stop_microphone", nowEpochSec: nowSec + 1)
        store.send("microphone_stopped", [
            "recordId": mic.recordId,
            "sessionId": mic.sessionId,
            "lane": "microphone",
            "sequence": 12,
            "epoch": 0
        ], nowEpochSec: nowSec + 1)
        return mic.recordId
    }

    @MainActor
    private func waitUntil(
        timeoutSeconds: Double = 2.0,
        tick: @MainActor () -> Void = {},
        predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutSeconds * 1000))
        while !predicate(), ContinuousClock.now < deadline {
            tick()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    @Test("Closed and miniaturized workspace windows gate UI slices and layout passes during playback ticks, then reconcile on reopen")
    @MainActor
    func offscreenWindowGateSuppressesPlaybackTicksAndReconcilesOnWake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-offscreen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HostSessionStore(workspacePath: root.path)
        let player = SteppingAVPlayer()
        let playback = NativePlayback(player: player)
        let delegate = KoeAppDelegate(playback: playback, defaultInputsProvider: { [] })
        delegate.store = store

        let frame = NSRect(x: -16000, y: -16000, width: 1040, height: 680)
        let window = TestWorkspaceWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.collectionBehavior = [.ignoresCycle, .transient]
        let hostingView = CountingHostingView(rootView: KoeWorkspaceRootView(store: store))
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        window.contentView = hostingView

        defer {
            window.orderOut(nil)
            delegate.store = nil
            playback.stop()
            store.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        let recordId = try createPlayableSixSecondRecord(in: store)
        store.send("select_record", ["recordId": recordId])
        store.send("playback", ["isPlaying": true])

        KoeWindowPresenter.presentWindow(window, activateApp: false)
        #expect(window.isVisible)
        #expect(store.isUISlicesActive)

        let itemReady = await waitUntil(tick: { playback.tick() }) {
            player.currentItem?.status == .readyToPlay
        }
        #expect(itemReady)
        playback.tick()

        hostingView.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(40))
        hostingView.layoutSubtreeIfNeeded()

        let visibleSidebarProbe = armObservation { _ = store.sidebar }
        let visibleNavProbe = armObservation { _ = store.navigation }
        let visiblePlaybackProbe = armObservation { _ = store.playback }
        player.simulatedTime = CMTime(value: 250, timescale: 1000)
        playback.tick()
        #expect(store.playback.positionMs == 250)
        #expect(visiblePlaybackProbe.count == 1)
        #expect(visibleSidebarProbe.count == 0)
        #expect(visibleNavProbe.count == 0)

        hostingView.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
        hostingView.layoutSubtreeIfNeeded()

        window.close()
        #expect(!window.isVisible)
        #expect(!store.isUISlicesActive)

        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutPasses = 0
        let closedPlaybackProbe = armObservation { _ = store.playback }
        let closedSidebarProbe = armObservation { _ = store.sidebar }

        for tickIndex in 1...10 {
            player.simulatedTime = CMTime(value: Int64(tickIndex * 500), timescale: 1000)
            playback.tick()
            try? await Task.sleep(for: .milliseconds(5))
            hostingView.layoutSubtreeIfNeeded()
        }

        #expect(store.snapshot.playback.positionMs == 5_000)
        #expect(!store.isUISlicesActive)
        #expect(store.playback.positionMs == 250)
        #expect(closedPlaybackProbe.count == 0)
        #expect(closedSidebarProbe.count == 0)
        #expect(hostingView.layoutPasses == 0)

        KoeWindowPresenter.presentWindow(window, activateApp: false)
        #expect(window.isVisible)
        #expect(store.isUISlicesActive)
        #expect(store.playback.positionMs == 5_000)

        window.simulatedMiniaturized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        #expect(!store.isUISlicesActive)

        let miniPlaybackProbe = armObservation { _ = store.playback }
        player.simulatedTime = CMTime(value: 5_500, timescale: 1000)
        playback.tick()
        #expect(store.snapshot.playback.positionMs == 5_500)
        #expect(store.playback.positionMs == 5_000)
        #expect(miniPlaybackProbe.count == 0)

        window.simulatedMiniaturized = false
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        #expect(store.isUISlicesActive)
        #expect(store.playback.positionMs == 5_500)
    }

    @Test("Batched dual-lane NativeCapture drain ingests 16 chunks with a single snapshot refresh and preserves lane rejection fences")
    @MainActor
    func batchedDualLaneCaptureDrainCoalescesSnapshotRefreshAndFencesRejections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-batch-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HostSessionStore(workspacePath: root.path)
        let micSource = FakeMicrophone()
        let sysSource = FakeSystemAudio()
        sysSource.clock = { micSource.clockNs }
        let capture = NativeCapture(source: micSource, systemSource: sysSource, nowNanoseconds: { micSource.clockNs })
        capture.store = store
        var snapshotCallbacks = 0
        store.onSnapshotChanged = { _ in
            snapshotCallbacks += 1
            capture.apply()
        }
        defer {
            store.onSnapshotChanged = nil
            store.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        store.send("start_microphone", ["inputId": "fixture", "includeSystem": true])
        micSource.permission?(true)
        sysSource.authorization?(.authorized)
        let started = await waitUntil(tick: { capture.apply() }) {
            store.snapshot.microphone?.phase == "recording"
        }
        #expect(started)
        let recordId = try #require(store.snapshot.microphone?.recordId)

        snapshotCallbacks = 0
        for index in 1...8 {
            micSource.receive?(Array(repeating: Int16(index), count: 160))
            sysSource.receive(Array(repeating: Int16(100 + index), count: 480))
        }
        capture.apply()

        #expect(store.snapshot.microphone?.lanes["microphone"]?.nextSequence == 8)
        #expect(store.snapshot.microphone?.lanes["system"]?.nextSequence == 8)
        #expect(snapshotCallbacks == 1)
        #expect(store.activeCapture != nil)

        store.send("stop_microphone")
        capture.apply()
        #expect(store.snapshot.microphone == nil)

        func readPCMInt16(_ assetName: String) throws -> [Int16] {
            let bytes = Array(try Data(contentsOf: root.appendingPathComponent("audio/\(assetName).wav")).dropFirst(44))
            return stride(from: 0, to: bytes.count, by: 2).map { Int16(bytes[$0]) | (Int16(bytes[$0 + 1]) << 8) }
        }
        #expect(try readPCMInt16(recordId) == (1...8).flatMap { Array(repeating: Int16($0), count: 160) })
        #expect(try readPCMInt16("\(recordId)-system") == (1...8).flatMap { Array(repeating: Int16(100 + $0), count: 480) })

        store.send("start_microphone", ["inputId": "fixture", "includeSystem": true])
        micSource.permission?(true)
        sysSource.authorization?(.authorized)
        let secondStarted = await waitUntil(tick: { capture.apply() }) {
            store.snapshot.microphone?.phase == "recording"
        }
        #expect(secondStarted)
        let secondRecordId = try #require(store.snapshot.microphone?.recordId)

        micSource.receive?(Array(repeating: 11, count: 160))
        micSource.receive?(Array(repeating: 12, count: 160))
        micSource.emit?(CapturedPCM(samples: Array(repeating: 99, count: 160), capturedStartNs: micSource.clockNs - 1))
        micSource.receive?(Array(repeating: 88, count: 160))
        sysSource.receive(Array(repeating: 21, count: 480))
        sysSource.receive(Array(repeating: 22, count: 480))
        capture.apply()

        #expect(store.snapshot.microphone?.phase == "recording")
        #expect(store.snapshot.microphone?.lanes["microphone"]?.stopped == true)
        #expect(store.snapshot.microphone?.lanes["microphone"]?.nextSequence == 2)
        #expect(store.snapshot.microphone?.lanes["system"]?.stopped == false)
        #expect(store.snapshot.microphone?.lanes["system"]?.nextSequence == 2)

        store.send("stop_microphone")
        capture.apply()
        #expect(store.snapshot.microphone == nil)
        #expect(try readPCMInt16(secondRecordId) == [11, 12].flatMap { Array(repeating: Int16($0), count: 160) })
        #expect(try readPCMInt16("\(secondRecordId)-system") == [21, 22].flatMap { Array(repeating: Int16($0), count: 480) })
    }

    @Test("CoreAudioInputMonitor debounces property bursts and avoids steady-state HAL queries when clean")
    @MainActor
    func coreAudioMonitorDebouncesBurstsAndSkipsSteadyStateQueries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-coreaudio-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = HostSessionStore(workspacePath: root.path)
        let mockListener = MockCoreAudioPropertyListener()
        let monitor = CoreAudioInputMonitor(listener: mockListener, debounceInterval: .milliseconds(25))

        let builtIn = MicrophoneInput(id: "built-in", name: "MacBook Pro 麦克风", transport: "built_in", isDefault: true)
        let builtInSecondary = MicrophoneInput(id: "built-in", name: "MacBook Pro 麦克风", transport: "built_in", isDefault: false)
        let usbMic = MicrophoneInput(id: "usb-mic", name: "Shure MV7", transport: "usb", isDefault: true)
        var simulatedInputs = [builtIn]
        var providerQueries = 0

        let delegate = KoeAppDelegate(
            playback: NativePlayback(),
            audioInputMonitor: monitor,
            defaultInputsProvider: {
                providerQueries += 1
                return simulatedInputs
            }
        )
        defer {
            delegate.store = nil
            store.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        delegate.store = store
        #expect(providerQueries == 1)
        #expect(mockListener.startCount == 1)
        #expect(store.snapshot.capture.inputs.map(\.id) == ["built-in"])

        for _ in 0..<10 {
            delegate.syncAudioInputsIfNeeded(force: false)
        }
        #expect(providerQueries == 1)

        simulatedInputs = [builtInSecondary, usbMic]
        for _ in 0..<5 {
            mockListener.firePropertyChange()
        }

        let updated = await waitUntil(timeoutSeconds: 1.5) {
            store.snapshot.capture.inputs.count == 2
        }
        #expect(updated)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(providerQueries == 2)
        #expect(store.snapshot.capture.inputs.map(\.id) == ["usb-mic", "built-in"])
        #expect(store.snapshot.capture.selectedSource == "input:usb-mic")
        #expect(store.snapshot.capture.selectedBadge == "USB 外接")

        delegate.store = nil
        #expect(mockListener.stopCount == 1)

        simulatedInputs = [builtIn]
        mockListener.firePropertyChange()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(providerQueries == 2)
    }
}
}
