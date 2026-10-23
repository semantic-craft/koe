import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/platform/mac_app.dart';
import 'package:koe/platform/phone_mic_stream.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/mac_menu_bar.dart';

import 'support/fake_foreground_service.dart';

/// One second of 16 kHz mono PCM16.
const _second = 32000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late _Mic mic;
  late _FileStt fileStt;
  late List<_Stream> streams;
  late bool offline;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-text-capture-');
    mic = _Mic();
    fileStt = _FileStt();
    streams = [];
    offline = false;
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  Directory spoolDir() => Directory('${directory.path}/text_capture');
  File minutesFile() => File('${directory.path}/minutes.json');

  RecorderController build({
    bool disposeAtEnd = true,
    BleService? ble,
    bool loadPersistedState = false,
  }) {
    final controller = RecorderController(
      ble: ble,
      loadPersistedState: loadPersistedState,
      analysisController: RecordingAnalysis(inMemory: true),
      qwenSpeech: fileStt..apiKeyOverride = 'test-key',
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${directory.path}/imports'),
      minutesStore: MinutesDocumentStore(file: minutesFile()),
      placeCapture: _NoPlace(),
      phoneRecordingEnabled: true,
      micStream: mic,
      speechStream: (_) {
        final stream = _Stream(offline: offline);
        streams.add(stream);
        return stream;
      },
    );
    if (disposeAtEnd) addTearDown(controller.dispose);
    return controller;
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  bool noSpools() =>
      !spoolDir().existsSync() ||
      spoolDir().listSync().whereType<File>().isEmpty;

  test(
    'a dropped connection reconnects and resends the unfinished sentence',
    () async {
      final controller = build();
      expect(await controller.startTextCapture(), isTrue);
      await until(() => controller.textCaptureConnected);

      mic.speak(_second);
      await until(() => streams.first.received == _second);
      streams.first.emit('第一句。', speechFinal: true);
      mic.speak(_second ~/ 2);
      await until(() => streams.first.received == _second + _second ~/ 2);
      streams.first.emit('第一句。\n第二');
      await Future<void>.delayed(Duration.zero);
      expect(controller.textCaptureText, '第一句。\n第二');

      streams.first.fail();
      await until(() => streams.length == 2 && streams[1].received > 0);
      // Only the speech after the finished sentence goes out again.
      await until(() => streams[1].received == _second ~/ 2);
      streams[1].emit('第二句说完了。', speechFinal: true);
      streams[1].finalText = '第二句说完了。';

      final outcome = await controller.stopTextCapture();

      expect(outcome!.document!.bodyText, '第一句。\n第二句说完了。');
      expect(outcome.document!.textOnly, isTrue);
      expect(outcome.pendingSeconds, 0);
      expect(controller.minutesDocuments.single.warning, isNull);
      expect(controller.library.assets, isEmpty);
      expect(noSpools(), isTrue);
    },
  );

  test(
    'speech with no network is recognized from the phone after stopping',
    () async {
      offline = true;
      final controller = build();
      expect(await controller.startTextCapture(), isTrue);
      mic.speak(_second * 2);
      await until(() => controller.textCaptureElapsed.inSeconds == 2);
      expect(controller.textCaptureConnected, isFalse);
      fileStt.reply = '地铁里说的话。';

      final outcome = await controller.stopTextCapture();
      expect(outcome!.pendingSeconds, 2);

      await until(() => controller.minutesDocuments.single.warning == null);
      expect(controller.minutesDocuments.single.bodyText, '地铁里说的话。');
      expect(fileStt.calls, 1);
      expect(controller.library.assets, isEmpty);
      await until(noSpools);
    },
  );

  test('a capture cut off by a crash is finished on the next launch', () async {
    final first = build(disposeAtEnd: false);
    expect(await first.startTextCapture(), isTrue);
    await until(() => first.textCaptureConnected);
    mic.speak(_second);
    await until(() => streams.first.received == _second);
    streams.first.emit('崩溃前说完的。', speechFinal: true);
    await until(
      () => first.minutesDocuments.any((d) => d.bodyText == '崩溃前说完的。'),
    );
    mic.speak(_second);
    await until(() => streams.first.received == _second * 2);
    // Let the draft's position reach disk, then kill without stopping.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    first.dispose();

    fileStt.reply = '崩溃后没来得及识别的。';
    mic = _Mic();
    final second = build();
    await second.waitForMinutesDocuments();
    await until(() => second.minutesDocuments.single.warning == null);

    expect(second.minutesDocuments.single.bodyText, '崩溃前说完的。\n崩溃后没来得及识别的。');
    expect(fileStt.calls, 1);
    await until(noSpools);
  });

  group('all-day listening', () {
    setUp(() {
      AllDayTiming.sleepAfter = const Duration(milliseconds: 150);
      AllDayTiming.splitAfter = const Duration(milliseconds: 400);
      AllDayTiming.tick = const Duration(milliseconds: 20);
    });
    tearDown(() {
      AllDayTiming.sleepAfter = const Duration(seconds: 20);
      AllDayTiming.splitAfter = const Duration(minutes: 10);
      AllDayTiming.tick = const Duration(seconds: 5);
    });

    test('sends only speech, rests when quiet and splits records', () async {
      final controller = build();
      expect(await controller.startTextCapture(allDay: true), isTrue);

      mic.speak(_second);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Quiet audio opens no connection and goes nowhere.
      expect(streams, isEmpty);

      mic.say(_second);
      await until(() => streams.length == 1 && streams.first.received > 0);
      // The speech plus the half second just before it.
      await until(() => streams.first.received == _second + _second ~/ 2);
      streams.first.emit('第一段。', speechFinal: true);
      streams.first.finalText = '第一段。';

      // Quiet: the connection is finished, then the record is saved.
      await until(() => streams.first.finished);
      await until(() => controller.textCaptureFinishedRecords == 1);
      expect(controller.minutesDocuments.single.bodyText, '第一段。');
      expect(controller.minutesDocuments.single.warning, isNull);
      expect(controller.textCaptureActive, isTrue);

      mic.say(_second);
      await until(() => streams.length == 2 && streams[1].received > 0);
      streams[1].emit('第二段。', speechFinal: true);
      streams[1].finalText = '第二段。';
      await controller.stopTextCapture();

      expect(controller.minutesDocuments.map((d) => d.bodyText).toSet(), {
        '第一段。',
        '第二段。',
      });
      expect(controller.library.assets, isEmpty);
      expect(noSpools(), isTrue);
    });

    test('the recorder key starts it and stopping the take saves it', () async {
      final ble = _Ble();
      final controller = build(ble: ble)
        ..connected = true
        ..allDayListening = true;

      ble.audio(1);
      await until(() => controller.textCaptureFromDevice);
      expect(controller.textCaptureAllDay, isTrue);
      expect(mic.started, isFalse);

      final speech = ByteData(_second);
      for (var i = 0; i < _second; i += 2) {
        speech.setInt16(i, i % 4 == 0 ? 1200 : -1200, Endian.little);
      }
      controller.feedDeviceTextCapture(speech.buffer.asUint8List());
      await until(() => streams.length == 1 && streams.first.received > 0);
      streams.first.emit('录音豆听到的话。', speechFinal: true);
      streams.first.finalText = '录音豆听到的话。';

      ble.audio(0);
      await until(() => !controller.textCaptureActive);
      expect(controller.minutesDocuments.single.bodyText, '录音豆听到的话。');
    });

    test('on Android it listens as microphone work of the foreground '
        'service; 停止 on the notification saves the text and it does not '
        'resume', () async {
      final service = FakeForegroundService();
      final first = build(disposeAtEnd: false)..allDayListening = true;
      expect(await first.startTextCapture(allDay: true), isTrue);
      await until(() => service.running);
      expect(service.types, {'microphone'});
      expect(service.text, 'Koe 正在全天监听（只留文字）');
      expect(service.stoppable, isTrue);

      mic.say(_second);
      await until(() => streams.length == 1 && streams.first.received > 0);
      streams.first.emit('锁屏时说的话。', speechFinal: true);
      streams.first.finalText = '锁屏时说的话。';

      await service.pressStop();
      await until(() => !first.textCaptureActive && !service.running);
      expect(first.minutesDocuments.single.bodyText, '锁屏时说的话。');
      first.dispose();

      // Reopening Koe does not start listening again on its own.
      mic = _Mic();
      final second = build()..allDayListening = true;
      await second.waitForMinutesDocuments();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(second.textCaptureActive, isFalse);
      expect(mic.started, isFalse);
      expect(service.running, isFalse);
    });

    test('on Android 开始录音 on the Koe icon enters it from the phone, as '
        'microphone work of the foreground service', () async {
      final service = FakeForegroundService();
      final controller = build()..allDayListening = true;

      await controller.requestRecordingFromShortcut();

      expect(controller.textCaptureActive, isTrue);
      expect(controller.textCaptureAllDay, isTrue);
      expect(mic.started, isTrue);
      await until(() => service.running);
      expect(service.types, {'microphone'});
      expect(controller.errorMessage, isNull);
      await controller.stopTextCapture();
    });

    test('on Android, listening Android refuses while Koe is off screen '
        'stops and says why, and starts again once Koe is back on '
        'screen', () async {
      final service = FakeForegroundService();
      final controller = build()..allDayListening = true;
      expect(await controller.startTextCapture(allDay: true), isTrue);
      await until(() => service.running);

      await service.refuse();

      await until(() => !controller.textCaptureActive);
      expect(
        controller.textCaptureError,
        'Koe 不在屏幕上时 Android 不让它开始用麦克风，回到 Koe 后接着听',
      );

      final binding = TestWidgetsFlutterBinding.instance;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await until(() => controller.textCaptureActive);
      expect(controller.textCaptureAllDay, isTrue);
      expect(controller.textCaptureError, isNull);
      await until(() => service.running);
      await controller.stopTextCapture();
    });

    test('a cold launch from 开始录音 waits for the saved switch', () async {
      await AppSettingsStore.save(
        const AppSettings(
          allDayListening: true,
          engines: {'qwen': EngineConfig(apiKey: 'test-key')},
        ),
        strict: true,
      );
      final controller = build(loadPersistedState: true);
      expect(controller.allDayListening, isFalse, reason: 'not read yet');

      await controller.requestRecordingFromShortcut();

      expect(controller.textCaptureActive, isTrue);
      expect(controller.textCaptureAllDay, isTrue);
      await controller.stopTextCapture();
    });

    test('开始录音 says why listening did not start', () async {
      mic.allowed = false;
      final controller = build()..allDayListening = true;

      await controller.requestRecordingFromShortcut();

      expect(controller.textCaptureActive, isFalse);
      expect(controller.statusMessage, '快捷录音未开始');
      expect(controller.errorMessage, '没有麦克风权限。可在系统设置里允许 Koe 使用麦克风');
    });

    test('reopening Koe continues listening that was left on', () async {
      final first = build(disposeAtEnd: false)..allDayListening = true;
      expect(await first.startTextCapture(allDay: true), isTrue);
      first.dispose();

      mic = _Mic();
      final second = build()..allDayListening = true;
      await until(() => second.textCaptureActive);
      expect(second.textCaptureAllDay, isTrue);
      await second.stopTextCapture();

      mic = _Mic();
      final third = build()..allDayListening = true;
      await third.waitForMinutesDocuments();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Stopped by the user: not resumed.
      expect(third.textCaptureActive, isFalse);
    });

    test('quitting Koe on the Mac saves the text, and listening goes on '
        'when it opens again', () async {
      const channel = MethodChannel('test/mac_app');
      final first = build(disposeAtEnd: false)..allDayListening = true;
      final bar = MacMenuBar(
        first,
        onStart: () {},
        app: MacApp(channel: channel, enabled: true),
      );
      expect(await first.startTextCapture(allDay: true), isTrue);
      mic.say(_second);
      await until(() => streams.length == 1 && streams.first.received > 0);
      streams.first.emit('退出前说的。', speechFinal: true);
      streams.first.finalText = '退出前说的。';

      // 退出 in the question the Mac asks.
      final answered = Completer<void>();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(const MethodCall('quit')),
            (_) => answered.complete(),
          );
      await answered.future;
      expect(first.textCaptureActive, isFalse);
      expect(first.minutesDocuments.single.bodyText, '退出前说的。');
      bar.dispose();
      first.dispose();

      mic = _Mic();
      final second = build()..allDayListening = true;
      await until(() => second.textCaptureActive);
      expect(second.textCaptureAllDay, isTrue);
    });

    test('quitting on the Mac while a stopped capture is still being saved '
        'waits for the save', () async {
      const channel = MethodChannel('test/mac_app');
      final controller = build()..allDayListening = true;
      final bar = MacMenuBar(
        controller,
        onStart: () {},
        app: MacApp(channel: channel, enabled: true),
      );
      addTearDown(bar.dispose);
      expect(await controller.startTextCapture(allDay: true), isTrue);
      mic.say(_second);
      await until(() => streams.length == 1 && streams.first.received > 0);
      streams.first.emit('停下前说的。', speechFinal: true);
      streams.first.finalText = '停下前说的。';
      mic.stopping = Completer<void>();

      Future<void> fromMac(String method, [Object? arguments]) {
        final answered = Completer<void>();
        unawaited(
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
                channel.name,
                channel.codec.encodeMethodCall(MethodCall(method, arguments)),
                (_) => answered.complete(),
              ),
        );
        return answered.future;
      }

      // 停止全天监听 from the menu, then quitting before the text is saved.
      await fromMac('menu', 'stop');
      expect(controller.textCaptureSaving, isTrue);
      String? savedWhenQuit;
      final quit = fromMac('quit').then(
        (_) =>
            savedWhenQuit = controller.minutesDocuments.firstOrNull?.bodyText,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      mic.stopping!.complete();
      await quit;
      expect(savedWhenQuit, '停下前说的。');
      expect(controller.textCaptureActive, isFalse);
    });
  });

  test('keeping the audio saves an original that carries the text', () async {
    final controller = build();
    expect(await controller.startTextCapture(), isTrue);
    await until(() => controller.textCaptureConnected);
    mic.speak(_second);
    await until(() => streams.first.received == _second);
    streams.first.emit('留着原声。', speechFinal: true);
    streams.first.finalText = '留着原声。';

    final outcome = await controller.stopTextCapture(keepAudio: true);

    final path = outcome!.recordingPath!;
    expect(File(path).lengthSync(), 44 + _second);
    expect(controller.transcriptForPath(path), '留着原声。');
    expect(controller.minutesDocuments, isEmpty);
    expect(noSpools(), isTrue);
  });
  test('on the Mac it listens through the microphone chosen for recording '
      '(#402)', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const usb = MicInput(id: 'usb', label: 'USB 会议麦克风');
    await MicInput.write(File('${directory.path}/microphone.json'), usb);
    final choosable = mic = _ChoosableMic([usb]);
    final controller = build();

    expect(await controller.startTextCapture(), isTrue);

    expect(choosable.startedFrom, [usb.id]);
    await controller.stopTextCapture();
  });

  test('on the Mac ⌃⌥⌘R starts and ends all-day listening from any app, and '
      '⌃⌥⌘B marks the sentence said', () async {
    const channel = MethodChannel('test/mac_app');
    final controller = build()..allDayListening = true;
    final bar = MacMenuBar(
      controller,
      onStart: () {},
      app: MacApp(channel: channel, enabled: true),
    );
    addTearDown(bar.dispose);
    Future<Object?> hotKey(String key) {
      final answered = Completer<Object?>();
      unawaited(
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(MethodCall('hotKey', key)),
              (reply) => answered.complete(
                reply == null ? null : channel.codec.decodeEnvelope(reply),
              ),
            ),
      );
      return answered.future;
    }

    expect(await hotKey('record'), 'started');
    expect(controller.textCaptureAllDay, isTrue);
    mic.say(_second);
    await until(() => streams.length == 1 && streams.first.received > 0);
    streams.first.emit('先说点闲话。\n合同周五前要签。', speechFinal: true);
    streams.first.finalText = '先说点闲话。\n合同周五前要签。';
    await until(() => controller.textCaptureText.isNotEmpty);

    expect(await hotKey('highlight'), 'marked');
    expect(await hotKey('record'), 'stopped');
    expect(controller.textCaptureActive, isFalse);
    expect(
      [
        for (final segment in controller.minutesDocuments.single.segments)
          if (segment.highlighted) segment.text,
      ],
      ['合同周五前要签。'],
    );
  });

  test('a marked sentence stays marked in the saved text', () async {
    final controller = build();
    expect(controller.markTextCaptureHighlight(), isFalse);
    expect(await controller.startTextCapture(), isTrue);
    await until(() => controller.textCaptureConnected);
    mic.speak(_second);
    await until(() => streams.first.received == _second);
    streams.first.emit('先说点闲话。', speechFinal: true);
    streams.first.emit('先说点闲话。\n合同周五前要签');
    await Future<void>.delayed(Duration.zero);
    // Marks the sentence being spoken, before it is finished.
    expect(controller.markTextCaptureHighlight(), isTrue);
    streams.first.emit('先说点闲话。\n合同周五前要签。\n再说别的。', speechFinal: true);
    streams.first.finalText = '先说点闲话。\n合同周五前要签。\n再说别的。';

    final outcome = await controller.stopTextCapture();

    final marked = [
      for (final segment in outcome!.document!.segments)
        if (segment.highlighted) segment.text,
    ];
    expect(marked, ['合同周五前要签。']);
    final saved = MinutesDocumentStore.decode(
      await minutesFile().readAsString(),
    )!.values.single;
    expect(saved.segments.map((s) => s.highlighted), [false, true, false]);
  });

  testWidgets('new record offers text-only capture and saves its text', (
    tester,
  ) async {
    final controller = (await tester.runAsync(() async => build()))!;
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done(), isTrue);
    }

    await tester.tap(find.byKey(const ValueKey('new-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-record-text-capture')));
    await settle(() => controller.textCaptureConnected);
    expect(find.text('纯文字记录中'), findsOneWidget);

    streams.first.emit('界面上看得到的话。', speechFinal: true);
    streams.first.finalText = '界面上看得到的话。';
    await tester.pump();
    expect(find.text('界面上看得到的话。', findRichText: true), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mark-text-capture')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('stop-text-capture')));
    await settle(() => !controller.textCaptureActive);
    await tester.pumpAndSettle();
    expect(find.text('文字已保存到资料'), findsOneWidget);
    expect(controller.minutesDocuments.single.bodyText, '界面上看得到的话。');
    expect(
      controller.minutesDocuments.single.segments.single.highlighted,
      isTrue,
    );
  });
  testWidgets('system back while listening asks first, then saves the text', (
    tester,
  ) async {
    final controller = (await tester.runAsync(() async => build()))!;
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done(), isTrue);
    }

    Future<void> dialog() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await tester.tap(find.byKey(const ValueKey('new-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-record-text-capture')));
    await settle(() => controller.textCaptureConnected);
    streams.first.emit('返回前说的话。', speechFinal: true);
    streams.first.finalText = '返回前说的话。';
    await tester.pump();

    await tester.binding.handlePopRoute();
    await dialog();
    expect(find.text('返回会结束这次记录并保存文字。'), findsOneWidget);
    await tester.tap(find.text('继续记录'));
    await dialog();
    expect(controller.textCaptureActive, isTrue);
    expect(find.text('纯文字记录中'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await dialog();
    await tester.tap(find.byKey(const ValueKey('confirm-leave-text-capture')));
    await settle(() => !controller.textCaptureActive);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('text-capture-title')), findsNothing);
    expect(controller.minutesDocuments.single.bodyText, '返回前说的话。');
  });

  testWidgets('with all-day listening on, phone recording listens all day', (
    tester,
  ) async {
    final controller = (await tester.runAsync(() async => build()))!
      ..allDayListening = true;
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done(), isTrue);
    }

    await tester.tap(find.byKey(const ValueKey('new-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-record-phone')));
    await settle(() => controller.textCaptureActive);
    expect(controller.textCaptureAllDay, isTrue);
    expect(find.text('全天监听中'), findsOneWidget);

    // Putting the sheet away keeps listening, one tap from its controls.
    await tester.tap(find.byKey(const ValueKey('hide-text-capture')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(controller.textCaptureActive, isTrue);
    expect(find.byKey(const ValueKey('all-day-listening-bar')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('all-day-listening-bar')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('stop-text-capture')));
    await settle(() => !controller.textCaptureActive);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('all-day-listening-bar')), findsNothing);
  });

  testWidgets(
    'all-day listening started from the Mac menu bar shows its sheet, which '
    'closes when listening is ended from the menu, also after the system '
    'cut the microphone off',
    (tester) async {
      const channel = MethodChannel('test/mac_app');
      final shared = MacApp.shared;
      MacApp.shared = MacApp(channel: channel, enabled: true);
      addTearDown(() => MacApp.shared = shared);
      final controller = (await tester.runAsync(() async => build()))!
        ..allDayListening = true;
      await tester.pumpWidget(KoeApp(controller: controller));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      Future<void> settle(bool Function() done) async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(done(), isTrue);
      }

      Future<void> menu(String action) => tester.runAsync(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(MethodCall('menu', action)),
              (_) {},
            ),
      );
      final sheet = find.text('全天监听中');

      await menu('start');
      await settle(() => sheet.evaluate().isNotEmpty);
      expect(controller.textCaptureAllDay, isTrue);
      mic.cutOff();
      await settle(() => controller.textCaptureError != null);

      await menu('stop');
      await settle(
        () =>
            find.byKey(const ValueKey('text-capture-title')).evaluate().isEmpty,
      );
      expect(controller.textCaptureActive, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

class _Ble extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();

  /// The recorder reports its key: 1 = recording, 0 = stopped.
  void audio(int status) => _packets.add(
    DecodedPacket(
      raw: Uint8List(0),
      statusByte: 1,
      cmdType: 0x18,
      cmdId: 0x82,
      payload: Uint8List.fromList([status]),
    ),
  );

  @override
  Stream<DecodedPacket> get packets => _packets.stream;
  @override
  Stream<List<ScannedDevice>> get scanResults => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Stream<String> get logs => const Stream.empty();
  @override
  bool get isConnected => true;
  @override
  Future<void> writeCommand(List<int> frame) async {}
  @override
  Future<void> dispose() async {
    await _packets.close();
  }
}

