import AVFoundation
import KoeAppleCore
import MediaPlayer
import os
import ViewInspector
import XCTest
@testable import KoeiOSApp

@MainActor
final class IOSPlaybackTests: XCTestCase {
    func testSessionRoutesPlaybackAndMicrophoneIndependently() throws {
        let owners = IOSAudioSession()
        let session = AVAudioSession.sharedInstance()
        defer {
            try? owners.setActive(false, for: .microphone)
            try? owners.setActive(false, for: .playback)
        }
        try owners.setActive(true, for: .playback)
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.categoryOptions, [])
        XCTAssertFalse(try owners.prepareInputDiscovery())
        XCTAssertEqual(session.category, .playback)
        try owners.setActive(true, for: .microphone)
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertTrue(session.categoryOptions.isSuperset(of: [.defaultToSpeaker, .allowBluetoothHFP]))
        try owners.setActive(false, for: .microphone)
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .default)
        XCTAssertEqual(session.categoryOptions, [])
    }

    private func fixture(audioSession: IOSAudioSession = IOSAudioSession(), mediaCenter: (any IOSMediaCenter)? = nil,
                         _ body: (HostSessionStore, IOSHostCoordinator, TestMicrophone) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("playback.wav")
        try writeTone(to: wav)
        let store = HostSessionStore(workspacePath: root.path, credentials: NativeCredentialsiOS(forceIsolated: true))
        let source = TestMicrophone()
        let host = IOSHostCoordinator(store: store, actions: HostBridgeActions(), source: source,
                                      audioSession: audioSession, allowsCoreBluetooth: false, mediaCenter: mediaCenter,
                                      nowNanoseconds: { source.clockNs })
        defer { host.shutdown(); store.shutdown() }
        store.send(.importFile(path: wav.path))
        XCTAssertEqual(store.snapshot.detail?.durationMs, 4000)
        host.setScenePhase(.active)
        try await body(store, host, source)
    }

    func testTappingTimestampOnIdleAudioStartsAtThatSegment() async throws {
        try await fixture { store, _, _ in
            let recordID = try XCTUnwrap(store.recordDetail.detail?.id)
            XCTAssertFalse(store.playback.isPlaying)
            let segment = SegmentSnapshot(id: "cue", text: "会议重点", startMs: 1200, endMs: 1800, timed: true)
            try IOSSegmentPlaybackButton(store: store, recordID: recordID, segment: segment)
                .inspect().find(ViewType.Button.self).tap()
            XCTAssertTrue(store.playback.isPlaying)
            XCTAssertEqual(store.playback.positionMs, 1200)
            try await until("AVPlayer 未从目标时码继续播放") {
                store.playback.isPlaying && store.playback.positionMs > 1200
            }
        }
    }

    private func writeTone(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                 channels: 1, interleaved: true))
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000))
        pcm.frameLength = pcm.frameCapacity
        let samples = try XCTUnwrap(pcm.int16ChannelData?.pointee)
        for frame in 0..<Int(pcm.frameLength) {
            samples[frame] = Int16(1000 * sin(Double(frame) * 2 * .pi * 440 / 16_000))
        }
        try file.write(from: pcm)
    }

    private func until(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                       _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try XCTUnwrap(condition() ? true : nil, message, file: file, line: line)
    }

    private func play(_ store: HostSessionStore) async throws {
        store.send(.playback(isPlaying: true))
        try await until("AVPlayer must advance the Rust playback position") {
            store.snapshot.playback.positionMs > 0 && store.snapshot.playback.isPlaying
        }
    }

    private func seekItem(_ store: HostSessionStore, host: IOSHostCoordinator, to position: UInt64) async throws -> AVPlayerItem {
        var jumped = false
        let center = NotificationCenter.default
        let token = center.addObserver(forName: .AVPlayerItemTimeJumped, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { jumped = true }
        }
        defer { center.removeObserver(token) }
        store.send(.seek(positionMs: position))
        try await until("AVPlayerItem must complete the requested seek") {
            guard jumped, let item = host.currentPlaybackItem else { return false }
            return abs(item.currentTime().seconds - Double(position) / 1000) < 0.15
        }
        return try XCTUnwrap(host.currentPlaybackItem)
    }

    private func enterBackground(_ host: IOSHostCoordinator, store: HostSessionStore) {
        XCTAssertTrue(store.snapshot.playback.isPlaying)
        XCTAssertEqual(store.snapshot.lifecycle?.keepAwake, false)
        host.setScenePhase(.background)
        XCTAssertFalse(store.isUISlicesActive)
    }

    func testSeekPauseResumeAndFinishWhileForegroundTimerIsStopped() async throws {
        let sessionActive = OSAllocatedUnfairLock(initialState: false)
        let session = IOSAudioSession { active in sessionActive.withLock { $0 = active } }
        try await fixture(audioSession: session) { store, host, _ in
            try await play(store)
            XCTAssertTrue(sessionActive.withLock { $0 })
            let item = try await seekItem(store, host: host, to: 2500)
            try await until("playback must advance after seeking") { store.snapshot.playback.positionMs > 2600 }
            store.send(.playback(isPlaying: false))
            try await until("pause must stop the native timebase") { item.timebase?.rate == 0 && !sessionActive.withLock { $0 } }
            store.send(.playback(isPlaying: true))
            try await until("resume must restart the native timebase") { item.timebase?.rate == 1 && sessionActive.withLock { $0 } }
            enterBackground(host, store: store)
            try await until("EOF must publish the final position with foreground polling disabled") {
                !store.snapshot.playback.isPlaying && store.snapshot.playback.positionMs == 4000
            }
            XCTAssertFalse(sessionActive.withLock { $0 })
            XCTAssertNil(store.nativeError)
        }
    }

    func testRemotePauseKeepsLivePositionAndResumeDrivesBackgroundPlayer() async throws {
        let center = TestMediaCenter()
        try await fixture(mediaCenter: center) { store, host, _ in
            try await play(store)
            let item = try await seekItem(store, host: host, to: 850)
            enterBackground(host, store: store)
            let frozenPosition = store.snapshot.playback.positionMs
            try await until("AVPlayer should advance while foreground polling sleeps") {
                item.currentTime().seconds * 1000 > Double(frozenPosition) + 500
            }
            XCTAssertEqual(try XCTUnwrap(center.handlers[.pause]).handler(nil), .success)
            try await until("Remote pause must stop the native timebase") { item.timebase?.rate == 0 }
            XCTAssertFalse(store.snapshot.playback.isPlaying)
            XCTAssertGreaterThan(store.snapshot.playback.positionMs, frozenPosition + 400)
            XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double,
                           Double(store.snapshot.playback.positionMs) / 1000)
            XCTAssertEqual(try XCTUnwrap(center.handlers[.play]).handler(nil), .success)
            try await until("Remote play must restart the native timebase") { item.timebase?.rate == 1 }
        }
    }

    func testFailedItemPublishesErrorWithForegroundTimerStopped() async throws {
        let sessionActive = OSAllocatedUnfairLock(initialState: false)
        let session = IOSAudioSession { active in sessionActive.withLock { $0 = active } }
        try await fixture(audioSession: session) { store, host, _ in
            try await play(store)
            XCTAssertTrue(sessionActive.withLock { $0 })
            let item = try await seekItem(store, host: host, to: 800)
            try await until("playback must advance after seeking") { store.snapshot.playback.positionMs > 900 }
            enterBackground(host, store: store)
            let error = NSError(domain: "IOSPlaybackTests", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Audio decoding failed"])
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item,
                                            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: error])
            try await until("failure notification must stop Rust playback and surface the native error") {
                !store.snapshot.playback.isPlaying && store.nativeError?.contains(error.localizedDescription) == true
            }
            XCTAssertFalse(sessionActive.withLock { $0 })
        }
    }

    func testInterruptionPausesWithoutForegroundPolling() async throws {
        let sessionActive = OSAllocatedUnfairLock(initialState: false)
        let session = IOSAudioSession { active in sessionActive.withLock { $0 = active } }
        try await fixture(audioSession: session) { store, host, _ in
            try await play(store)
            XCTAssertTrue(sessionActive.withLock { $0 })
            enterBackground(host, store: store)
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            ])
            try await until("interruption must stop playback before EOF") {
                !store.snapshot.playback.isPlaying && store.snapshot.playback.positionMs < 4000
            }
            XCTAssertFalse(sessionActive.withLock { $0 })
        }
    }

    func testMissingAssetStopsPlaybackAndSurfacesError() async throws {
        try await fixture { store, _, _ in
            let path = try XCTUnwrap(store.snapshot.playback.asset?.audioPath)
            store.send(.playback(isPlaying: true))
            try FileManager.default.removeItem(atPath: path)
            // Speech readiness can project a missing asset before AVPlayer reports the read failure.
            store.send(.localAsrReadiness(state: "unavailable", message: "此设备暂不支持本机识别。"))
            XCTAssertNil(store.snapshot.playback.asset)
            try await until("missing WAV must stop Rust playback and surface the native error") {
                !store.snapshot.playback.isPlaying && store.nativeError != nil
            }
        }
    }

    func testCorruptAssetStopsPlaybackAndSurfacesError() async throws {
        try await fixture { store, _, _ in
            let path = try XCTUnwrap(store.snapshot.playback.asset?.audioPath)
            try Data("corrupt".utf8).write(to: URL(fileURLWithPath: path))
            store.send(.playback(isPlaying: true))
            try await until("invalid WAV must stop Rust playback and surface the native error") {
                !store.snapshot.playback.isPlaying && store.nativeError != nil
            }
        }
    }

    func testFinishingPlaybackWhileRecordingKeepsCaptureReceivingPCM() async throws {
        let sessionActive = OSAllocatedUnfairLock(initialState: false)
        let session = IOSAudioSession { active in sessionActive.withLock { $0 = active } }
        try await fixture(audioSession: session) { store, _, source in
            let id = try XCTUnwrap(store.snapshot.playback.recordId)
            store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true))
            try await until("microphone should be actively recording") { store.snapshot.microphone?.phase == "recording" }
            try session.setActive(true, for: .microphone)
            store.send(.selectRecord(recordId: id))
            try await play(store)
            store.send(.seek(positionMs: 3400))
            try await until("EOF should settle playback during capture") {
                !store.snapshot.playback.isPlaying && store.snapshot.playback.positionMs == 4000
            }
            XCTAssertTrue(sessionActive.withLock { $0 }, "Playback EOF must preserve the microphone’s audio session")
            let write = try XCTUnwrap(source.receive)
            write(CapturedPCM(samples: [123], capturedStartNs: source.clockNs))
            try await until("capture should ingest PCM after EOF") { store.snapshot.microphone?.nextSequence == 1 }
            store.send(.captureAction(action: .end))
            try await until("recording must finalize") { store.snapshot.microphone == nil }
            try session.setActive(false, for: .microphone)
            XCTAssertFalse(sessionActive.withLock { $0 }, "Stopping the last audio source must release the session")
        }
    }
}
