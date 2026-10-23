import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:koe/ai/apple_speech.dart';
import 'package:koe/ai/doubao_stt.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/main.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/context/commitments.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

import 'support/audio_payload_detector.dart';
import 'support/fake_foreground_service.dart';

void main() {
  late Directory directory;
  late Directory imports;
  late _FakePhoneRecorder mic;
  late RecorderController controller;

  RecorderController build({bool permission = true}) {
    mic = _FakePhoneRecorder(permission: permission);
    return RecorderController(
      loadPersistedState: false,
      topicsEnabled: true,
      libraryDirectory: imports,
      phoneRecorder: mic,
      phoneRecordingEnabled: true,
      placeCapture: _FixedPlace(),
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-phone-rec-');
    imports = Directory('${directory.path}/imports');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  /// Pumps real async work (file writes, hashing) until [done] holds.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 50 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(done(), isTrue);
  }

  Future<void> openPhoneRecording(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('new-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-record-phone')));
    await settle(
      tester,
      () => mic.path != null || controller.phoneRecordingError != null,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a phone take is saved as a dated original with its place', (
    tester,
  ) async {
    controller = (await tester.runAsync(() async => build()))!;
    addTearDown(controller.dispose);
    await pump(tester);
    final before = DateTime.now();
    await openPhoneRecording(tester);
    await settle(tester, () => controller.phoneRecordingActive);
    expect(find.text('手机录音中'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pause-phone-recording')));
    await tester.pump();
    expect(find.text('已暂停'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('resume-phone-recording')));
    await tester.pump();
    expect(find.text('手机录音中'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stop-phone-recording')));
    await settle(
      tester,
      () => controller.library.assets.any(
        (a) => a.source == RecordingSource.phone && a.place != null,
      ),
    );
    await tester.pumpAndSettle();

    final asset = controller.library.assets.single;
    expect(asset.displayName, startsWith('手机录音 '));
    // Recorded time is when the take started, not when it was saved.
    expect(asset.recordedAt!.isBefore(asset.importedAt), isTrue);
    expect(asset.recordedAt!.isBefore(before), isFalse);
    expect(asset.place!.label, '上海市 徐汇区');
    expect(controller.exportedPaths, contains(asset.path));
    expect(File(asset.path).existsSync(), isTrue);
    expect(find.text('手机录音已保存为原件'), findsOneWidget);
    expect(controller.phoneRecordingActive, isFalse);
  });

  testWidgets('an interruption shows as paused until the user resumes', (
    tester,
  ) async {
    controller = (await tester.runAsync(() async => build()))!;
    addTearDown(controller.dispose);
    await pump(tester);
    await openPhoneRecording(tester);
    await settle(tester, () => controller.phoneRecordingActive);

    mic.states$.add(PhoneMicState.paused);
    await tester.pump();
    await tester.pump();
    expect(find.text('已暂停'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('resume-phone-recording')),
      findsOneWidget,
    );
  });

  testWidgets('discarding asks first and then removes the take', (
    tester,
  ) async {
    controller = (await tester.runAsync(() async => build()))!;
    addTearDown(controller.dispose);
    await pump(tester);
    await openPhoneRecording(tester);
    await settle(tester, () => controller.phoneRecordingActive);
    final path = mic.path!;

    await tester.tap(find.byKey(const ValueKey('discard-phone-recording')));
    await pumpDialog(tester);
    await tester.tap(find.text('继续录音'));
    await pumpDialog(tester);
    expect(controller.phoneRecordingActive, isTrue);

    await tester.tap(find.byKey(const ValueKey('discard-phone-recording')));
    await pumpDialog(tester);
    await tester.tap(
      find.byKey(const ValueKey('confirm-discard-phone-recording')),
    );
    await settle(
      tester,
      () => find
          .byKey(const ValueKey('phone-recording-title'))
          .evaluate()
          .isEmpty,
    );
    expect(File(path).existsSync(), isFalse);
    expect(controller.phoneRecordingActive, isFalse);
    expect(controller.library.assets, isEmpty);
  });

  testWidgets('system back mid-take asks first, then saves the take', (
    tester,
  ) async {
    controller = (await tester.runAsync(() async => build()))!;
    addTearDown(controller.dispose);
    await pump(tester);
    await openPhoneRecording(tester);
    await settle(tester, () => controller.phoneRecordingActive);

    await tester.binding.handlePopRoute();
    await pumpDialog(tester);
    expect(find.text('返回会结束并保存这段录音。'), findsOneWidget);
    await tester.tap(find.text('继续录音'));
    await pumpDialog(tester);
    expect(controller.phoneRecordingActive, isTrue);
    expect(find.text('手机录音中'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await pumpDialog(tester);
    await tester.tap(
      find.byKey(const ValueKey('confirm-leave-phone-recording')),
    );
    await settle(
      tester,
      () => controller.library.assets.any(
        (a) => a.source == RecordingSource.phone,
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.phoneRecordingActive, isFalse);
    expect(find.byKey(const ValueKey('phone-recording-title')), findsNothing);
    expect(find.text('手机录音已保存为原件'), findsOneWidget);
  });

  testWidgets('denied microphone permission explains and records nothing', (
    tester,
  ) async {
    controller = (await tester.runAsync(() async => build(permission: false)))!;
    addTearDown(controller.dispose);
    await pump(tester);
    await openPhoneRecording(tester);
    await settle(tester, () => controller.phoneRecordingError != null);
    await tester.pump();

    expect(find.textContaining('没有麦克风权限'), findsOneWidget);
    expect(mic.path, isNull);
    await tester.tap(find.byKey(const ValueKey('close-phone-recording')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('phone-recording-title')), findsNothing);
  });

  testWidgets('the number of people chosen while recording stays with the '
      'take (#408)', (tester) async {
    controller = (await tester.runAsync(() async => build()))!;
    addTearDown(controller.dispose);
    await pump(tester);
    await openPhoneRecording(tester);
    await settle(tester, () => controller.phoneRecordingActive);
    expect(find.text('人数：自动判断'), findsOneWidget);

    // The take keeps animating, so step through the menu's own transition
    // instead of waiting for the screen to settle.
    await tester.tap(find.byKey(const ValueKey('phone-recording-speakers')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('expected-speakers-3')));
    await settle(tester, () => controller.phoneRecordingExpectedSpeakers == 3);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('大约 3 人'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stop-phone-recording')));
    await settle(
      tester,
      () =>
          controller.library.assets.isNotEmpty &&
          !controller.phoneRecordingSaving,
    );
    expect(
      controller.expectedSpeakersForPath(controller.library.assets.single.path),
      3,
    );
  });

  testWidgets('the panel still closes when the number of people is tapped '
      'while the take saves (#408)', (tester) async {
    controller = (await tester.runAsync(() async => build()))!;
    addTearDown(controller.dispose);
    await pump(tester);
    await openPhoneRecording(tester);
    await settle(tester, () => controller.phoneRecordingActive);

    final gate = mic.stopGate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('stop-phone-recording')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('phone-recording-speakers')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    gate.complete();
    await settle(
      tester,
      () =>
          controller.library.assets.isNotEmpty &&
          !controller.phoneRecordingSaving,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('phone-recording-title')), findsNothing);
    expect(find.text('手机录音已保存为原件'), findsOneWidget);
  });

  testWidgets('the number of people chosen when importing stays with the '
      'recording (#408)', (tester) async {
    final source = File('${directory.path}/meeting.wav');
    await tester.runAsync(() => source.writeAsBytes(_wav(dataBytes: 32000)));
    final original = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = _OpenPanel(source.path);
    addTearDown(() => FileSelectorPlatform.instance = original);
    controller = (await tester.runAsync(() async => build()))!;
    addTearDown(controller.dispose);
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('new-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-record-import')));
    await tester.pumpAndSettle();
    expect(find.textContaining('meeting.wav'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('expected-speakers-3')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('confirm-import-audio')));
    await settle(
      tester,
      () =>
          controller.library.assets.isNotEmpty &&
          controller.expectedSpeakersForPath(
                controller.library.assets.single.path,
              ) ==
              3,
    );
  });

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  test('on Android a take runs as microphone work of the foreground service '
      'and 停止 on its notification saves it', () async {
    final service = FakeForegroundService();
    controller = build();
    addTearDown(controller.dispose);

    await controller.startPhoneRecording();
    expect(service.types, {'microphone'});
    expect(service.text, 'Koe 正在录音');
    expect(service.stoppable, isTrue);

    await controller.pausePhoneRecording();
    expect(service.text, 'Koe 录音已暂停');
    await controller.resumePhoneRecording();
    expect(service.text, 'Koe 正在录音');
    // A call pauses it, and the notification says so.
    mic.states$.add(PhoneMicState.paused);
    await until(() => service.text == 'Koe 录音已暂停');

    await service.pressStop();
    await until(() => controller.library.assets.isNotEmpty);
    final asset = controller.library.assets.single;
    expect(asset.source, RecordingSource.phone);
    expect(File(asset.path).lengthSync(), greaterThan(44));
    expect(controller.phoneRecordingActive, isFalse);
    expect(service.running, isFalse);
    expect(mic.starts, 1);
  });

  test('on Android a take Android refuses while Koe is off screen stops, is '
      'saved and says why', () async {
    final service = FakeForegroundService();
    controller = build();
    addTearDown(controller.dispose);
    await controller.startPhoneRecording();
    expect(service.running, isTrue);

    await service.refuse();

    await until(() => controller.library.assets.isNotEmpty);
    expect(controller.phoneRecordingActive, isFalse);
    expect(
      controller.phoneRecordingError,
      'Koe 不在屏幕上时 Android 不让它开始用麦克风，录音已停下',
    );
  });

  test('a pause the user made survives the system resuming after a '
      'notification sound', () async {
    controller = build();
    addTearDown(controller.dispose);
    await controller.startPhoneRecording();
    await controller.pausePhoneRecording();
    expect(mic.pauses, 1);

    // Focus regained: record resumes the take on its own.
    mic.states$.add(PhoneMicState.recording);
    await until(() => mic.pauses == 2);
    expect(controller.phoneRecordingPaused, isTrue);
  });

  test('a take cut off by a kill is recovered on the next launch', () async {
    final started = DateTime(2026, 10, 19, 8, 15);
    await imports.create(recursive: true);
    final path = '${imports.path}/phone_${started.microsecondsSinceEpoch}.wav';
    // A WAV whose header still says zero bytes, as left by a killed writer.
    await File(path).writeAsBytes(_wav(dataBytes: 32000, headerSizes: 0));

    controller = build();
    addTearDown(controller.dispose);
    await controller.waitForPhoneTakeRecovery();

    final asset = controller.library.assetForPath(path)!;
    expect(asset.source, RecordingSource.phone);
    expect(asset.recordedAt, started);
    final header = ByteData.sublistView(await File(path).readAsBytes());
    expect(header.getUint32(4, Endian.little), 32000 + 36);
    expect(header.getUint32(40, Endian.little), 32000);
    expect(controller.statusMessage, contains('找回了 1 段'));
  });

  group('macOS 麦克风录音 (#378)', () {
    RecorderController buildOnMac({
      bool permission = true,
      bool? phoneRecordingEnabled,
    }) {
      mic = _FakePhoneRecorder(permission: permission);
      return RecorderController(
        loadPersistedState: false,
        topicsEnabled: false,
        libraryDirectory: imports,
        phoneRecorder: mic,
        phoneRecordingEnabled: phoneRecordingEnabled,
        placeCapture: _FixedPlace(),
      );
    }

    testWidgets(
      '(1) macOS 目标平台下新建录音入口出现「麦克风录音」，文案不含「手机」',
      (tester) async {
        controller = (await tester.runAsync(() async => buildOnMac()))!;
        addTearDown(controller.dispose);
        await pump(tester);

        await tester.tap(find.byKey(const ValueKey('new-recording')));
        await tester.pumpAndSettle();

        expect(find.text('麦克风录音'), findsOneWidget);
        expect(find.text('用麦克风录下来，保存为原件'), findsOneWidget);
        expect(find.textContaining('手机'), findsNothing);
        expect(controller.phoneRecordingEnabled, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      '(2) 用假录音器在 macOS 目标平台录一段，暂停再继续，结束后作为原件出现在录音库',
      (tester) async {
        controller = (await tester.runAsync(() async => buildOnMac()))!;
        addTearDown(controller.dispose);
        await pump(tester);
        final before = DateTime.now();

        await openPhoneRecording(tester);
        await settle(tester, () => controller.phoneRecordingActive);
        expect(find.text('麦克风录音中'), findsOneWidget);
        expect(find.textContaining('手机'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('pause-phone-recording')));
        await tester.pump();
        expect(controller.phoneRecordingPaused, isTrue);
        expect(mic.pauses, 1);
        expect(find.text('已暂停'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('resume-phone-recording')));
        await tester.pump();
        expect(controller.phoneRecordingPaused, isFalse);
        expect(mic.resumes, 1);
        expect(find.text('麦克风录音中'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('stop-phone-recording')));
        await settle(
          tester,
          () => controller.library.assets.any(
            (a) => a.source == RecordingSource.phone && a.place != null,
          ),
        );
        await tester.pumpAndSettle();

        final asset = controller.library.assets.single;
        expect(asset.source, RecordingSource.phone);
        expect(asset.displayName, startsWith('麦克风录音 '));
        expect(asset.displayName, isNot(contains('手机')));
        expect(asset.recordedAt!.isBefore(asset.importedAt), isTrue);
        expect(asset.recordedAt!.isBefore(before), isFalse);
        expect(controller.exportedPaths, contains(asset.path));
        final file = File(asset.path);
        expect(file.existsSync(), isTrue);
        final bytes = file.readAsBytesSync();
        expect(bytes.length, greaterThan(44));
        expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
        expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
        expect(find.text('麦克风录音已保存为原件'), findsOneWidget);
        expect(controller.phoneRecordingActive, isFalse);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    test(
      '(3) macOS 目标平台下进程被杀后下次启动找回未结束的录音',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final started = DateTime(2026, 10, 22, 14, 30);
        await imports.create(recursive: true);
        final path =
            '${imports.path}/phone_${started.microsecondsSinceEpoch}.wav';
        await File(path).writeAsBytes(_wav(dataBytes: 32000, headerSizes: 0));

        controller = buildOnMac();
        addTearDown(controller.dispose);
        await controller.waitForPhoneTakeRecovery();

        final asset = controller.library.assetForPath(path);
        expect(asset, isNotNull);
        expect(asset!.source, RecordingSource.phone);
        expect(asset.displayName, startsWith('麦克风录音 '));
        expect(asset.recordedAt, started);
        final header = ByteData.sublistView(await File(path).readAsBytes());
        expect(header.getUint32(4, Endian.little), 32000 + 36);
        expect(header.getUint32(40, Endian.little), 32000);
        expect(controller.statusMessage, '找回了 1 段中断的麦克风录音');
      },
    );

    testWidgets(
      '(4) macOS 目标平台下麦克风权限被拒时显示中文原因并提供去系统设置的入口',
      (tester) async {
        final launchedUrls = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const macPigeonChannel =
            'dev.flutter.pigeon.url_launcher_macos.UrlLauncherApi.launchUrl';
        messenger.setMockMessageHandler(macPigeonChannel, (message) async {
          final decoded =
              const StandardMessageCodec().decodeMessage(message) as List?;
          if (decoded != null && decoded.isNotEmpty) {
            launchedUrls.add(decoded.first as String);
          }
          final reply = WriteBuffer()
            ..putUint8(12)
            ..putUint8(1)
            ..putUint8(130)
            ..putUint8(12)
            ..putUint8(2)
            ..putUint8(1)
            ..putUint8(0);
          return reply.done();
        });
        const methodChannel = MethodChannel('plugins.flutter.io/url_launcher');
        messenger.setMockMethodCallHandler(methodChannel, (call) async {
          if (call.method == 'launch') {
            final args = call.arguments as Map;
            launchedUrls.add(args['url'] as String);
            return true;
          }
          return true;
        });
        addTearDown(() {
          messenger.setMockMessageHandler(macPigeonChannel, null);
          messenger.setMockMethodCallHandler(methodChannel, null);
        });

        controller = (await tester.runAsync(
          () async =>
              buildOnMac(permission: false, phoneRecordingEnabled: true),
        ))!;
        addTearDown(controller.dispose);
        await pump(tester);

        await openPhoneRecording(tester);
        await settle(tester, () => controller.phoneRecordingError != null);
        await tester.pump();

        expect(find.textContaining('没有麦克风权限'), findsOneWidget);
        expect(mic.path, isNull);
        final settingsButton = find.byKey(
          const ValueKey('open-microphone-settings'),
        );
        expect(settingsButton, findsOneWidget);
        expect(find.text('去系统设置'), findsOneWidget);

        await tester.tap(settingsButton);
        await settle(tester, () => launchedUrls.isNotEmpty);
        expect(
          launchedUrls,
          ['x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'],
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    test(
      '(5) 「录音只留本机」开启时，Mac 麦克风会议录音的转写不发任何音频请求',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final wire = _WireRecordingClient();
        final apple = _OnDeviceAppleSpeech(supported: true);
        final macMic = _FakePhoneRecorder(permission: true);

        controller = RecorderController(
          loadPersistedState: false,
          topicsEnabled: false,
          appleSpeech: apple,
          qwenSpeech: QwenSttService(client: wire, pollInterval: Duration.zero)
            ..apiKeyOverride = 'qwen-test-key',
          doubaoSpeech: DoubaoSttService(client: wire)
            ..apiKeyOverride = 'doubao-test-key',
          analysisController: RecordingAnalysis(
            inMemory: true,
            service: QwenAnalysisService(client: wire),
          ),
          contextAnalysisService: QwenAnalysisService(
            client: wire,
            systemPrompt: commitmentSystemPrompt,
            instructionLabel: '要求',
            sourceLabel: '资料',
          ),
          phoneRecorder: macMic,
          placeCapture: _FixedPlace(),
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: imports,
        );
        addTearDown(controller.dispose);

        await controller.refreshAppleCapabilities();
        await controller.setAutoOrganize(true);

        await controller.startPhoneRecording();
        final recordedPath = await controller.stopPhoneRecording();
        expect(recordedPath, isNotNull);
        final recordedBytes = await File(recordedPath!).readAsBytes();
        expect(_containsSublist(recordedBytes, ascii.encode('RIFF')), isTrue);
        expect(_containsSublist(recordedBytes, _pcmPattern), isTrue);

        await until(
          () =>
              controller.organizeStatusFor(recordedPath).stage ==
              OrganizeStage.done,
        );

        expect(wire.requests, isNotEmpty, reason: '整理请求正常发出');
        bool carriesAudio(_RecordedWireRequest req) =>
            requestCarriesAudioBytes(req.bodyBytes, pcmPattern: _pcmPattern);

        // 负对照：构造假请求嵌入真实录下 WAV 文件的不同对齐/短片段/URL-safe/76列换行 Base64，检测器必须全部判为带音频
        String wrap76(String input) {
          final out = StringBuffer();
          for (var i = 0; i < input.length; i += 76) {
            if (i > 0) out.write('\r\n');
            out.write(
              input.substring(
                i,
                i + 76 > input.length ? input.length : i + 76,
              ),
            );
          }
          return out.toString();
        }

        _RecordedWireRequest fakeJsonRequest(String encodedAudio) =>
            _RecordedWireRequest(
              method: 'POST',
              url: Uri.parse('https://example.invalid/v1/audio'),
              bodyBytes: Uint8List.fromList(
                utf8.encode(jsonEncode({'payload': encodedAudio})),
              ),
            );

        // 1) 从文件开头起只取 WAV 头 (44B) + 36B (<60B) 样本数据的短片段
        final shortFromStart = fakeJsonRequest(
          base64Encode(recordedBytes.sublist(0, 44 + 36)),
        );
        // 2) 非 3 倍数字节偏移起的分片（偏移 46，46 mod 3 = 1；相对样本起点 44 偏移 2）
        final unalignedSlice = fakeJsonRequest(
          base64Encode(recordedBytes.sublist(46, 46 + 60)),
        );
        // 3) URL-safe Base64（从偏移 50 起取 24B 完整样本周期，含 0xDE,0xAD,0xBE,0xEF,0xCA,0xFE 对应 + → -）
        final urlSafeSlice = fakeJsonRequest(
          base64UrlEncode(recordedBytes.sublist(50, 50 + 24)),
        );
        // 4) 76 列换行 Base64
        final wrapped76Slice = fakeJsonRequest(
          wrap76(base64Encode(recordedBytes.sublist(30, 30 + 96))),
        );
        expect(
          [
            carriesAudio(shortFromStart),
            carriesAudio(unalignedSlice),
            carriesAudio(urlSafeSlice),
            carriesAudio(wrapped76Slice),
          ],
          [isTrue, isTrue, isTrue, isTrue],
          reason:
              'WAV 头+短片段、非 3 倍数字节偏移分片、URL-safe Base64、76 列换行 Base64 都必须被判为带音频',
        );

        final audioCarryingRequests = [
          for (final req in wire.requests)
            if (carriesAudio(req)) '${req.method} ${req.url}',
        ];
        expect(audioCarryingRequests, isEmpty);

        final uploadEndpoints = [
          for (final req in wire.requests)
            if (req.url.host.contains('oss') ||
                req.url.path.contains('/api/v1/uploads') ||
                req.url.path.contains('/services/audio/asr/transcription') ||
                req.url.host.contains('openspeech.bytedance.com') ||
                req.url.path.contains('/auc/bigmodel/recognize'))
              '${req.method} ${req.url}',
        ];
        expect(uploadEndpoints, isEmpty);

        // macOS < 26 无本机引擎时提示原因，不回落云端
        final lowVerWire = _WireRecordingClient();
        final lowVerController = RecorderController(
          loadPersistedState: false,
          topicsEnabled: false,
          appleSpeech: _OnDeviceAppleSpeech(supported: false),
          qwenSpeech: QwenSttService(
            client: lowVerWire,
            pollInterval: Duration.zero,
          )..apiKeyOverride = 'qwen-test-key',
          phoneRecorder: _FakePhoneRecorder(permission: true),
          placeCapture: _FixedPlace(),
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${directory.path}/imports-low'),
        );
        addTearDown(lowVerController.dispose);
        await lowVerController.refreshAppleCapabilities();
        await lowVerController.setAutoOrganize(true);
        await lowVerController.startPhoneRecording();
        final lowVerPath = await lowVerController.stopPhoneRecording();
        expect(lowVerPath, isNotNull);
        await until(
          () =>
              lowVerController.organizeStatusFor(lowVerPath!).stage ==
              OrganizeStage.failed,
        );
        expect(lowVerWire.requests, isEmpty);
        expect(
          lowVerController.organizeStatusFor(lowVerPath!).message,
          '已开启「录音只留本机」，此设备暂无可用的本机语音引擎，不会回落到云端',
        );
      },
    );
  });
}

final Uint8List _pcmPattern = Uint8List.fromList([
  0x5A,
  0xA5,
  0x3C,
  0xC3,
  0x7E,
  0xE7,
  0x18,
  0x81,
  0x42,
  0x24,
  0x99,
  0x66,
  0xBD,
  0xDB,
  0xAA,
  0x55,
  0x13,
  0x37,
  0xDE,
  0xAD,
  0xBE,
  0xEF,
  0xCA,
  0xFE,
]);

bool _containsSublist(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  final limit = haystack.length - needle.length;
  for (var i = 0; i <= limit; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

class _RecordedWireRequest {
  _RecordedWireRequest({
    required this.method,
    required this.url,
    required this.bodyBytes,
  });

  final String method;
  final Uri url;
  final Uint8List bodyBytes;

  String get bodyText => utf8.decode(bodyBytes, allowMalformed: true);
}

class _WireRecordingClient extends http.BaseClient {
  final List<_RecordedWireRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    requests.add(
      _RecordedWireRequest(
        method: request.method,
        url: request.url,
        bodyBytes: bodyBytes,
      ),
    );
    if (request.url.path.endsWith('/chat/completions')) {
      final decoded =
          jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
      final messages = (decoded['messages'] as List).cast<Map>();
      final userContent = '${messages.last['content']}';
      final content =
          userContent.contains('提取出用户自己承诺要做的事') ||
              userContent.contains('"items"')
          ? '{"items":[{"type":"mine","title":"确认录音不上传","due":null,"segment":1}],"updates":[]}'
          : '会议决定默认打开录音只留本机，确认录音不上传 [S1]。';
      final reply = jsonEncode({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': content},
          },
        ],
      });
      return http.StreamedResponse(
        Stream.value(utf8.encode(reply)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"error":"unexpected endpoint"}')),
      500,
    );
  }
}

class _OnDeviceAppleSpeech extends AppleSpeechService {
  _OnDeviceAppleSpeech({required this.supported});

  final bool supported;

  @override
  bool get offered => true;

  @override
  Future<AppleSpeechCapabilities> capabilities({
    String? sourceLanguage,
    String? targetLanguage,
  }) async {
    if (!supported) return const AppleSpeechCapabilities.unsupported();
    return const AppleSpeechCapabilities(
      supported: true,
      speechStatus: SpeechResourceStatus.ready,
      translationStatus: SpeechResourceStatus.ready,
      suggestedSourceLanguage: 'zh-CN',
      speechLanguages: [
        SpeechLanguage(code: 'zh-CN', name: '简体中文'),
        SpeechLanguage(code: 'en-US', name: 'English'),
      ],
    );
  }

  @override
  Future<SttResult> transcribePath(
    String path, {
    required String sourceLanguage,
    SttFileProgressCallback? onProgress,
  }) async {
    if (!supported) throw StateError('unsupported');
    return SttResult(
      text: '今天讨论了 Mac 麦克风会议录音方案。',
      sourcePath: path,
      language: sourceLanguage,
      segments: const [
        SttSegment(
          text: '今天讨论了 Mac 麦克风会议录音方案。',
          startMs: 0,
          endMs: 3000,
        ),
      ],
    );
  }
}

Uint8List _wav({required int dataBytes, int? headerSizes}) {
  final bytes = ByteData(44 + dataBytes);
  void tag(int at, String value) {
    for (var i = 0; i < 4; i++) {
      bytes.setUint8(at + i, value.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  bytes.setUint32(4, headerSizes ?? 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, 16000, Endian.little);
  bytes.setUint32(28, 32000, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  bytes.setUint32(40, headerSizes ?? dataBytes, Endian.little);
  for (var i = 0; i < dataBytes; i++) {
    bytes.setUint8(44 + i, _pcmPattern[i % _pcmPattern.length]);
  }
  return bytes.buffer.asUint8List();
}

class _FixedPlace implements PlaceCapture {
  @override
  Future<RecordingPlace?> capture() async => RecordingPlace(
    label: '上海市 徐汇区',
    source: RecordingPlaceSource.automatic,
    capturedAt: DateTime.now(),
  );
}

/// Stands in for the system's open panel, choosing [path].
class _OpenPanel extends FileSelectorPlatform {
  _OpenPanel(this.path);

  final String path;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => XFile(path);
}

/// Writes a real WAV on stop so the save path runs on actual bytes.
class _FakePhoneRecorder implements PhoneRecorder {
  _FakePhoneRecorder({required this.permission});

  final bool permission;
  final states$ = StreamController<PhoneMicState>.broadcast();
  String? path;
  int starts = 0;
  int pauses = 0;
  int resumes = 0;

  /// When set, stop waits for it, so a test can act while the take saves.
  Completer<void>? stopGate;

  @override
  Future<bool> requestPermission() async => permission;

  @override
  Stream<PhoneMicState> get states => states$.stream;

  @override
  Future<void> start(String path) async {
    starts++;
    this.path = path;
    await File(path).writeAsBytes(_wav(dataBytes: 0, headerSizes: 0));
  }

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> resume() async => resumes++;

  @override
  Future<void> stop() async {
    await stopGate?.future;
    await File(path!).writeAsBytes(_wav(dataBytes: 64000));
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async => states$.close();
}

/// The recording sheet's breathing dot never settles, so dialog transitions
/// over it are pumped for a fixed time instead of `pumpAndSettle`.
Future<void> pumpDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}