class _Mic implements PhoneMicStream {
  StreamController<Uint8List>? _samples;
  bool get started => _samples != null;
  bool allowed = true;

  void speak(int bytes) => _samples!.add(Uint8List(bytes));

  /// Ends the samples, as the system does when it takes the microphone.
  void cutOff() => _samples!.close();

  /// [bytes] of audio loud enough to count as speech.
  void say(int bytes) {
    final data = ByteData(bytes);
    for (var i = 0; i + 1 < bytes; i += 2) {
      data.setInt16(i, i % 4 == 0 ? 1200 : -1200, Endian.little);
    }
    _samples!.add(data.buffer.asUint8List());
  }

  @override
  Future<bool> requestPermission() async => allowed;

  @override
  Stream<PhoneMicState> get states => const Stream.empty();

  @override
  Future<Stream<Uint8List>> start() async {
    _samples = StreamController<Uint8List>();
    return _samples!.stream;
  }

  /// When set, stopping waits for it, as a slow microphone does.
  Completer<void>? stopping;

  @override
  Future<void> stop() async {
    await stopping?.future;
    await _samples?.close();
  }

  @override
  Future<void> dispose() async {}
}

/// A Mac microphone with inputs to choose from.
class _ChoosableMic extends _Mic implements PhoneMicInputs {
  _ChoosableMic(this.connected);

