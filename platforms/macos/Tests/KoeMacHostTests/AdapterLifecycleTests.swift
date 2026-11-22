import CoreAudio
import CoreBluetooth
import Foundation
@testable import Koe
@testable import KoeAppleCore
import os
import Testing

@MainActor
private final class TrackingBleCentral: BleCentral {
    var state: CBManagerState = .poweredOn
    var isScanning = true
    weak var delegate: CBCentralManagerDelegate? {
        didSet { if delegate == nil { delegateClearedExplicitly = true } }
    }
    var delegateClearedExplicitly = false
    var stopScanCount = 0

    func connectedPeripherals(withServices services: [CBUUID]) -> [any BlePeripheral] { [] }
    func knownPeripherals(withIdentifiers ids: [UUID]) -> [any BlePeripheral] { [] }
    func connectPeer(_ peer: any BlePeripheral) {}
    func cancelPeer(_ peer: any BlePeripheral) {}
    func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) { isScanning = true }
    func stopScan() {
        isScanning = false
        stopScanCount += 1
    }
}

@MainActor
private final class TrackingBlePeripheral: BlePeripheral {
    let identifier = UUID()
    var name: String? = "soundcore Work"
    var state: CBPeripheralState = .connected
    weak var delegate: CBPeripheralDelegate? {
        didSet { if delegate == nil { delegateClearedExplicitly = true } }
    }
    var delegateClearedExplicitly = false
    var services: [CBService]?
    var canSendWriteWithoutResponse = true

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {}
    func isNotifying(_ characteristic: CBCharacteristic) -> Bool { false }
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 20 }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
}

@MainActor
private final class HangingPreparationRecognizer: LocalSpeechRecognizer {
    var prepareStarted = false
    var prepareCancelled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func prepare() async throws {
        prepareStarted = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled {
                    prepareCancelled = true
                    cont.resume()
                } else {
                    continuation = cont
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.prepareCancelled = true
                self?.continuation?.resume()
                self?.continuation = nil
            }
        }
        try Task.checkCancellation()
    }

    func finishIfPending() {
        continuation?.resume()
        continuation = nil
    }

    func start(
        locale: String,
        result: @escaping @MainActor (Result<LocalSpeechResult, Error>) -> Void
    ) async throws -> any LocalSpeechSession {
        throw LocalSpeechError("unused")
    }
}

@Suite("Apple adapter deinit and lifecycle cleanup")
@MainActor
struct AdapterLifecycleTests {
    @Test("BluetoothBridge deinit invalidates scheduled timers, stops scanning, and clears delegates")
    func bluetoothBridgeDeinitInvalidatesTimersAndClearsDelegates() {
        let central = TrackingBleCentral()
        let peripheral = TrackingBlePeripheral()
        let timer = Timer(timeInterval: 60, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: .common)
        weak var weakBridge: BluetoothBridge?

        do {
            let bridge = BluetoothBridge()
            weakBridge = bridge
            bridge.central = central
            central.delegate = bridge
            bridge.peripheral = peripheral
            peripheral.delegate = bridge
            bridge.outboundFlushTimer = timer
        }

        #expect(weakBridge == nil)
        #expect(!timer.isValid)
        #expect(central.stopScanCount == 1)
        #expect(central.delegate == nil)
        #expect(central.delegateClearedExplicitly)
        #expect(peripheral.delegate == nil)
        #expect(peripheral.delegateClearedExplicitly)
        timer.invalidate()
    }

