import Foundation

@MainActor
public struct HostBridgeActions {
    public var requestBleScan: () -> Void
    public var flushBleOutbound: () -> Void
    public var resumeMicrophone: () -> Void

    public init(
        requestBleScan: @escaping () -> Void = {},
        flushBleOutbound: @escaping () -> Void = {},
        resumeMicrophone: @escaping () -> Void = {}
    ) {
        self.requestBleScan = requestBleScan
        self.flushBleOutbound = flushBleOutbound
        self.resumeMicrophone = resumeMicrophone
    }
}

public struct HostAudioInputDescriptor: Encodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let transport: String
    public let isDefault: Bool

    public init(id: String, name: String, transport: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.transport = transport
        self.isDefault = isDefault
    }
}

public enum HostAdapterEvent: Encodable, Equatable, Sendable {
    case syncAudioInputs(inputs: [HostAudioInputDescriptor])
    case microphonePrepared(recordId: String, sessionId: String, epoch: UInt64, clockNs: UInt64)
    case resumeMicrophone(clockNs: UInt64)
    case microphoneStarted(recordId: String, sessionId: String, lane: String, sampleRate: UInt32)
    case microphonePaused(recordId: String, sessionId: String, lane: String, sequence: UInt64, epoch: UInt64)
    case microphoneStopped(recordId: String, sessionId: String, lane: String, sequence: UInt64, epoch: UInt64? = nil)
    case microphoneFailed(recordId: String, sessionId: String, lane: String, message: String, epoch: UInt64? = nil)
    case localAsrReadiness(state: String, message: String)
    case localAsrResult(operationId: UInt64, text: String, startMs: UInt64, endMs: UInt64, isFinal: Bool)
    case localAsrFinished(operationId: UInt64)
    case localAsrFailed(operationId: UInt64, message: String)
    case deviceEvent(event: String, connectionId: String, deviceName: String? = nil)
    case deviceDisconnect
    case requestQuit
    case cancelQuit

    private enum CodingKeys: String, CodingKey {
        case type, inputs, recordId, sessionId, epoch, clockNs, lane, sampleRate, sequence
        case message, state, operationId, text, startMs, endMs, isFinal
        case event, connectionId, deviceName
    }

    public var eventType: String {
        switch self {
        case .syncAudioInputs: "sync_audio_inputs"
        case .microphonePrepared: "microphone_prepared"
        case .resumeMicrophone: "resume_microphone"
        case .microphoneStarted: "microphone_started"
        case .microphonePaused: "microphone_paused"
        case .microphoneStopped: "microphone_stopped"
        case .microphoneFailed: "microphone_failed"
        case .localAsrReadiness: "local_asr_readiness"
        case .localAsrResult: "local_asr_result"
        case .localAsrFinished: "local_asr_finished"
        case .localAsrFailed: "local_asr_failed"
        case .deviceEvent: "device_event"
        case .deviceDisconnect: "device_disconnect"
        case .requestQuit: "request_quit"
        case .cancelQuit: "cancel_quit"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eventType, forKey: .type)
        switch self {
        case let .syncAudioInputs(inputs):
            try c.encode(inputs, forKey: .inputs)
        case let .microphonePrepared(recordId, sessionId, epoch, clockNs):
            try c.encode(recordId, forKey: .recordId)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(epoch, forKey: .epoch)
            try c.encode(clockNs, forKey: .clockNs)
        case let .resumeMicrophone(clockNs):
            try c.encode(clockNs, forKey: .clockNs)
        case let .microphoneStarted(recordId, sessionId, lane, sampleRate):
            try c.encode(recordId, forKey: .recordId)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(lane, forKey: .lane)
            try c.encode(sampleRate, forKey: .sampleRate)
        case let .microphonePaused(recordId, sessionId, lane, sequence, epoch):
            try c.encode(recordId, forKey: .recordId)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(lane, forKey: .lane)
            try c.encode(sequence, forKey: .sequence)
            try c.encode(epoch, forKey: .epoch)
        case let .microphoneStopped(recordId, sessionId, lane, sequence, epoch):
            try c.encode(recordId, forKey: .recordId)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(lane, forKey: .lane)
            try c.encode(sequence, forKey: .sequence)
            try c.encodeIfPresent(epoch, forKey: .epoch)
        case let .microphoneFailed(recordId, sessionId, lane, message, epoch):
            try c.encode(recordId, forKey: .recordId)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(lane, forKey: .lane)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(epoch, forKey: .epoch)
        case let .localAsrReadiness(state, message):
            try c.encode(state, forKey: .state)
            try c.encode(message, forKey: .message)
        case let .localAsrResult(operationId, text, startMs, endMs, isFinal):
            try c.encode(operationId, forKey: .operationId)
            try c.encode(text, forKey: .text)
            try c.encode(startMs, forKey: .startMs)
            try c.encode(endMs, forKey: .endMs)
            try c.encode(isFinal, forKey: .isFinal)
        case let .localAsrFinished(operationId):
            try c.encode(operationId, forKey: .operationId)
        case let .localAsrFailed(operationId, message):
            try c.encode(operationId, forKey: .operationId)
            try c.encode(message, forKey: .message)
        case let .deviceEvent(event, connectionId, deviceName):
            try c.encode(event, forKey: .event)
            try c.encode(connectionId, forKey: .connectionId)
            try c.encodeIfPresent(deviceName, forKey: .deviceName)
        case .deviceDisconnect, .requestQuit, .cancelQuit:
            break
        }
    }
}