  final List<MicInput> connected;
  MicInput? _input;

  /// The input each capture started from; null is the system default.
  final startedFrom = <String?>[];

  @override
  Future<List<MicInput>> inputs() async => connected;

  @override
  void useInput(MicInput? input) => _input = input;

  @override
  Future<Stream<Uint8List>> start() {
    startedFrom.add(_input?.id);
    return super.start();
  }
}

class _Stream implements SttStreamSession {
  _Stream({required this.offline});

  final bool offline;
  final _events = StreamController<SttStreamEvent>.broadcast();
  bool _ready = false;
  bool finished = false;
  int received = 0;
  String? finalText;

  void emit(String text, {bool speechFinal = false}) => _events.add(
    SttStreamEvent(type: 'partial', text: text, speechFinal: speechFinal),
  );

  void fail() {
    _ready = false;
    _events.add(const SttStreamEvent(type: 'error', error: 'dropped'));
  }

  @override
  Stream<SttStreamEvent> get events => _events.stream;

  @override
  bool get isOpen => _ready;

  @override
  bool get isServerReady => _ready;

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {
    if (offline) throw const SocketException('offline');
    _ready = true;
  }

  @override
  void sendPcm(Uint8List pcm16le) => received += pcm16le.length;

  @override
  void finalizeUtterance() {}

  @override
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    _ready = false;
    finished = true;
    return SttStreamEvent(type: 'done', text: finalText ?? '', isFinal: true);
  }

  @override
  Future<void> close() async => _ready = false;

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
  }
}

class _FileStt extends QwenSttService {
  String reply = '';
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
    return SttResult(text: reply);
  }
}

class _NoPlace implements PlaceCapture {
  @override
  Future<RecordingPlace?> capture() async => null;
}
