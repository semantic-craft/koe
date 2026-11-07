import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:koe/ai/apple_speech.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/audio/opus_pcm_decoder.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/ble/realtime_stream.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('soundcore/apple_speech');
  const events = MethodChannel('soundcore/apple_speech/events');
  final calls = <MethodCall>[];
  late AppleSpeechService service;
  Future<Object?> Function(MethodCall)? handler;

  Future<void> emit(Map<String, Object?> event) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    handler = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return handler?.call(call);
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      events,
      (_) async => null,
    );
    service = AppleSpeechService();
  });

  tearDown(() async {
    await service.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('unsupported platforms do not invoke any processing bridge', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect((await service.capabilities()).supported, isFalse);
    await expectLater(
      service.transcribePath('/saved.wav', sourceLanguage: 'en-US'),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'unsupported'),
      ),
    );
    expect(calls, isEmpty);
  });

  test('missing iOS bridge safely reports unsupported', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    expect((await service.capabilities()).supported, isFalse);
  });

  test(
    'capability reads never implicitly prepare or select a language',
    () async {
      handler = (call) async => {
        'supported': true,
        'speechStatus': 'needsDownload',
        'translationStatus': 'ready',
        'speechLanguages': [
          {'code': 'en-US', 'name': 'English (US)'},
        ],
        'translationLanguages': [
          {'code': 'zh-Hans', 'name': '简体中文'},
        ],
        'suggestedSourceLanguage': 'en-US',
      };
      final capability = await service.capabilities(
        sourceLanguage: 'en-US',
        targetLanguage: 'zh-Hans',
      );
      expect(capability.speechStatus, SpeechResourceStatus.needsDownload);
      expect(capability.translationStatus, SpeechResourceStatus.ready);
      expect(capability.speechLanguages.single.code, 'en-US');
      expect(capability.suggestedSourceLanguage, 'en-US');
      expect(calls.map((call) => call.method), ['capabilities']);
      await service.prepareLanguages(
        sourceLanguage: 'en-US',
        targetLanguage: 'zh-Hans',
      );
      expect(calls.last.method, 'prepareLanguages');
      expect(calls.last.arguments, containsPair('sourceLanguage', 'en-US'));
      expect(calls.last.arguments, containsPair('targetLanguage', 'zh-Hans'));
      expect(calls.last.arguments['jobId'], isA<String>());
    },
  );

  test(
    'saved translation preparation does not invoke speech preparation',
    () async {
      await service.prepareTranslation(
        sourceLanguage: 'pl',
        targetLanguage: 'zh-Hans',
      );
      expect(calls.map((call) => call.method), ['prepareTranslation']);
      expect(calls.single.arguments, containsPair('sourceLanguage', 'pl'));
      expect(calls.single.arguments, containsPair('targetLanguage', 'zh-Hans'));
      expect(calls.single.arguments['jobId'], isA<String>());
      handler = (_) async => throw PlatformException(code: 'cancelled');
      await expectLater(
        service.prepareTranslation(
          sourceLanguage: 'pl',
          targetLanguage: 'zh-Hans',
        ),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect(calls.any((call) => call.method == 'prepareLanguages'), isFalse);
    },
  );

  for (final prepareSpeech in [true, false]) {
    test(
      'live stream cancels ${prepareSpeech ? 'speech' : 'translation'} preparation and rejects its late result',
      () async {
        final prepared = Completer<Object?>();
        handler = (call) async =>
            call.method.startsWith('prepare') ? prepared.future : null;
        final preparation = prepareSpeech
            ? service.prepareLanguages(sourceLanguage: 'en-US')
            : service.prepareTranslation(
                sourceLanguage: 'pl',
                targetLanguage: 'zh-Hans',
              );
        final rejected = expectLater(
          preparation,
          throwsA(
            isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        final preparationID = calls.single.arguments['jobId'];
        final session = service.createStreamSession(sourceLanguage: 'en-US');
        await session.start();
        expect(calls[1].method, 'cancelFile');
        expect(calls[1].arguments['jobId'], preparationID);
        expect(calls[2].method, 'startStream');
        prepared.complete(null);
        await rejected;
        expect(session.isServerReady, isTrue);
        await session.dispose();
      },
    );
  }

  test(
    'explicit cancellation includes preparation without a transcription job',
    () async {
      final prepared = Completer<Object?>();
      handler = (call) async =>
          call.method == 'prepareTranslation' ? prepared.future : null;
      final preparation = service.prepareTranslation(
        sourceLanguage: 'pl',
        targetLanguage: 'zh-Hans',
      );
      final rejected = expectLater(
        preparation,
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await service.cancelFileProcessing();
      expect(calls.last.method, 'cancelFile');
      expect(calls.last.arguments['jobId'], calls.first.arguments['jobId']);
      prepared.complete(null);
      await rejected;
    },
  );

  test(
    'graceful finish keeps late finalized translation before closing',
    () async {
      final completed = Completer<Object?>();
      handler = (call) async =>
          call.method == 'finishStream' ? completed.future : null;
      final session = service.createStreamSession(
        sourceLanguage: 'en-US',
        targetLanguage: 'zh-Hans',
      );
      await session.start();
      final id = calls.last.arguments['sessionId'];
      final finishing = session.finish();
      await Future<void>.delayed(Duration.zero);
      final finalized = {
        'sessionId': id,
        'type': 'partial',
        'text': 'Last words.',
        'isFinal': true,
        'translationTurns': [
          {
            'sourceLanguage': 'en-US',
            'targetLanguage': 'zh-Hans',
            'sourceText': 'Last words.',
            'text': '最后的话。',
            'isFinal': true,
          },
        ],
      };
      await emit(finalized);
      expect(calls.any((call) => call.method == 'closeStream'), isFalse);
      completed.complete({...finalized, 'type': 'done'});
      final result = await finishing;
      expect(result?.text, 'Last words.');
      expect(result?.translationTurns.single.text, '最后的话。');
      expect(calls.last.method, 'closeStream');
      await session.dispose();
    },
  );

  test(
    'finish timeout closes native work and ignores late translations',
    () async {
      final completed = Completer<Object?>();
      handler = (call) async =>
          call.method == 'finishStream' ? completed.future : null;
      final session = service.createStreamSession(
        sourceLanguage: 'en-US',
        targetLanguage: 'zh-Hans',
      );
      final received = <SttStreamEvent>[];
      final subscription = session.events.listen(received.add);
      await session.start();
      final id = calls.last.arguments['sessionId'];
      await emit({'sessionId': id, 'type': 'partial', 'text': 'Kept source.'});
      await expectLater(
        session.finish(timeout: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      expect(calls.last.method, 'closeStream');
      await emit({'sessionId': id, 'type': 'partial', 'text': 'late'});
      completed.complete({'type': 'done', 'text': 'late'});
      await Future<void>.delayed(Duration.zero);
      expect(received.map((event) => event.text), ['Kept source.']);
      await subscription.cancel();
      await session.dispose();
    },
  );

  test(
    'cancelled file output is rejected and a new job has its own ID',
    () async {
      final result = Completer<Object?>();
      handler = (call) async =>
          call.method == 'transcribeFile' ? result.future : null;
      final first = service.transcribePath(
        '/saved.wav',
        sourceLanguage: 'en-US',
      );
      final failed = expectLater(
        first,
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final firstID = calls.single.arguments['jobId'];
      await expectLater(
        service.translate('hello', sourceLanguage: 'en', targetLanguage: 'zh'),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'busy')),
      );
      await service.cancelFileProcessing();
      result.complete({'text': 'late result'});
      await failed;
      handler = (call) async => '你好';
      expect(
        await service.translate(
          'hello',
          sourceLanguage: 'en',
          targetLanguage: 'zh',
        ),
        '你好',
      );
      expect(calls.last.arguments['jobId'], isNot(firstID));
      expect(calls.map((call) => call.method), [
        'transcribeFile',
        'cancelFile',
        'translate',
      ]);
    },
  );

  test(
    'stream filters old sessions and keeps source after translation errors',
    () async {
      final session = service.createStreamSession(
        sourceLanguage: 'en-US',
        targetLanguage: 'zh-Hans',
      );
      final received = <SttStreamEvent>[];
      final subscription = session.events.listen(received.add);
      await session.start();
      final id = calls.last.arguments['sessionId'];
      await emit({
        'sessionId': 'old',
        'type': 'partial',
        'text': 'old recording',
      });
      await emit({'sessionId': id, 'type': 'partial', 'text': 'current words'});
      await emit({
        'sessionId': id,
        'type': 'translationError',
        'text': 'current words',
        'error': 'resources_missing',
      });
      expect(received.map((event) => event.text), [
        'current words',
        'current words',
      ]);
      expect(session.isServerReady, isTrue);
      await session.close();
      await emit({'sessionId': id, 'type': 'partial', 'text': 'too late'});
      expect(received, hasLength(2));
      await subscription.cancel();
      await session.dispose();
    },
  );

  test(
    'finish drains accepted PCM before finalizing and emits done once',
    () async {
      final firstPacket = Completer<Object?>();
      var pcmCount = 0;
      handler = (call) async {
        if (call.method == 'appendPcm' && pcmCount++ == 0) {
          return firstPacket.future;
        }
        if (call.method == 'finishStream') {
          return {'type': 'done', 'text': 'final', 'isFinal': true};
        }
        return null;
      };
      final session = service.createStreamSession(sourceLanguage: 'en-US');
      final received = <SttStreamEvent>[];
      final subscription = session.events.listen(received.add);
      await session.start();
      session.sendPcm(Uint8List.fromList([1, 2]));
      session.sendPcm(Uint8List.fromList([3, 4]));
      final finish = session.finish();
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method), ['startStream', 'appendPcm']);
      firstPacket.complete(null);
      expect((await finish)?.text, 'final');
      expect(calls.map((c) => c.method), [
        'startStream',
        'appendPcm',
        'appendPcm',
        'finishStream',
        'closeStream',
      ]);
      expect(received.where((event) => event.type == 'done'), hasLength(1));
      await subscription.cancel();
      await session.dispose();
    },
  );

  test(
    'macOS target platform uses native capabilities when available and supports zh-CN, en-US, ja-JP',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      handler = (call) async {
        if (call.method == 'capabilities') {
          return {
            'supported': true,
            'speechStatus': 'ready',
            'translationStatus': 'ready',
            'suggestedSourceLanguage': 'zh-CN',
          };
        }
        if (call.method == 'transcribeFile') {
          return {'text': '会议纪要文件转写', 'durationSec': 12.5};
        }
        return null;
      };

      expect(service.offered, isTrue);
      final capability = await service.capabilities(sourceLanguage: 'zh-CN');
      expect(calls.map((c) => c.method), ['capabilities']);
      expect(capability.supported, isTrue);
      expect(capability.speechStatus, SpeechResourceStatus.ready);
      expect(capability.statusLabel, '已就绪');
      expect(capability.unavailableReason, isNull);
      expect(
        capability.speechLanguages.map((l) => l.code),
        containsAll(['zh-CN', 'en-US', 'ja-JP']),
      );

      final controller = RecorderController(
        loadPersistedState: false,
        appleSpeech: service,
      );
      addTearDown(controller.dispose);
      await controller.refreshAppleCapabilities();
      expect(controller.speechProviders, contains(SttProvider.apple));
      expect(controller.engineConfigured(SttProvider.apple), isTrue);
      expect(controller.appleSpeechReady, isTrue);

      final result = await service.transcribePath(
        '/meeting.wav',
        sourceLanguage: 'zh-CN',
      );
      expect(result.text, '会议纪要文件转写');
      expect(result.language, 'zh-CN');
    },
  );

  test(
    'macOS below 26 reports unsupported with reason and marks engine unavailable',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      handler = (call) async => {
        'supported': false,
        'speechStatus': 'unsupported',
        'translationStatus': 'unsupported',
        'unavailableReason': '需要 macOS 26 及以上',
      };

      final capability = await service.capabilities(sourceLanguage: 'zh-CN');
      expect(calls.map((c) => c.method), ['capabilities']);
      expect(capability.supported, isFalse);
      expect(capability.speechStatus, SpeechResourceStatus.unsupported);
      expect(capability.statusLabel, '不可用');
      expect(capability.unavailableReason, '需要 macOS 26 及以上');

      final controller = RecorderController(
        loadPersistedState: false,
        appleSpeech: service,
      );
      addTearDown(controller.dispose);
      await controller.refreshAppleCapabilities();
      expect(controller.speechProviders, contains(SttProvider.apple));
      expect(controller.engineConfigured(SttProvider.apple), isFalse);
      expect(controller.appleCapabilities.statusLabel, '不可用');
      expect(
        controller.appleCapabilities.unavailableReason,
        '需要 macOS 26 及以上',
      );
    },
  );

  test(
    'macOS live stream propagates microphone_permission_denied error code and reason to Dart',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      handler = (call) async {
        if (call.method == 'startStream') {
          throw PlatformException(
            code: 'microphone_permission_denied',
            message: '没有麦克风权限，无法开始实时转写',
          );
        }
        return null;
      };

      final session = service.createStreamSession(
        sourceLanguage: 'zh-CN',
        microphone: true,
      );
      await expectLater(
        session.start(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'microphone_permission_denied')
              .having((e) => e.message, 'message', '没有麦克风权限，无法开始实时转写'),
        ),
      );
      expect(session.isOpen, isFalse);
      expect(session.isServerReady, isFalse);
      expect(calls.first.method, 'startStream');
      expect(calls.first.arguments, containsPair('microphone', true));
      await session.dispose();

      // RecorderController 侧：本机引擎实时流启动抛 microphone_permission_denied 时，
      // transcriptError 应映射为明确中文提示而非「处理失败，请重试」。
      _ensureMacosOpusLibraryLoaded();
      handler = (call) async {
        if (call.method == 'capabilities') {
          return {
            'supported': true,
            'speechStatus': 'ready',
            'translationStatus': 'ready',
            'suggestedSourceLanguage': 'zh-CN',
          };
        }
        if (call.method == 'startStream') {
          throw PlatformException(
            code: 'microphone_permission_denied',
            message: '没有麦克风权限，无法开始实时转写',
          );
        }
        return null;
      };
      final controller = RecorderController(
        loadPersistedState: false,
        ble: _ConnectedBle(),
        appleSpeech: service,
        transcriptPersister: ({bool strict = false}) async {},
      )
        ..connected = true
        ..phase = AppPhase.ready;
      addTearDown(controller.dispose);
      await controller.refreshAppleCapabilities();
      controller.setSpeechProvider(SttProvider.apple);
      await controller.startRecord();
      controller.handleRealtimeOpusFrameForTesting(_validOpusFrame());
      for (var i = 0; i < 20 && controller.transcriptError == null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        controller.transcriptError,
        '没有麦克风权限，请在系统设置中允许 Koe 使用麦克风',
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'macOS settings screen lists Apple engine and shows 不可用 with macOS 26 reason when unsupported',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      handler = (call) async => {
        'supported': false,
        'speechStatus': 'unsupported',
        'translationStatus': 'unsupported',
        'unavailableReason': '需要 macOS 26 及以上',
      };
      final controller = RecorderController(
        loadPersistedState: false,
        appleSpeech: service,
      );
      addTearDown(controller.dispose);
      await controller.refreshAppleCapabilities();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pump();

      final appleCard = find.byKey(
        const ValueKey('speech-provider-option-apple'),
      );
      expect(appleCard, findsOneWidget);
      expect(
        find.descendant(of: appleCard, matching: find.text('Apple 设备端')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: appleCard, matching: find.text('不可用')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: appleCard, matching: find.text('需要 macOS 26 及以上')),
        findsOneWidget,
      );
      expect(find.text('设备受限'), findsNothing);
      expect(find.textContaining('iOS 本地神经网络'), findsNothing);

      controller.setSpeechProvider(SttProvider.apple);
      await tester.pump();
      expect(find.text('需要 macOS 26 及以上'), findsNWidgets(2));
      expect(find.textContaining('需要 iOS 26'), findsNothing);

      handler = (call) async => {
        'supported': true,
        'speechStatus': 'ready',
        'translationStatus': 'ready',
        'suggestedSourceLanguage': 'zh-CN',
      };
      await controller.refreshAppleCapabilities();
      await tester.pump();

      expect(
        find.descendant(of: appleCard, matching: find.text('使用中')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: appleCard,
          matching: find.text('Apple 本地神经网络语音引擎，离线可用、隐私优先'),
        ),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'iOS settings screen shows 不可用 with iOS 26 reason when unsupported',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      handler = (call) async => {
        'supported': false,
        'speechStatus': 'unsupported',
        'translationStatus': 'unsupported',
        'unavailableReason': '需要 iOS 26 及以上',
      };
      final controller = RecorderController(
        loadPersistedState: false,
        appleSpeech: service,
      );
      addTearDown(controller.dispose);
      await controller.refreshAppleCapabilities();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pump();

      final appleCard = find.byKey(
        const ValueKey('speech-provider-option-apple'),
      );
      expect(appleCard, findsOneWidget);
      expect(
        find.descendant(of: appleCard, matching: find.text('不可用')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: appleCard, matching: find.text('需要 iOS 26 及以上')),
        findsOneWidget,
      );
      expect(find.text('设备受限'), findsNothing);

      controller.setSpeechProvider(SttProvider.apple);
      await tester.pump();
      expect(find.text('需要 iOS 26 及以上'), findsNWidgets(2));
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'legacy auto-filled en-US appleSourceLanguage refreshes to suggested zh-CN, '
    'SettingsScreen shows 原文语言 when Qwen is selected with meetingLocalOnly, '
    'and live Apple stream preserves timed segments on the finished recording',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      late Directory tempDir;
      late File clip;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('koe-apple-zh-');
        clip = File('${tempDir.path}/1794019668.wav');
        await clip.writeAsBytes(wavBytes(List.filled(64000, 0)));
        final settingsFile = File(
          '${tempDir.path}/AnkerRecorder/app_settings.json',
        );
        await settingsFile.parent.create(recursive: true);
        await settingsFile.writeAsString(
          jsonEncode({
            'speechProvider': 'qwen',
            'appleSourceLanguage': 'en-US',
            'meetingLocalOnly': true,
            'transcriptLanguage': 'auto',
          }),
        );
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => tempDir.path,
      );
      addTearDown(() async {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        await tester.runAsync(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
      });

      String? startedSourceLanguage;
      String? activeSessionId;
      handler = (call) async {
        if (call.method == 'capabilities') {
          return {
            'supported': true,
            'speechStatus': 'ready',
            'translationStatus': 'ready',
            'suggestedSourceLanguage': 'zh-CN',
          };
        }
        if (call.method == 'startStream') {
          startedSourceLanguage = call.arguments['sourceLanguage'] as String?;
          activeSessionId = call.arguments['sessionId'] as String?;
          return null;
        }
        if (call.method == 'finishStream') {
          return {
            'sessionId': activeSessionId,
            'type': 'done',
            'text': '测试一下实时中文语音识别。\n看看能不能把我的中文识别出来。',
            'isFinal': true,
            'speechFinal': true,
            'segments': [
              {
                'text': '测试一下实时中文语音识别。',
                'startMs': 0,
                'endMs': 1800,
              },
              {
                'text': '看看能不能把我的中文识别出来。',
                'startMs': 2000,
                'endMs': 3800,
              },
            ],
          };
        }
        return null;
      };

      late RecorderController controller;
      await tester.runAsync(() async {
        controller = RecorderController(
          loadPersistedState: true,
          ble: _ConnectedBle(),
          appleSpeech: service,
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${tempDir.path}/imports'),
        )
          ..connected = true
          ..phase = AppPhase.ready;
        for (var i = 0;
            i < 100 && controller.appleSourceLanguage != 'zh-CN';
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      addTearDown(controller.dispose);

      expect(
        controller.appleSourceLanguage,
        'zh-CN',
        reason: 'legacy unflagged en-US must refresh to suggested zh-CN',
      );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('原文语言'),
        findsOneWidget,
        reason: 'on-device source language selector must be visible when meetingLocalOnly is on',
      );

      await tester.runAsync(() async {
        controller.recording = true;
        controller.handleRealtimeStateForTesting(
          RealtimeStreamState(
            active: true,
            fileId: 1794019668,
            path: clip.path,
            bytesReceived: 3200,
          ),
        );
        for (var i = 0; i < 100 && startedSourceLanguage == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(startedSourceLanguage, 'zh-CN');

        await emit({
          'sessionId': activeSessionId,
          'type': 'partial',
          'text': '测试一下实时中文语音识别。',
          'isFinal': true,
          'speechFinal': true,
          'segments': [
            {
              'text': '测试一下实时中文语音识别。',
              'startMs': 0,
              'endMs': 1800,
            },
          ],
        });

        controller.recording = false;
        controller.handleRealtimeStateForTesting(
          RealtimeStreamState(
            active: false,
            fileId: 1794019668,
            path: clip.path,
            bytesReceived: 64000,
          ),
        );
        for (var i = 0;
            i < 100 &&
                controller
                        .recordingView(
                          RecordingReference(fileId: 1794019668, path: clip.path),
                        )
                        .segments
                        .length <
                    2;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });

      final view = controller.recordingView(
        RecordingReference(fileId: 1794019668, path: clip.path),
      );
      expect(view.text, '测试一下实时中文语音识别。\n看看能不能把我的中文识别出来。');
      expect(view.segments, hasLength(2));
      expect(view.segments.first.text, '测试一下实时中文语音识别。');
      expect(view.segments.last.start, const Duration(milliseconds: 2000));

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: MaterialApp(
            home: RecordingDetailScreen(
              reference: RecordingReference(
                fileId: 1794019668,
                path: clip.path,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('这条转写没有可靠的逐句时码'),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

class _ConnectedBle extends BleService {
  @override
  bool get isConnected => true;

  @override
  Future<void> writeCommand(List<int> frame) async {}
}

const String _opus20msPacketHex =
    '7881a75d6c9e99ac0000067e5639f73b1ea2dc310f523839393ea3d08447cbe1'
    'b6b8ff44143d7621af0734dd0787ec99fec0f544189d5f482942ded82f85b618'
    'f43b6492de947050e097687d6c10d0af638553a27165e791290180531504';

Uint8List _validOpusFrame() => Uint8List.fromList(<int>[
  for (var i = 0; i < _opus20msPacketHex.length; i += 2)
    int.parse(_opus20msPacketHex.substring(i, i + 2), radix: 16),
]);

void _ensureMacosOpusLibraryLoaded() {
  if (!Platform.isMacOS) return;
  final configFile = File(
    '${Directory.current.path}/.dart_tool/package_config.json',
  );
  if (!configFile.existsSync()) return;
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
  final packages = config['packages'] as List<Object?>;
  for (final entry in packages) {
    final package = entry as Map<String, Object?>;
    if (package['name'] != 'opus_codec_macos') continue;
    final rootUri = configFile.parent.uri.resolve(package['rootUri'] as String);
    final rootDir = Directory(rootUri.toFilePath());
    final binaries = Directory('${rootDir.path}/macos/opus.xcframework')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('/opus.framework/opus'))
        .toList();
    if (binaries.isNotEmpty) {
      OpusPcmDecoder.debugUseOpusLibrary(
        DynamicLibrary.open(binaries.first.path),
      );
    }
    break;
  }
}
