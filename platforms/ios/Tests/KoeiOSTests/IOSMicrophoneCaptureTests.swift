import AVFAudio
import KoeAppleCore
import XCTest
@testable import KoeiOSApp

final class TestMicrophone: MicrophoneSource, @unchecked Sendable {
    var permission: Bool? = true
    var clockNs: UInt64 = 1_000_000_000
    var inputUID = "phone"
    let center = NotificationCenter()
    let engine = AVAudioEngine()
    var receive: (@Sendable (CapturedPCM) -> Void)?
    private var observer: IOSCaptureRouteObserver?

    func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        if let permission { completion(permission) }
    }

    func start(inputID: String, expectedSampleRate: UInt32?, receive: @escaping @Sendable (CapturedPCM) -> Void,
               failed: @escaping @Sendable (String) -> Void) throws -> UInt32 {
        self.receive = receive
        observer = IOSCaptureRouteObserver(center: center, fence: AudioCallbackFence(), initialInputUID: inputUID,
                                           currentInputUID: { [weak self] in self?.inputUID }, failed: failed)
        observer?.observeConfiguration(of: engine)
        return 16_000
    }

    func stop() {
        observer?.stop()
        observer = nil
        receive = nil
    }
}

@MainActor
final class IOSMicrophoneCaptureTests: XCTestCase {
    private func fixture(_ body: (HostSessionStore, TestMicrophone, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let store = HostSessionStore(workspacePath: root.path, credentials: NativeCredentialsiOS(forceIsolated: true))
        let source = TestMicrophone()
        let coordinator = IOSHostCoordinator(store: store, actions: HostBridgeActions(),
                                             source: source, nowNanoseconds: { source.clockNs })
        coordinator.setScenePhase(.active)
        defer { coordinator.shutdown(); store.shutdown() }
        try await body(store, source, root)
    }

    private func waitFor(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try XCTUnwrap(condition() ? true : nil, message, file: file, line: line)
    }

    private func start(_ store: HostSessionStore) async throws -> String {
        store.send(.startMicrophone(inputId: "phone"))
        try await waitFor("已授权的采集应从 starting 进入 recording") {
            store.snapshot.microphone?.phase == "recording"
        }
        return try XCTUnwrap(store.snapshot.microphone?.recordId)
    }

    private func wav(_ root: URL, _ id: String) throws -> [UInt8] {
        Array(try Data(contentsOf: root.appendingPathComponent("audio/\(id).wav")).dropFirst(44))
    }

    func testDeniedPermissionFinishesPendingCaptureAndExplainsFailure() async throws {
        try await fixture { store, source, _ in
            source.permission = false
            store.send(.startMicrophone(inputId: "phone"))
            try await self.waitFor("权限拒绝应结束采集并显示麦克风权限提示") {
                store.snapshot.microphone == nil &&
                    [store.navigation.notice, store.navigation.effectiveError].compactMap { $0 }.contains { $0.contains("权限") }
            }
            XCTAssertEqual(store.lifecycle?.keepAwake, false)
            XCTAssertTrue(store.records.isEmpty)
        }
    }

    func testPollDrainsPCMAndResumeSavesBothEpochsInOrder() async throws {
        try await fixture { store, source, root in
            let id = try await self.start(store)
            let firstEpoch = try XCTUnwrap(source.receive)
            firstEpoch(CapturedPCM(samples: [1, 2], capturedStartNs: source.clockNs))
            firstEpoch(CapturedPCM(samples: [3, 4], capturedStartNs: source.clockNs + 125_000))
            try await self.waitFor("轮询应把两个有序 PCM 块送入 Rust") { store.snapshot.microphone?.nextSequence == 2 }
            store.performCaptureAction(.pause)
            try await self.waitFor("暂停应等待采集回调栅栏") { store.snapshot.microphone?.phase == "paused" }
            source.clockNs += 8_000_000_000
            store.performCaptureAction(.resume)
            try await self.waitFor("恢复应创建下一 epoch 并启动输入设备") {
                store.snapshot.microphone?.epoch == 1 && source.receive != nil
            }
            firstEpoch(CapturedPCM(samples: [99], capturedStartNs: source.clockNs))
            source.receive?(CapturedPCM(samples: [5, 6], capturedStartNs: source.clockNs))
            store.performCaptureAction(.end)
            try await self.waitFor("停止后应发布已保存的记录") { store.records.contains { $0.id == id } && store.snapshot.microphone == nil }
            XCTAssertEqual(try self.wav(root, id), [1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0])
        }
    }

    func testInputSwitchFencesProducerAndPreservesAcceptedSamples() async throws {
        try await fixture { store, source, root in
            let id = try await self.start(store)
            let send = try XCTUnwrap(source.receive)
            send(CapturedPCM(samples: [11], capturedStartNs: source.clockNs))
            let route = AVAudioSession.routeChangeNotification
            source.center.post(name: route, object: AVAudioSession.sharedInstance(), userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
            ])
            try await self.waitFor("输入未切换时应继续录制") { store.snapshot.microphone?.nextSequence == 1 }
            send(CapturedPCM(samples: [12], capturedStartNs: source.clockNs + 62_500))
            source.inputUID = "headset"
            source.center.post(name: route, object: AVAudioSession.sharedInstance(), userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            ])
            try await self.waitFor("设备切换后应保存已接收的音频并结束采集") { store.snapshot.microphone == nil && store.records.contains { $0.id == id } }
            XCTAssertEqual(try self.wav(root, id), [11, 0, 12, 0])
            store.send(.selectRecord(recordId: id))
            XCTAssertEqual(store.snapshot.detail?.status, "采集不完整")
        }
    }

    func testInterruptionFinishesCaptureAndNextSessionIgnoresOldCallbacks() async throws {
        try await fixture { store, source, root in
            let id = try await self.start(store)
            let old = try XCTUnwrap(source.receive)
            old(CapturedPCM(samples: [7], capturedStartNs: source.clockNs))
            let session = AVAudioSession.sharedInstance()
            source.center.post(name: AVAudioSession.interruptionNotification, object: session, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            ])
            try await self.waitFor("音频中断须收尾已录样本并释放音源") {
                store.snapshot.microphone == nil && source.receive == nil && store.records.contains { $0.id == id }
            }
            source.center.post(name: AVAudioSession.interruptionNotification, object: session, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            ])
            XCTAssertNil(store.snapshot.microphone)
            XCTAssertEqual(try self.wav(root, id), [7, 0])
            let nextID = try await self.start(store)
            old(CapturedPCM(samples: [99], capturedStartNs: source.clockNs))
            source.receive?(CapturedPCM(samples: [8], capturedStartNs: source.clockNs))
            store.send(.stopMicrophone)
            try await self.waitFor("中断后新录音可以独立保存") { store.snapshot.microphone == nil && store.records.contains { $0.id == nextID } }
            XCTAssertEqual(try self.wav(root, nextID), [8, 0])
        }
    }

    func testStoppedEngineOnUnchangedInputFinishesRecording() async throws {
        try await fixture { store, source, root in
            let id = try await self.start(store)
            source.receive?(CapturedPCM(samples: [13], capturedStartNs: source.clockNs))
            source.center.post(name: .AVAudioEngineConfigurationChange, object: source.engine)
            try await self.waitFor("引擎因硬件格式变化停止后，应保存尾块并结束录音") {
                store.snapshot.microphone == nil && store.records.contains { $0.id == id }
            }
            XCTAssertEqual(try self.wav(root, id), [13, 0])
        }
    }

    func testMonitorPublishesAvailableInputsAndNewDefaultAfterRouteChange() async throws {
        try await fixture { store, _, _ in
            let center = NotificationCenter()
            @MainActor func input(_ id: String, _ port: AVAudioSession.Port, isDefault: Bool = false) -> HostAudioInputDescriptor {
                HostAudioInputDescriptor(id: id, name: id, transport: IOSAudioInputMonitor.transport(for: port), isDefault: isDefault)
            }
            var inputs = [input("phone", .builtInMic, isDefault: true), input("headset", .bluetoothHFP),
                          input("dock", .usbAudio), input("jack", .headsetMic)]
            let monitor = IOSAudioInputMonitor(store: store, center: center, inputs: { inputs })
            monitor.start()
            defer { monitor.stop() }
            try await self.waitFor("启动时应同步四种可用输入") { store.captureStudio.studio.inputs.count == 4 }
            let devices = store.captureStudio.studio.inputs
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.transport) }),
                           ["phone": "built_in", "headset": "bluetooth", "dock": "usb", "jack": "external"])
            XCTAssertEqual(devices.filter(\.isDefault).map(\.id), ["phone"])
            inputs = [input("dock", .usbAudio, isDefault: true)]
            center.post(name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
            try await self.waitFor("移除的设备须消失，当前输入须成为默认") {
                store.captureStudio.studio.inputs.map(\.id) == ["dock"] && store.captureStudio.studio.inputs.first?.isDefault == true
            }
        }
    }
}
