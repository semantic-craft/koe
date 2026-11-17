import Foundation
import KoeAppleShared

struct LocalSpeechResult: Equatable {
    let text: String
    let startMs: UInt64
    let endMs: UInt64
    let isFinal: Bool
}

@MainActor
protocol LocalSpeechSession: AnyObject {
    func append(_ samples: [Int16]) throws
    func finish() async throws
    func cancel() async
}

@MainActor
protocol LocalSpeechRecognizer {
    func prepare() async throws
    func start(locale: String, result: @escaping @MainActor (Result<LocalSpeechResult, Error>) -> Void) async throws -> any LocalSpeechSession
}

struct LocalSpeechError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum LocalSpeechEffect: Equatable {
    case start(UInt64, String)
    case audio(UInt64, [Int16])
    case finish(UInt64)
    case cancel(UInt64)

    static func decodeBinary(_ data: Data) throws -> [LocalSpeechEffect] {
        guard !data.isEmpty else { return [] }
        var effects: [LocalSpeechEffect] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.endIndex - offset >= 13 else {
                throw LocalSpeechError("离线转写任务帧不完整。")
            }
            let kind = data[offset]
            var opId: UInt64 = 0
            for i in 0..<8 {
                opId |= UInt64(data[offset + 1 + i]) << (i * 8)
            }
            var payloadLen = 0
            for i in 0..<4 {
                payloadLen |= Int(data[offset + 9 + i]) << (i * 8)
            }
            offset += 13
            guard payloadLen >= 0, data.endIndex - offset >= payloadLen else {
                throw LocalSpeechError("离线转写任务长度无效。")
            }
            let payload = data.subdata(in: offset..<(offset + payloadLen))
            offset += payloadLen
            switch kind {
            case 1:
                guard let locale = String(data: payload, encoding: .utf8) else {
                    throw LocalSpeechError("离线转写语言标识无效。")
                }
                effects.append(.start(opId, locale))
            case 2:
                guard payloadLen.isMultiple(of: 2) else {
                    throw LocalSpeechError("离线转写音频长度无效。")
                }
                var samples: [Int16] = []
                samples.reserveCapacity(payloadLen / 2)
                var i = 0
                while i + 1 < payloadLen {
                    let lo = UInt16(payload[payload.startIndex + i])
                    let hi = UInt16(payload[payload.startIndex + i + 1]) << 8
                    samples.append(Int16(bitPattern: lo | hi))
                    i += 2
                }
                effects.append(.audio(opId, samples))
            case 3:
                guard payloadLen == 0 else {
                    throw LocalSpeechError("离线转写结束帧长度无效。")
                }
                effects.append(.finish(opId))
            case 4:
                guard payloadLen == 0 else {
                    throw LocalSpeechError("离线转写取消帧长度无效。")
                }
                effects.append(.cancel(opId))
            default:
                throw LocalSpeechError("未知的离线转写任务类型。")
            }
        }
        return effects
    }
}

@MainActor
final class NativeLocalTranscription {
    weak var store: HostSessionStore? {
        didSet {
            shutdown()
            if store != nil { prepare() }
        }
    }
    private let recognizer: any LocalSpeechRecognizer
    private let drain: (() throws -> Data)?
    private let sendEvent: ((HostAdapterEvent) -> Void)?
    private var worker: Task<Void, Never>?
    private var readiness: Task<Void, Never>?
    private var cancellation: Task<Void, Never>?
    private var session: (any LocalSpeechSession)?
    private var operation: UInt64?
    private var epoch: UInt64 = 0
    private var deadline: ContinuousClock.Instant?
    private let now: () -> ContinuousClock.Instant
    private let operationTimeout: Duration

    init(
        recognizer: (any LocalSpeechRecognizer)? = nil,
        drain: (() throws -> Data)? = nil,
        send: ((HostAdapterEvent) -> Void)? = nil,
        now: @escaping () -> ContinuousClock.Instant = { .now },
        operationTimeout: Duration = .seconds(30)
    ) {
        self.recognizer = recognizer ?? makeLocalSpeechRecognizer()
        self.drain = drain
        self.sendEvent = send
        self.now = now
        self.operationTimeout = operationTimeout
    }

