import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/apple_speech.dart';
import 'package:koe/state/recorder_controller.dart';

/// Apple on-device file transcription keeps the times of its passages (#396):
/// without them a local-only meeting cannot jump from the transcript to the
/// recording, and local speaker diarization has nothing to assign speakers to.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/apple_file_transcript_times');
  late Directory dir;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    dir = await Directory.systemTemp.createTemp('koe-apple-times-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'capabilities':
          return {
            'supported': true,
            'speechStatus': 'ready',
            'translationStatus': 'ready',
            'suggestedSourceLanguage': 'zh-CN',
          };
        case 'transcribeFile':
          // The reply of `transcribe(id:path:source:)` in
          // darwin/AppleSpeechBridge.swift.
          return {
            'text': '我们先看上周的进度。\n周五前提交方案。',
            'durationSec': 6.4,
            'segments': [
              {'text': '我们先看上周的进度。', 'startMs': 320, 'endMs': 2880},
              {'text': '周五前提交方案。', 'startMs': 3400, 'endMs': 6120},
            ],
          };
      }
      return null;
    });
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    await dir.delete(recursive: true);
  });

  test('Apple 设备端文件转写存下的逐字稿每段带时间', () async {
    final controller = RecorderController(
      loadPersistedState: false,
      topicsEnabled: false,
      appleSpeech: AppleSpeechService(channel: channel),
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${dir.path}/imports'),
    );
    addTearDown(controller.dispose);
    await controller.refreshAppleCapabilities();
    final source = File('${dir.path}/meeting.wav');
    await source.writeAsBytes(_silentWav(seconds: 1));
    final path = (await controller.importLocalAudio(source.path)).path;

    await controller.transcribeLocalFile(path, provider: SttProvider.apple);

    expect(controller.transcriptForPath(path), '我们先看上周的进度。\n周五前提交方案。');
    expect(controller.transcriptSegmentsForPath(path), const [
      TranscriptSegment(
        text: '我们先看上周的进度。',
        start: Duration(milliseconds: 320),
        end: Duration(milliseconds: 2880),
      ),
      TranscriptSegment(
        text: '周五前提交方案。',
        start: Duration(milliseconds: 3400),
        end: Duration(milliseconds: 6120),
      ),
    ]);
  });
}

/// 16 kHz mono 16-bit PCM, the format of Koe's own recordings.
Uint8List _silentWav({required int seconds}) {
  const rate = 16000;
  final dataLength = rate * 2 * seconds;
  final bytes = ByteData(44 + dataLength);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, dataLength, Endian.little);
  return bytes.buffer.asUint8List();
}
