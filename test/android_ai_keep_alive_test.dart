import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/platform/background_sync_service.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

import 'support/fake_foreground_service.dart';

/// On Android the foreground service keeps Koe running while it transcribes
/// and analyses recordings, so the work finishes after the user leaves Koe or
/// locks the phone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ai-keep-alive-');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  const grace = Duration(milliseconds: 500);

  RecorderController build(_Qwen qwen, {AnalysisService? assistant}) {
    final controller = RecorderController(
      loadPersistedState: false,
      meetingLocalOnly: false,
      qwenSpeech: qwen,
      contextAnalysisService: assistant,
      aiKeepAliveGrace: grace,
      phoneRecordingEnabled: false,
      topicsEnabled: false,
    )..setSpeechProvider(SttProvider.qwen);
    addTearDown(controller.dispose);
    return controller;
  }

  Future<String> recording() async {
    final audio = File('${directory.path}/1761000000.wav');
    await audio.writeAsBytes([1, 2, 3, 4]);
    return audio.path;
  }

  test('transcribing a recording and then extracting its todos keep the '
      'service running as dataSync, with no stop in between, until shortly '
      'after', () async {
    final service = FakeForegroundService();
    final qwen = _Qwen();
    final assistant = _Assistant();
    final controller = build(qwen, assistant: assistant);
    final path = await recording();

    final transcribed = controller.transcribeLocalFile(path);
    await until(() => qwen.calls == 1);
    expect(service.types, {'dataSync'});
    expect(service.text, 'Koe 正在处理录音');

    qwen.pending.complete();
    await transcribed;
    final extracted = controller.extractTodos(RecordingReference(path: path));
    await until(() => assistant.calls == 1);
    // Past the grace that followed the transcription, the service stays.
    await Future<void>.delayed(grace * 2);
    expect(service.types, {'dataSync'});
    expect(service.stops, 0);

    assistant.pending.complete('{"items":[],"updates":[]}');
    await extracted;
    await until(() => !service.running);
    expect(service.stops, 1);
  });

  test('beside recorder sync, whose line stays on the notification; when '
      'Android takes dataSync away at its daily limit, Koe asks again once '
      'it is back on screen', () async {
    final service = FakeForegroundService();
    await BackgroundSyncService.shared.begin(BackgroundWork.recorderSync);
    final qwen = _Qwen();
    final controller = build(qwen);

    final transcribed = controller.transcribeLocalFile(await recording());
    await until(() => service.types.contains('dataSync'));
    expect(service.types, {'connectedDevice', 'dataSync'});
    expect(service.text, 'Koe 正在同步录音');

    await service.refuse({'dataSync'});
    expect(service.types, {'connectedDevice'});

    final binding = TestWidgetsFlutterBinding.instance;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await until(() => service.types.contains('dataSync'));

    qwen.pending.complete();
    await transcribed;
    await until(() => !service.types.contains('dataSync'));
    expect(service.types, {'connectedDevice'});
    expect(service.text, 'Koe 正在同步录音');
    await BackgroundSyncService.shared.end(BackgroundWork.recorderSync);
  });
}

/// Cloud transcription that answers once [pending] completes.
class _Qwen extends QwenSttService {
  _Qwen() {
    apiKeyOverride = 'key';
  }

  final pending = Completer<void>();
  int calls = 0;

  @override
  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    int? expectedSpeakers,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    calls++;
    await pending.future;
    return SttResult(text: '周五前把报价发给小王。', sourcePath: path, language: 'zh');
  }
}

/// The language model, answering once [pending] completes.
class _Assistant implements AnalysisService {
  final pending = Completer<String>();
  int calls = 0;

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) {
    calls++;
    return pending.future;
  }

  @override
  void dispose() {}
}
