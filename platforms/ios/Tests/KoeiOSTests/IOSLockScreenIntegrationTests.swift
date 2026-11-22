import KoeAppleCore
import MediaPlayer
import XCTest
@testable import KoeiOSApp

@MainActor
final class IOSLockScreenIntegrationTests: XCTestCase {
    func testHostPublishesSelectedRecordingToLockScreen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HostSessionStore(workspacePath: root.path, credentials: NativeCredentialsiOS(forceIsolated: true))
        let media = TestMediaCenter()
        let host = IOSHostCoordinator(store: store, actions: HostBridgeActions(), source: TestMicrophone(),
                                      allowsCoreBluetooth: false, mediaCenter: media, allowsLocalSpeech: false)
        defer { host.shutdown(); store.shutdown() }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ios-rich-snapshot", withExtension: "json"))
        XCTAssertTrue(store.loadDebugSnapshotFixtureJSON(try String(contentsOf: fixture, encoding: .utf8)))
        XCTAssertEqual(media.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, store.snapshot.detail?.title)
        host.shutdown()
        XCTAssertNil(media.nowPlayingInfo)
        XCTAssertTrue(media.handlers.isEmpty)
    }

    private func snapshot(id: String? = "rec-meeting-1", position: UInt64 = 12_345,
                          playing: Bool = true, asset: Bool = true) throws -> HostSnapshot {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ios-rich-snapshot", withExtension: "json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var playback = try XCTUnwrap(json["playback"] as? [String: Any])
        playback["recordId"] = id
        playback["positionMs"] = position
        playback["isPlaying"] = playing
        if asset {
            var plan = try XCTUnwrap(playback["asset"] as? [String: Any])
            plan["durationNs"] = 31_234_500_000
            playback["asset"] = plan
        } else {
            playback.removeValue(forKey: "asset")
        }
        json["playback"] = playback
        var detail = try XCTUnwrap(json["detail"] as? [String: Any])
        detail["title"] = "详情中的标题"
        json["detail"] = detail
        return try JSONDecoder().decode(HostSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testMetadataUsesMatchingRecordAndPublishesOnlyChangedValues() throws {
        let center = TestMediaCenter()
        let controller = IOSNowPlayingController(center: center) { _ in }
        defer { controller.shutdown() }
        let first = try snapshot()
        controller.sync(first)
        let info = try XCTUnwrap(center.nowPlayingInfo)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "详情中的标题")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Koe")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 31.2345)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12.345)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        let writes = center.writes
        controller.sync(first)
        XCTAssertEqual(center.writes, writes)
        controller.sync(try snapshot(id: "rec-note-1", position: 900, playing: false, asset: false))
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "录音豆低功耗设计笔记")
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double, 15)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0.9)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        controller.sync(try snapshot(id: "unknown", asset: false))
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Koe 录音")
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double, 0)
    }

    func testSixRemoteCommandsDispatchClampedRuntimeIntents() throws {
        let center = TestMediaCenter()
        var sent: [HostCommand] = []
        let controller = IOSNowPlayingController(center: center) { sent.append($0) }
        defer { controller.shutdown() }
        controller.sync(try snapshot())
        XCTAssertEqual(center.enabled, Set(IOSRemoteCommand.allCases))
        func perform(_ cmd: IOSRemoteCommand, _ value: Double? = nil) throws {
            XCTAssertEqual(try XCTUnwrap(center.handlers[cmd]).handler(value), .success)
        }
        try perform(.play)
        try perform(.pause)
        try perform(.toggle)
        try perform(.seek, -1)
        try perform(.seek, 4.125)
        try perform(.seek, 100)
        try perform(.skipBackward)
        try perform(.skipForward)
        controller.sync(try snapshot(position: 22_000, playing: false))
        try perform(.toggle)
        try perform(.skipBackward)
        try perform(.skipForward)
        // A shorter replacement asset can put the previous cursor beyond the new end.
        controller.sync(try snapshot(position: 40_000))
        try perform(.skipBackward)
        try perform(.skipForward)
        XCTAssertEqual(sent, [.playback(isPlaying: true), .playback(isPlaying: false), .playback(isPlaying: false),
                              .seek(positionMs: 0), .seek(positionMs: 4125), .seek(positionMs: 31234),
                              .seek(positionMs: 0), .seek(positionMs: 27345), .playback(isPlaying: true),
                              .seek(positionMs: 7000), .seek(positionMs: 31234), .seek(positionMs: 25000), .seek(positionMs: 31234)])
    }

    func testClearingAndReleasingControllerRetiresCommandTargets() throws {
        for explicitShutdown in [true, false] {
            let center = TestMediaCenter()
            var sent: [HostCommand] = []
            var controller: IOSNowPlayingController? = IOSNowPlayingController(center: center) { sent.append($0) }
            controller?.sync(try snapshot())
            let old = try XCTUnwrap(center.handlers[.play]).handler
            controller?.sync(try snapshot(id: nil))
            XCTAssertNil(center.nowPlayingInfo)
            XCTAssertTrue(center.enabled.isEmpty)
            XCTAssertNotEqual(old(nil), .success)
            controller?.sync(try snapshot())
            XCTAssertEqual(center.handlers.count, 6)
            if explicitShutdown { controller?.shutdown() }
            controller = nil
            XCTAssertNil(center.nowPlayingInfo)
            XCTAssertTrue(center.enabled.isEmpty && center.handlers.isEmpty)
            XCTAssertNotEqual(old(nil), .success)
            XCTAssertTrue(sent.isEmpty)
        }
    }

    func testOffMainThreadRemoteCommandDoesNotDeadlockAndDispatchesOnMainActor() async throws {
        var boundHandlers: [ObjectIdentifier: @Sendable (Double?) -> MPRemoteCommandHandlerStatus] = [:]
        let center = IOSSystemMediaCenter { remote, invoke in
            boundHandlers[ObjectIdentifier(remote)] = invoke
            return UUID()
        }
        var dispatched: [(HostCommand, Bool)] = []
        let controller = IOSNowPlayingController(center: center) { command in
            dispatched.append((command, Thread.isMainThread))
        }
        defer { controller.shutdown() }
        controller.sync(try snapshot())

        let seekInvoke = try XCTUnwrap(boundHandlers[ObjectIdentifier(MPRemoteCommandCenter.shared().changePlaybackPositionCommand)])
        let backgroundCompleted = DispatchSemaphore(value: 0)
        final class StatusBox: @unchecked Sendable { var status: MPRemoteCommandHandlerStatus? }
        let box = StatusBox()

        DispatchQueue.global(qos: .userInitiated).async {
            box.status = seekInvoke(4.125)
            backgroundCompleted.signal()
        }

        let waitResult = backgroundCompleted.wait(timeout: .now() + 0.5)
        XCTAssertEqual(waitResult, .success, "Off-main-thread remote command must not block waiting for the main thread")
        XCTAssertEqual(box.status, .success)

        let deadline = ContinuousClock.now + .seconds(2)
        while dispatched.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(dispatched.count, 1)
        XCTAssertEqual(dispatched.first?.0, .seek(positionMs: 4125))
        XCTAssertEqual(dispatched.first?.1, true)
    }
}

@MainActor
final class TestMediaCenter: IOSMediaCenter {
    struct Target {
        let token = UUID()
        let handler: IOSRemoteHandler
    }
    var handlers: [IOSRemoteCommand: Target] = [:]
    var enabled: Set<IOSRemoteCommand> = []
    var writes = 0
    var nowPlayingInfo: [String: Any]? { didSet { writes += 1 } }
    func setEnabled(_ value: Bool, for command: IOSRemoteCommand) {
        if value { enabled.insert(command) } else { enabled.remove(command) }
    }
    func addTarget(for command: IOSRemoteCommand, handler: @escaping IOSRemoteHandler) -> Any {
        XCTAssertNil(handlers[command])
        let target = Target(handler: handler)
        handlers[command] = target
        return target.token
    }
    func removeTarget(_ token: Any, for command: IOSRemoteCommand) {
        XCTAssertEqual(handlers[command]?.token, token as? UUID)
        handlers.removeValue(forKey: command)
    }
}
