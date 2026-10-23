import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/main.dart';
import 'package:koe/platform/mac_app.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/mac_menu_bar.dart';

import 'support/wav_fixture.dart';

/// Koe on the Mac menu bar (#403): the take and the work under way, the Mac
/// kept awake meanwhile, a question and a saved take before quitting, and a
/// notice when the disk fills up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/mac_app');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late List<Map<Object?, Object?>> updates;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-mac-menu-bar-');
    updates = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'update') {
        updates.add(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
    final shared = MacApp.shared;
    MacApp.shared = MacApp(channel: channel, enabled: true);
    addTearDown(() async {
      MacApp.shared = shared;
      messenger.setMockMethodCallHandler(channel, null);
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  Map<Object?, Object?> shown() => updates.last;
  List<Object?> menu() => [
    for (final action in shown()['actions']! as List<Object?>)
      (action! as Map<Object?, Object?>)['title'],
  ];

  /// Sends [method] as the Mac side does; completes once Koe answers.
  Future<void> fromMac(String method, [Object? arguments]) {
    final answered = Completer<void>();
    unawaited(
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, arguments)),
        (_) => answered.complete(),
      ),
    );
    return answered.future;
  }

  /// Pumps real async work (file reads and writes) until [done] holds.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 50 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(done(), isTrue);
  }

  Future<RecorderController> openKoe(WidgetTester tester, _Mic mic) async {
    final controller = (await tester.runAsync(
      () async => RecorderController(
        loadPersistedState: false,
        libraryDirectory: Directory('${directory.path}/imports'),
        phoneRecorder: mic,
        phoneRecordingEnabled: true,
        placeCapture: _NoPlace(),
      ),
    ))!;
    addTearDown(controller.dispose);
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    return controller;
  }

  /// Starts a take from the menu, which opens the recording sheet.
  Future<void> startFromMenu(WidgetTester tester, RecorderController c) async {
    await tester.runAsync(() => fromMac('menu', 'start'));
    await settle(tester, () => c.phoneRecordingActive);
  }

  testWidgets(
    'the menu bar item shows the take, and its menu starts, pauses, resumes '
    'and saves it',
    (tester) async {
      final controller = await openKoe(tester, _Mic());
      expect(shown()['state'], 'idle');
      expect(menu(), ['开始录音']);
      expect(shown()['keepAwake'], isNull);
      expect(shown()['quitMessage'], isNull);

      await startFromMenu(tester, controller);
      expect(find.byKey(const ValueKey('phone-recording-title')), findsOne);
      expect(shown()['state'], 'recording');
      expect(shown()['take'], '录音中');
      expect(shown()['running'], isTrue);
      expect(menu(), ['暂停录音', '停止并保存']);
      expect(shown()['keepAwake'], 'Koe is recording');
      expect(shown()['quitMessage'], '正在录音，要退出 Koe 吗？');

      await tester.runAsync(() => fromMac('menu', 'pause'));
      await settle(tester, () => controller.phoneRecordingPaused);
      expect(shown()['state'], 'paused');
      expect(shown()['take'], '录音已暂停');
      expect(shown()['running'], isFalse);
      expect(menu(), ['继续录音', '停止并保存']);
      // Paused, the take is still Koe's to lose.
      expect(shown()['keepAwake'], 'Koe is recording');

      await tester.runAsync(() => fromMac('menu', 'resume'));
      await settle(tester, () => !controller.phoneRecordingPaused);
      expect(shown()['state'], 'recording');

      await tester.runAsync(() => fromMac('menu', 'stop'));
      await settle(tester, () => controller.library.assets.length == 1);
      expect(shown()['state'], 'idle');
      expect(menu(), ['开始录音']);
      expect(shown()['keepAwake'], isNull);
      expect(shown()['quitMessage'], isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('quitting while recording saves the take before Koe quits', (
    tester,
  ) async {
    final controller = await openKoe(tester, _Mic());
    await startFromMenu(tester, controller);

    await tester.runAsync(() => fromMac('quit'));
    expect(controller.phoneRecordingActive, isFalse);
    expect(controller.library.assets, hasLength(1));
    expect(
      File(controller.library.assets.single.path).lengthSync(),
      greaterThan(44),
    );
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  group('room left on the disk', () {
    setUp(() => TakeSpaceCheck.checkEvery = const Duration(milliseconds: 300));
    tearDown(() => TakeSpaceCheck.checkEvery = const Duration(seconds: 30));

    final notice = find.byKey(const ValueKey('phone-recording-space-notice'));

    testWidgets(
      'a take started with under 1 GB left says how long it can record',
      (tester) async {
        final mic = _Mic()..space = 800000000;
        final controller = await openKoe(tester, mic);
        await startFromMenu(tester, controller);
        await settle(tester, () => notice.evaluate().isNotEmpty);

        const text =
            '磁盘只剩 800 MB，大约还能录 6 小时 56 分钟。'
            '空间用完时录音会停下，已录的部分会保存。';
        expect(tester.widget<Text>(notice).data, text);
        expect(shown()['lines'], [text]);

        await tester.runAsync(() => fromMac('menu', 'stop'));
        await settle(tester, () => controller.library.assets.length == 1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'a take says so once under 300 MB are left, and keeps the room left '
      'current until there is room again',
      (tester) async {
        final mic = _Mic()..space = 2000000000;
        final controller = await openKoe(tester, mic);
        await startFromMenu(tester, controller);

        // Room to start, and later more than a take's last 300 MB: quiet.
        await settle(tester, () => mic.spaceChecks >= 1);
        mic.space = 500000000;
        final checked = mic.spaceChecks;
        await settle(tester, () => mic.spaceChecks > checked);
        expect(notice, findsNothing);
        expect(shown()['lines'], isEmpty);

        mic.space = 250000000;
        await settle(tester, () => notice.evaluate().isNotEmpty);
        expect(
          tester.widget<Text>(notice).data,
          '磁盘只剩 250 MB，大约还能录 2 小时 10 分钟。'
          '空间用完时录音会停下，已录的部分会保存。',
        );

        mic.space = 100000000;
        await settle(
          tester,
          () => tester.widget<Text>(notice).data!.startsWith('磁盘只剩 100 MB'),
        );
        expect(
          (shown()['lines']! as List<Object?>).single,
          startsWith('磁盘只剩 100 MB，大约还能录 52 分钟。'),
        );

        // Some room back, though not enough to start a take without a
        // notice: it stays, so it does not come and go near 300 MB.
        mic.space = 500000000;
        await settle(
          tester,
          () => tester.widget<Text>(notice).data!.startsWith('磁盘只剩 500 MB'),
        );

        mic.space = 5000000000;
        await settle(tester, () => notice.evaluate().isEmpty);
        expect(shown()['lines'], isEmpty);

        await tester.runAsync(() => fromMac('menu', 'stop'));
        await settle(tester, () => controller.library.assets.length == 1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });

  test('transcribing keeps the Mac awake and asks before quitting', () async {
    final stt = _HeldStt()..apiKeyOverride = 'k';
    final controller = RecorderController(
      loadPersistedState: false,
      meetingLocalOnly: false,
      qwenSpeech: stt,
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${directory.path}/imports'),
      placeCapture: _NoPlace(),
    )..speechProvider = SttProvider.qwen;
    addTearDown(controller.dispose);
    final bar = MacMenuBar(controller, onStart: () {});
    addTearDown(bar.dispose);
    final source = File('${directory.path}/周会.wav')
      ..writeAsBytesSync(wavBytes(List.filled(64000, 0x10)));
    final path = (await controller.importLocalAudio(source.path)).path;

    final transcribed = controller.transcribeLocalFile(path);
    await stt.uploading.future;
    await pumpEventQueue();
    expect(shown()['state'], 'working');
    expect(shown()['lines'], ['正在转写「周会」· 上传 25%']);
    expect(shown()['keepAwake'], 'Koe is transcribing');
    expect(shown()['quitMessage'], 'Koe 还在处理录音，要退出吗？');
    expect(shown()['quitInfo'], contains('进行中的转写会中断'));

    stt.done.complete(const SttResult(text: '周会的内容'));
    await transcribed;
    await pumpEventQueue();
    expect(shown()['state'], 'idle');
    expect(shown()['keepAwake'], isNull);
    expect(shown()['quitMessage'], isNull);
  });
}

class _NoPlace implements PlaceCapture {
  @override
  Future<RecordingPlace?> capture() async => null;
}

/// The Mac microphone, on a disk with [space] bytes left; null when it
/// cannot tell.
class _Mic implements PhoneRecorder, PhoneDiskSpace {
  int? space;
  int spaceChecks = 0;

  @override
  Future<int?> availableSpace(String path) async {
    spaceChecks++;
    return space;
  }

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<PhoneMicState> get states => const Stream.empty();

  @override
  Future<void> start(String path) async {
    await File(path).writeAsBytes(wavBytes(List.filled(64000, 0x10)));
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

/// A cloud transcription that has uploaded a quarter of the audio and waits
/// for [done].
class _HeldStt extends QwenSttService {
  final uploading = Completer<void>();
  final done = Completer<SttResult>();

  @override
  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) {
    onProgress?.call(
      const SttFileProgress(
        SttFileStage.uploading,
        uploadedBytes: 1,
        totalBytes: 4,
      ),
    );
    uploading.complete();
    return done.future;
  }
}
