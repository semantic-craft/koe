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
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/mac_menu_bar.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:provider/provider.dart';

import 'support/settings_completion.dart';
import 'support/wav_fixture.dart';

/// Koe on the Mac menu bar (#403): the take and the work under way, the Mac
/// kept awake meanwhile, a question and a saved take before quitting, and a
/// notice when the disk fills up. The global hot keys ⌃⌥⌘R and ⌃⌥⌘B (#405).
/// Questions over other apps when a meeting app takes the microphone (#406).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/mac_app');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late List<Map<Object?, Object?>> updates;

  /// The hot keys other apps hold, which the Mac cannot give Koe.
  late Set<String> othersHold;

  /// The questions put over other apps.
  late List<Map<Object?, Object?>> prompts;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-mac-menu-bar-');
    updates = [];
    othersHold = {};
    prompts = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'prompt') {
        prompts.add(call.arguments as Map<Object?, Object?>);
      }
      if (call.method == 'update') {
        final update = call.arguments as Map<Object?, Object?>;
        updates.add(update);
        return [
          for (final key in update['hotKeys']! as List<Object?>)
            if (othersHold.contains(key)) key,
        ];
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

  String asked() => prompts.last['message']! as String;
  List<Object?> buttons() => [
    for (final action in prompts.last['actions']! as List<Object?>)
      (action! as Map<Object?, Object?>)['title'],
  ];

  /// Sends [method] as the Mac side does; completes with Koe's answer.
  Future<Object?> fromMac(String method, [Object? arguments]) {
    final answered = Completer<Object?>();
    unawaited(
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, arguments)),
        (reply) => answered.complete(
          reply == null ? null : channel.codec.decodeEnvelope(reply),
        ),
      ),
    );
    return answered.future;
  }

  /// Reports [apps] using the microphone, as the Mac does when they change,
  /// and lets [elapsed] go by.
  Future<void> microphone(
    WidgetTester tester,
    List<String> apps,
    Duration elapsed,
  ) async {
    unawaited(fromMac('microphoneUsers', apps));
    await tester.pump(elapsed);
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

  final sheet = find.byKey(const ValueKey('phone-recording-title'));

  /// Starts a take from the menu, which opens the recording sheet.
  Future<void> startFromMenu(WidgetTester tester, RecorderController c) async {
    await tester.runAsync(() => fromMac('menu', 'start'));
    await settle(
      tester,
      () => c.phoneRecordingActive && sheet.evaluate().isNotEmpty,
    );
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
      await settle(tester, () => !controller.phoneRecordingSaving);
      expect(controller.library.assets, hasLength(1));
      expect(shown()['state'], 'idle');
      expect(menu(), ['开始录音']);
      expect(shown()['keepAwake'], isNull);
      expect(shown()['quitMessage'], isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    '⌃⌥⌘R starts a take from another app while the window draws nothing, '
    '⌃⌥⌘B marks it, and ⌃⌥⌘R saves it with the mark',
    (tester) async {
      final controller = await openKoe(tester, _Mic());
      expect(shown()['hotKeys'], ['record']);

      // No frame between the key and the answer: Koe's window draws none
      // while it is closed or behind other windows.
      expect(
        await tester.runAsync(() => fromMac('hotKey', 'record')),
        'started',
      );
      expect(controller.phoneRecordingActive, isTrue);
      expect(shown()['hotKeys'], ['record', 'highlight']);
      // The window shows the take's controls once it draws.
      await settle(tester, () => sheet.evaluate().isNotEmpty);

      expect(
        await tester.runAsync(() => fromMac('hotKey', 'highlight')),
        'marked',
      );
      expect(
        await tester.runAsync(() => fromMac('hotKey', 'record')),
        'stopped',
      );
      final take = controller.library.assets.single.path;
      expect(
        controller
            .bookmarksFor(RecordingReference(path: take))
            .map((bookmark) => bookmark.note),
        ['录音中标的重点'],
      );
      expect(shown()['hotKeys'], ['record']);
      await settle(tester, () => sheet.evaluate().isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'a take stopped from the menu closes its sheet, and one the system cut '
    'off keeps it open to say why, where the next take shows too',
    (tester) async {
      final mic = _Mic();
      final controller = await openKoe(tester, mic);
      await startFromMenu(tester, controller);

      await tester.runAsync(() => fromMac('menu', 'stop'));
      await settle(tester, () => sheet.evaluate().isEmpty);
      expect(controller.library.assets, hasLength(1));

      await startFromMenu(tester, controller);
      mic.cutOff();
      await settle(tester, () => controller.library.assets.length == 2);
      await settle(
        tester,
        () => find.textContaining('录音被系统停下了').evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(sheet, findsOne);

      // A take started again shows in that sheet, not in a second one.
      await startFromMenu(tester, controller);
      await tester.pump(const Duration(seconds: 1));
      expect(sheet, findsOne);
      await tester.runAsync(() => fromMac('menu', 'stop'));
      await settle(tester, () => sheet.evaluate().isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'hot keys another app holds are pointed out, and once turned off they '
    'are let go and stay off',
    (tester) async {
      othersHold = {'record', 'highlight'};
      final controller = (await tester.runAsync(
        () async => RecorderController(
          loadPersistedState: false,
          libraryDirectory: Directory('${directory.path}/imports'),
          phoneRecorder: _Mic(),
          phoneRecordingEnabled: true,
          placeCapture: _NoPlace(),
        ),
      ))!;
      addTearDown(controller.dispose);
      final bar = MacMenuBar(controller, onStart: () {});
      addTearDown(bar.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      final taken = find.byKey(const ValueKey('settings-record-hot-key-taken'));
      await tester.scrollUntilVisible(
        taken,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.widget<Text>(taken).data,
        '⌃⌥⌘R 已被别的应用占用。退出那个应用后，把这个开关关掉再打开。',
      );

      // ⌃⌥⌘B is asked for only during a take, and the menu says it is held.
      await tester.runAsync(controller.startPhoneRecording);
      await settle(
        tester,
        () => (shown()['lines']! as List<Object?>).contains(
          '⌃⌥⌘B 被别的应用占用，回到 Koe 标重点',
        ),
      );
      await tester.runAsync(controller.stopPhoneRecording);

      for (final key in [
        'settings-record-hot-key',
        'settings-highlight-hot-key',
      ]) {
        final toggle = find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(Switch),
        );
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pump();
      }
      expect(shown()['hotKeys'], isEmpty);
      expect(taken, findsNothing);
      await waitForSettings(tester, controller);
      final saved = (await tester.runAsync(AppSettingsStore.load))!;
      expect(saved.recordHotKey, isFalse);
      expect(saved.highlightHotKey, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'a meeting app using the microphone for 5 seconds asks over other apps '
    'to start a take, and once the meeting is over for 10 seconds asks to '
    'stop it, which saves the take',
    (tester) async {
      final controller = await openKoe(tester, _Mic());
      expect(shown()['watchMicrophone'], isTrue);

      await microphone(tester, ['com.tencent.meeting'], seconds(4));
      expect(prompts, isEmpty);
      await tester.pump(seconds(1));
      expect(asked(), '腾讯会议 正在用麦克风，要开始录音吗？');
      expect(buttons(), ['不再提醒', '不用', '开始录音']);
      // No frame between the button and the answer, as with ⌃⌥⌘R.
      expect(
        await tester.runAsync(() => fromMac('promptAction', 'start')),
        'started',
      );
      expect(controller.phoneRecordingActive, isTrue);
      await settle(tester, () => sheet.evaluate().isNotEmpty);

      await microphone(tester, [], seconds(9));
      expect(prompts, hasLength(1));
      await tester.pump(seconds(1));
      expect(asked(), '会议好像结束了，要停止录音吗？');
      expect(buttons(), ['继续', '停止并保存']);
      expect(
        await tester.runAsync(() => fromMac('promptAction', 'stop')),
        'stopped',
      );
      expect(controller.library.assets, hasLength(1));
      await settle(tester, () => sheet.evaluate().isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'asking to stop a take that is then stopped with ⌃⌥⌘R does not stop the '
    'take started next from the question still shown',
    (tester) async {
      final controller = await openKoe(tester, _Mic());
      expect(
        await tester.runAsync(() => fromMac('hotKey', 'record')),
        'started',
      );
      await settle(tester, () => sheet.evaluate().isNotEmpty);
      await microphone(tester, ['us.zoom.xos'], seconds(1));
      await microphone(tester, [], seconds(10));
      expect(asked(), '会议好像结束了，要停止录音吗？');

      expect(
        await tester.runAsync(() => fromMac('hotKey', 'record')),
        'stopped',
      );
      expect(
        await tester.runAsync(() => fromMac('hotKey', 'record')),
        'started',
      );
      expect(
        await tester.runAsync(() => fromMac('promptAction', 'stop')),
        isNull,
      );
      expect(controller.phoneRecordingActive, isTrue);
      expect(controller.library.assets, hasLength(1));

      expect(
        await tester.runAsync(() => fromMac('hotKey', 'record')),
        'stopped',
      );
      await settle(tester, () => sheet.evaluate().isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('不再提醒 keeps a meeting app from asking until 恢复提醒 in settings, '
      'and with the prompts off the Mac stops watching the microphone', (
    tester,
  ) async {
    final controller = (await tester.runAsync(
      () async => RecorderController(
        loadPersistedState: false,
        libraryDirectory: Directory('${directory.path}/imports'),
        phoneRecorder: _Mic(),
        phoneRecordingEnabled: true,
        placeCapture: _NoPlace(),
      ),
    ))!;
    addTearDown(controller.dispose);
    final bar = MacMenuBar(controller, onStart: () {});
    addTearDown(bar.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    await microphone(tester, ['com.electron.lark'], seconds(5));
    expect(asked(), '飞书 正在用麦克风，要开始录音吗？');
    await tester.runAsync(
      () => fromMac('promptAction', 'mute:com.electron.lark'),
    );
    await waitForSettings(tester, controller);
    expect(
      (await tester.runAsync(AppSettingsStore.load))!.meetingAppPromptsMuted,
      ['com.electron.lark'],
    );
    // The next call asks nothing.
    await microphone(tester, [], seconds(10));
    await microphone(tester, ['com.electron.lark'], seconds(5));
    expect(prompts, hasLength(1));

    final unmute = find.byKey(
      const ValueKey('settings-unmute-com.electron.lark'),
    );
    await tester.scrollUntilVisible(
      unmute,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('飞书'), findsOne);
    await tester.ensureVisible(unmute);
    await tester.pump();
    await tester.tap(unmute);
    await tester.pump();
    expect(unmute, findsNothing);
    await microphone(tester, [], seconds(10));
    await microphone(tester, ['com.electron.lark'], seconds(5));
    expect(prompts, hasLength(2));

    final toggle = find.descendant(
      of: find.byKey(const ValueKey('settings-meeting-app-prompts')),
      matching: find.byType(Switch),
    );
    await tester.scrollUntilVisible(
      toggle,
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    expect(shown()['watchMicrophone'], isFalse);
    await waitForSettings(tester, controller);
    final saved = (await tester.runAsync(AppSettingsStore.load))!;
    expect(saved.meetingAppPrompts, isFalse);
    expect(saved.meetingAppPromptsMuted, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

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

  testWidgets(
    'quitting while a stopped take is still being saved waits for the save '
    'without asking again',
    (tester) async {
      final mic = _Mic()..stopping = Completer<void>();
      final controller = await openKoe(tester, mic);
      await startFromMenu(tester, controller);

      await tester.runAsync(() => fromMac('menu', 'stop'));
      expect(shown()['state'], 'working');
      expect(shown()['lines'], ['正在保存录音']);
      expect(shown()['saving'], isTrue);
      expect(shown()['quitMessage'], isNull);

      // What the library holds when Koe answers, which lets the Mac quit.
      int? savedWhenQuit;
      await tester.runAsync(() async {
        unawaited(
          fromMac(
            'quit',
          ).then((_) => savedWhenQuit = controller.library.assets.length),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        mic.stopping!.complete();
      });
      await settle(tester, () => savedWhenQuit != null);
      expect(savedWhenQuit, 1);
      expect(shown()['saving'], isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

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

Duration seconds(int seconds) => Duration(seconds: seconds);

class _NoPlace implements PlaceCapture {
  @override
  Future<RecordingPlace?> capture() async => null;
}

/// The Mac microphone, on a disk with [space] bytes left; null when it
/// cannot tell.
class _Mic implements PhoneRecorder, PhoneDiskSpace {
  int? space;
  int spaceChecks = 0;

  /// When set, stopping waits for it, as a slow save does.
  Completer<void>? stopping;

  final _states = StreamController<PhoneMicState>.broadcast();

  /// The system ends the take, as an unplugged microphone does.
  void cutOff() => _states.add(PhoneMicState.stopped);

  @override
  Future<int?> availableSpace(String path) async {
    spaceChecks++;
    return space;
  }

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<PhoneMicState> get states => _states.stream;

  @override
  Future<void> start(String path) async {
    await File(path).writeAsBytes(wavBytes(List.filled(64000, 0x10)));
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    await stopping?.future;
  }

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
    int? expectedSpeakers,
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