    func prepare() {
        guard readiness == nil else { return }
        let currentEpoch = epoch
        send(.localAsrReadiness(state: "preparing", message: "正在准备中文离线转写。"))
        readiness = Task { [weak self] in
            guard let self else { return }
            do {
                try await recognizer.prepare()
                try Task.checkCancellation()
                guard epoch == currentEpoch else { return }
                send(.localAsrReadiness(state: "ready", message: "中文离线转写已就绪。"))
            } catch {
                guard epoch == currentEpoch else { return }
                send(.localAsrReadiness(state: "unavailable", message: error.localizedDescription))
            }
        }
    }

    func apply() {
        guard worker == nil else {
            if let deadline, now() >= deadline {
                if let operation {
                    send(.localAsrFailed(operationId: operation, message: "离线转写等待系统响应超时；原始录音仍会保存。"))
                }
                interrupt()
            }
            return
        }
        do {
            let data = try drain?() ?? store?.drainLocalASREffectsData() ?? Data()
            let effects = try LocalSpeechEffect.decodeBinary(data)
            guard !effects.isEmpty else { return }
            let currentEpoch = epoch
            worker = Task { [weak self] in
                guard let self else { return }
                await process(effects, epoch: currentEpoch)
                worker = nil
            }
        } catch {
            store?.reportNativeError("无法读取离线转写任务。")
        }
    }

    func waitUntilIdle() async { await worker?.value }

    func shutdown() {
        epoch &+= 1
        operation = nil
        readiness?.cancel()
        readiness = nil
        interrupt()
    }

    private func process(_ effects: [LocalSpeechEffect], epoch currentEpoch: UInt64) async {
        for effect in effects {
            guard !Task.isCancelled, epoch == currentEpoch else { break }
            do {
                switch effect {
                case let .start(id, locale):
                    operation = nil
                    await cancelSession()
                    try Task.checkCancellation()
                    guard epoch == currentEpoch else { break }
                    operation = id
                    deadline = now().advanced(by: operationTimeout)
                    let readiness = readiness
                    await withTaskCancellationHandler {
                        await readiness?.value
                    } onCancel: {
                        readiness?.cancel()
                    }
                    try Task.checkCancellation()
                    let created = try await recognizer.start(locale: locale) { [weak self] event in
                        self?.receive(event, operation: id, epoch: currentEpoch)
                    }
                    session = created
                    deadline = nil
                case let .audio(id, samples):
                    if operation == id { try session?.append(samples) }
                case let .finish(id):
                    guard operation == id, let session else { continue }
                    deadline = now().advanced(by: operationTimeout)
                    try await session.finish()
                    deadline = nil
                    try Task.checkCancellation()
                    if epoch == currentEpoch, operation == id {
                        send(.localAsrFinished(operationId: id))
                        operation = nil
                        self.session = nil
                    }
                case let .cancel(id):
                    guard operation == id else { continue }
                    operation = nil
                    await session?.cancel()
                    session = nil
                }
            } catch {
                deadline = nil
                let failed = operation
                operation = nil
                if !Task.isCancelled, epoch == currentEpoch, let failed {
                    send(.localAsrFailed(operationId: failed, message: error.localizedDescription))
                }
                await cancelSession()
            }
        }
        if Task.isCancelled || epoch != currentEpoch {
            operation = nil
            await cancelSession()
        }
    }

    private func receive(_ event: Result<LocalSpeechResult, Error>, operation id: UInt64, epoch currentEpoch: UInt64) {
        guard epoch == currentEpoch, operation == id else { return }
        switch event {
        case let .success(result):
            send(.localAsrResult(
                operationId: id,
                text: result.text,
                startMs: result.startMs,
                endMs: result.endMs,
                isFinal: result.isFinal
            ))
        case let .failure(error):
            interrupt()
            send(.localAsrFailed(operationId: id, message: error.localizedDescription))
        }
    }

    private func interrupt() {
        deadline = nil
        operation = nil
        worker?.cancel()
        if cancellation == nil, let session {
            cancellation = Task { await session.cancel() }
        }
        if worker == nil, session != nil {
            worker = Task { [weak self] in
                await self?.cancelSession()
                self?.worker = nil
            }
        }
    }

    private func cancelSession() async {
        if let cancellation { await cancellation.value }
        else { await session?.cancel() }
        cancellation = nil
        session = nil
    }

    private func send(_ event: HostAdapterEvent) {
        if let sendEvent { sendEvent(event) }
        else { store?.send(event) }
    }
}
