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

enum LocalSpeechEffect: Decodable {
    case start(UInt64, String)
    case audio(UInt64, [Int16])
    case finish(UInt64)
    case cancel(UInt64)

    private enum CodingKeys: String, CodingKey { case kind, operationId, locale, pcm16 }
    private enum Kind: String, Decodable { case start, audio, finish, cancel }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try fields.decode(UInt64.self, forKey: .operationId)
        switch try fields.decode(Kind.self, forKey: .kind) {
        case .start: self = .start(operation, try fields.decode(String.self, forKey: .locale))
        case .audio: self = .audio(operation, try fields.decode([Int16].self, forKey: .pcm16))
        case .finish: self = .finish(operation)
        case .cancel: self = .cancel(operation)
        }
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
    private let sendCommand: ((String, [String: Any]) -> Void)?
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
        send: ((String, [String: Any]) -> Void)? = nil,
        now: @escaping () -> ContinuousClock.Instant = { .now },
        operationTimeout: Duration = .seconds(30)
    ) {
        self.recognizer = recognizer ?? makeLocalSpeechRecognizer()
        self.drain = drain
        self.sendCommand = send
        self.now = now
        self.operationTimeout = operationTimeout
    }

    func prepare() {
        guard readiness == nil else { return }
        let currentEpoch = epoch
        send("local_asr_readiness", ["state": "preparing", "message": "正在准备中文离线转写。"])
        readiness = Task { [weak self] in
            guard let self else { return }
            do {
                try await recognizer.prepare()
                try Task.checkCancellation()
                guard epoch == currentEpoch else { return }
                send("local_asr_readiness", ["state": "ready", "message": "中文离线转写已就绪。"])
            } catch {
                guard epoch == currentEpoch else { return }
                send("local_asr_readiness", ["state": "unavailable", "message": error.localizedDescription])
            }
        }
    }

    func apply() {
        guard worker == nil else {
            if let deadline, now() >= deadline {
                if let operation {
                    send("local_asr_failed", ["operationId": operation, "message": "离线转写等待系统响应超时；原始录音仍会保存。"])
                }
                interrupt()
            }
            return
        }
        do {
            let data = try drain?() ?? store?.drainLocalASREffectsJSON() ?? Data("[]".utf8)
            let effects = try JSONDecoder().decode([LocalSpeechEffect].self, from: data)
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
                        send("local_asr_finished", ["operationId": id])
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
                    send("local_asr_failed", ["operationId": failed, "message": error.localizedDescription])
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
            send("local_asr_result", [
                "operationId": id, "text": result.text, "startMs": result.startMs,
                "endMs": result.endMs, "isFinal": result.isFinal
            ])
        case let .failure(error):
            interrupt()
            send("local_asr_failed", ["operationId": id, "message": error.localizedDescription])
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

    private func send(_ type: String, _ fields: [String: Any]) {
        if let sendCommand { sendCommand(type, fields) }
        else { store?.send(type, fields) }
    }
}
