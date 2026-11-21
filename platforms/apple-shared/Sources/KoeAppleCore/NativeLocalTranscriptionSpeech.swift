import AVFoundation
import CoreMedia
import Foundation
import Speech

@MainActor
public func makeLocalSpeechRecognizer() -> any LocalSpeechRecognizer {
    if #available(macOS 26, iOS 26, *) { return AppleLocalSpeechRecognizer() }
    return UnsupportedLocalSpeechRecognizer()
}

@MainActor
private struct UnsupportedLocalSpeechRecognizer: LocalSpeechRecognizer {
    private var unsupported: LocalSpeechError {
        #if os(iOS)
        LocalSpeechError("Apple 本机识别需要 iOS 26 或更新版本及支持的设备。请在设置中切换为云端识别，原始录音仍会保存。")
        #else
        LocalSpeechError("中文离线转写需要 macOS 26 或更新版本及支持的 Mac。录音仍会保存。")
        #endif
    }

    func prepare() async throws { throw unsupported }
    func start(locale: String, result: @escaping @MainActor (Result<LocalSpeechResult, Error>) -> Void) async throws -> any LocalSpeechSession {
        throw unsupported
    }
}

@available(macOS 26, iOS 26, *)
@MainActor
public final class AppleLocalSpeechRecognizer: LocalSpeechRecognizer {
    private var locale: Locale?

    public init() {}

    public func prepare() async throws {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            #if os(iOS)
            throw LocalSpeechError("此设备暂不支持中文本机识别。请在设置中切换为云端识别，原始录音仍会保存。")
            #else
            throw LocalSpeechError("此 Mac 暂不支持中文离线转写。录音仍会保存。")
            #endif
        }
        try await AssetInventory.reserve(locale: supported)
        let module = Self.transcriber(locale: supported)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw LocalSpeechError("中文离线语音模型尚未就绪，请联网完成模型下载后重试。")
        }
        locale = supported
    }

    public func start(locale requested: String, result: @escaping @MainActor (Result<LocalSpeechResult, Error>) -> Void) async throws -> any LocalSpeechSession {
        guard requested == "zh-CN", let locale else {
            throw LocalSpeechError("中文离线转写尚未就绪。录音仍会保存。")
        }
        return try await AppleLocalSpeechSession.start(transcriber: Self.transcriber(locale: locale), result: result)
    }

    private static func transcriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
    }
}

@MainActor
public final class LocalSpeechPCMConverter {
    public static let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    public init(outputFormat: AVAudioFormat) throws {
        self.outputFormat = outputFormat
        if outputFormat == Self.inputFormat { converter = nil }
        else {
            guard let created = AVAudioConverter(from: Self.inputFormat, to: outputFormat) else {
                throw LocalSpeechError("无法转换离线转写所需的音频格式。")
            }
            converter = created
        }
    }

    public func convert(_ samples: [Int16]) throws -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        guard let input = AVAudioPCMBuffer(pcmFormat: Self.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.int16ChannelData?[0] else {
            throw LocalSpeechError("无法分配离线转写音频缓冲区。")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in channel.update(from: source.baseAddress!, count: source.count) }
        guard let converter else { return input }
        let capacity = AVAudioFrameCount(ceil(Double(samples.count) * outputFormat.sampleRate / 16_000)) + 64
        let output = try buffer(capacity: capacity)
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if consumed { state.pointee = .noDataNow; return nil }
            consumed = true
            state.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error else { throw LocalSpeechError("离线转写音频转换失败。") }
        return output.frameLength == 0 ? nil : output
    }

    public func flush(_ receive: (AVAudioPCMBuffer) throws -> Void) throws {
        guard let converter else { return }
        while true {
            let output = try buffer(capacity: 4096)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            guard status != .error else { throw LocalSpeechError("离线转写尾音转换失败。") }
            if output.frameLength > 0 { try receive(output) }
            if status == .endOfStream || output.frameLength == 0 { return }
        }
    }