    @Test("NativeLocalTranscription deinit cancels in-flight preparation task")
    func nativeLocalTranscriptionDeinitCancelsInFlightPreparation() async {
        let recognizer = HangingPreparationRecognizer()
        defer { recognizer.finishIfPending() }
        weak var weakAdapter: NativeLocalTranscription?

        do {
            let adapter = NativeLocalTranscription(recognizer: recognizer, drain: { Data() }, send: { _ in })
            weakAdapter = adapter
            adapter.prepare()
            let deadline = ContinuousClock.now + .seconds(1)
            while !recognizer.prepareStarted && ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(recognizer.prepareStarted)
        }

        let cancelDeadline = ContinuousClock.now + .milliseconds(300)
        while !recognizer.prepareCancelled && ContinuousClock.now < cancelDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakAdapter == nil)
        #expect(recognizer.prepareCancelled)
    }

    @Test("SystemCoreAudioPropertyListener releases lock across CoreAudio registration and rolls back concurrent stop")
    func systemCoreAudioPropertyListenerReleasesLockDuringRegistration() {
        let addedCount = OSAllocatedUnfairLock(initialState: 0)
        let removedCount = OSAllocatedUnfairLock(initialState: 0)
        let stopCompleted = DispatchSemaphore(value: 0)
        let stopRanDuringAdd = OSAllocatedUnfairLock(initialState: false)
        let queue = DispatchQueue(label: "koe.test.coreaudio")
        let listenerBox = OSAllocatedUnfairLock<SystemCoreAudioPropertyListener?>(initialState: nil)

        let listener = SystemCoreAudioPropertyListener(
            addListener: { _, _, _, _ in
                let count = addedCount.withLock { value -> Int in
                    value += 1
                    return value
                }
                if count == 1 {
                    DispatchQueue.global().async {
                        listenerBox.withLock { $0 }?.stopListening(queue: queue)
                        stopCompleted.signal()
                    }
                    let finishedWithoutDeadlock = stopCompleted.wait(timeout: .now() + .milliseconds(250)) == .success
                    stopRanDuringAdd.withLock { $0 = finishedWithoutDeadlock }
                }
                return noErr
            },
            removeListener: { _, _, _, _ in
                removedCount.withLock { $0 += 1 }
                return noErr
            }
        )
        listenerBox.withLock { $0 = listener }

        listener.startListening(queue: queue, onPropertyChanged: {})
        #expect(stopRanDuringAdd.withLock { $0 })
        #expect(addedCount.withLock { $0 } == 3)
        #expect(removedCount.withLock { $0 } == 3)
    }

    @Test("NativeLocalTranscription repeated prepare does not clobber readiness with cancellation error")
    func nativeLocalTranscriptionRepeatedPrepareDoesNotClobberReadiness() async {
        @MainActor
        final class SequencedPreparationRecognizer: LocalSpeechRecognizer {
            var callCount = 0
            var firstStarted = false
            var firstCancelled = false
            var secondFinished = false
            private var firstContinuation: CheckedContinuation<Void, Never>?

            func prepare() async throws {
                callCount += 1
                if callCount == 1 {
                    firstStarted = true
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { cont in
                            if Task.isCancelled {
                                firstCancelled = true
                                cont.resume()
                            } else {
                                firstContinuation = cont
                            }
                        }
                    } onCancel: {
                        Task { @MainActor [weak self] in
                            self?.firstCancelled = true
                            self?.firstContinuation?.resume()
                            self?.firstContinuation = nil
                        }
                    }
                    try Task.checkCancellation()
                } else {
                    await Task.yield()
                    secondFinished = true
                }
            }

            func finishFirstIfPending() {
                firstContinuation?.resume()
                firstContinuation = nil
            }

            func start(
                locale: String,
                result: @escaping @MainActor (Result<LocalSpeechResult, Error>) -> Void
            ) async throws -> any LocalSpeechSession {
                throw LocalSpeechError("unused")
            }
        }

        let recognizer = SequencedPreparationRecognizer()
        defer { recognizer.finishFirstIfPending() }
        var readinessStates: [String] = []
        let adapter = NativeLocalTranscription(
            recognizer: recognizer,
            drain: { Data() },
            send: { event in
                if case let .localAsrReadiness(state, _) = event {
                    readinessStates.append(state)
                }
            }
        )

        adapter.prepare()
        let startDeadline = ContinuousClock.now + .seconds(1)
        while !recognizer.firstStarted && ContinuousClock.now < startDeadline {
            await Task.yield()
        }
        #expect(recognizer.firstStarted)

        adapter.prepare()
        let finishDeadline = ContinuousClock.now + .seconds(1)
        while (!recognizer.firstCancelled || !recognizer.secondFinished || readinessStates.last != "ready") &&
            ContinuousClock.now < finishDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(30))

        #expect(recognizer.firstCancelled)
        #expect(recognizer.secondFinished)
        #expect(!readinessStates.contains("unavailable"))
        #expect(readinessStates.last == "ready")
    }
}
