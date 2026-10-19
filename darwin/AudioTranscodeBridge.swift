import AVFoundation
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Decodes imported audio (m4a/aac/flac/mp3) into 16 kHz mono PCM16 WAV for
/// speech services that do not read MP4 containers (Doubao flash, #233).
enum AudioTranscodeBridge {
  static func configure(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.semanticcraft.koe/audio_transcode", binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "toWav" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let input = args["input"] as? String,
        let output = args["output"] as? String
      else {
        result(FlutterError(code: "invalid_argument", message: "参数无效", details: nil))
        return
      }
      let rate = (args["sampleRate"] as? NSNumber)?.doubleValue ?? 16000
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try AudioTranscoder.toWav(
            input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output),
            sampleRate: rate)
          DispatchQueue.main.async { result(nil) }
        } catch let error as AudioTranscoder.Failure {
          DispatchQueue.main.async {
            result(FlutterError(code: "transcode_failed", message: error.message, details: nil))
          }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "transcode_failed", message: "无法转换音频", details: nil))
          }
        }
      }
    }
  }
}

enum AudioTranscoder {
  struct Failure: Error {
    let message: String
  }

  static func toWav(input: URL, output: URL, sampleRate: Double) throws {
    try? FileManager.default.removeItem(at: output)
    let source: AVAudioFile
    do {
      source = try AVAudioFile(forReading: input)
    } catch {
      throw Failure(message: "无法读取这个音频文件")
    }
    let sourceFormat = source.processingFormat
    guard
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
    else {
      throw Failure(message: "不支持这个音频的编码")
    }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    do {
      // Scoped so the WAV header is finalized when the writer is released.
      let destination = try AVAudioFile(
        forWriting: output, settings: settings, commonFormat: .pcmFormatInt16,
        interleaved: true)
      let inputCapacity: AVAudioFrameCount = 8192
      let outputCapacity = AVAudioFrameCount(
        Double(inputCapacity) * sampleRate / sourceFormat.sampleRate) + 1024
      var finished = false
      var readError: Error?
      while true {
        guard
          let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity)
        else { throw Failure(message: "内存不足，无法转换音频") }
        var convertError: NSError?
        let status = converter.convert(to: out, error: &convertError) { _, inputStatus in
          // Reading at the end throws on some OS versions; stop before it.
          if finished || source.framePosition >= source.length {
            finished = true
            inputStatus.pointee = .endOfStream
            return nil
          }
          guard
            let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputCapacity)
          else {
            finished = true
            inputStatus.pointee = .endOfStream
            return nil
          }
          do {
            try source.read(into: buffer)
          } catch {
            readError = error
          }
          if buffer.frameLength == 0 {
            finished = true
            inputStatus.pointee = .endOfStream
            return nil
          }
          inputStatus.pointee = .haveData
          return buffer
        }
        if readError != nil { throw Failure(message: "读取音频时出错") }
        if status == .error || convertError != nil {
          throw Failure(message: "音频解码失败")
        }
        if out.frameLength > 0 { try destination.write(from: out) }
        if status == .endOfStream { break }
      }
      if destination.length == 0 { throw Failure(message: "音频里没有可转换的声音") }
    } catch let error as Failure {
      try? FileManager.default.removeItem(at: output)
      throw error
    } catch {
      try? FileManager.default.removeItem(at: output)
      throw Failure(message: "无法写入转换后的音频")
    }
  }
}