    private func buffer(capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw LocalSpeechError("无法分配离线转写音频缓冲区。")
        }
        return output
    }
}

@available(macOS 26, iOS 26, *)
@MainActor
public final class LocalSpeechAudioInput {
    public let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation

    public init(capacity: Int = 64) {
        (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(capacity))
    }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        switch continuation.yield(AnalyzerInput(buffer: buffer)) {
        case .enqueued: return
        case .dropped: throw LocalSpeechError("离线转写处理不及，已停止转写；原始录音仍会保存。")
        case .terminated: throw LocalSpeechError("离线转写音频流已中断；原始录音仍会保存。")
        @unknown default: throw LocalSpeechError("离线转写音频流无法继续。")
        }
    }

    public func finish() { continuation.finish() }
}

@available(macOS 26, iOS 26, *)
@MainActor
final class AppleLocalSpeechSession: LocalSpeechSession {
    private let analyzer: SpeechAnalyzer
    private let input: LocalSpeechAudioInput
    private let converter: LocalSpeechPCMConverter
    private let reader: Task<Void, Error>
    private var closed = false

    private init(analyzer: SpeechAnalyzer, input: LocalSpeechAudioInput,
                 converter: LocalSpeechPCMConverter, reader: Task<Void, Error>) {
        self.analyzer = analyzer
        self.input = input
        self.converter = converter
        self.reader = reader
    }

    static func start(transcriber: SpeechTranscriber, result: @escaping @MainActor (Result<LocalSpeechResult, Error>) -> Void) async throws -> AppleLocalSpeechSession {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: LocalSpeechPCMConverter.inputFormat) else {
            throw LocalSpeechError("系统未提供中文离线转写音频格式。")
        }
        let converter = try LocalSpeechPCMConverter(outputFormat: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let input = LocalSpeechAudioInput()
        let reader = Task {
            do {
                for try await item in transcriber.results {
                    try Task.checkCancellation()
                    let start = try milliseconds(item.range.start)
                    let end = try milliseconds(item.range.end)
                    guard end >= start else { throw LocalSpeechError("离线转写返回了无效的音频时间。") }
                    result(.success(LocalSpeechResult(text: String(item.text.characters), startMs: start, endMs: end, isFinal: item.isFinal)))
                }
            } catch {
                if !Task.isCancelled { result(.failure(error)) }
                throw error
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await analyzer.prepareToAnalyze(in: format)
                try Task.checkCancellation()
                try await analyzer.start(inputSequence: input.stream)
                try Task.checkCancellation()
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            return AppleLocalSpeechSession(analyzer: analyzer, input: input, converter: converter, reader: reader)
        } catch {
            input.finish()
            reader.cancel()
            await analyzer.cancelAndFinishNow()
            _ = await reader.result
            throw error
        }
    }

    func append(_ samples: [Int16]) throws {
        guard !closed else { throw LocalSpeechError("离线转写音频流已关闭。") }
        for offset in stride(from: 0, to: samples.count, by: 4096) {
            if let buffer = try converter.convert(Array(samples[offset..<min(offset + 4096, samples.count)])) {
                try input.append(buffer)
            }
        }
    }

    func finish() async throws {
        guard !closed else { throw LocalSpeechError("离线转写音频流已关闭。") }
        try converter.flush { try input.append($0) }
        closed = true
        input.finish()
        let analyzer = analyzer
        let reader = reader
        try await withTaskCancellationHandler {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await reader.value
            try Task.checkCancellation()
        } onCancel: {
            reader.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    func cancel() async {
        closed = true
        input.finish()
        reader.cancel()
        await analyzer.cancelAndFinishNow()
        _ = await reader.result
    }

    private static func milliseconds(_ time: CMTime) throws -> UInt64 {
        let value = CMTimeGetSeconds(time) * 1000
        guard value.isFinite, value >= 0, value < Double(UInt64.max) else {
            throw LocalSpeechError("离线转写返回了无效的音频时间。")
        }
        return UInt64(value.rounded())
    }
}
