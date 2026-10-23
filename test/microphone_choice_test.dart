import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/recorder_controller.dart';

import 'support/wav_fixture.dart';

/// The microphone Koe records from on the Mac (#402): chosen before a take,
/// kept across launches, and given up for the system default when it is not
/// connected.
void main() {
  late Directory directory;

  const builtIn = MicInput(id: 'built-in', label: 'MacBook Pro 麦克风');
  const usb = MicInput(id: 'usb', label: 'USB 会议麦克风');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-mic-choice-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

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

  RecorderController build(_Mics mics) => RecorderController(
    loadPersistedState: false,
    libraryDirectory: Directory('${directory.path}/imports'),
    phoneRecorder: mics,
    phoneRecordingEnabled: true,
    placeCapture: _NoPlace(),
  );

  Future<RecorderController> openNewRecording(
    WidgetTester tester,
    _Mics mics,
  ) async {
    final controller = (await tester.runAsync(() async => build(mics)))!;
    addTearDown(controller.dispose);
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    await tester.tap(find.byKey(const ValueKey('new-recording')));
    await tester.pumpAndSettle();
    await settle(tester, () => controller.phoneMicInputs.isNotEmpty);
    return controller;
  }

  Future<void> startTake(WidgetTester tester, RecorderController c) async {
    final option = find.byKey(const ValueKey('new-record-phone'));
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    await tester.tap(option);
    await settle(tester, () => c.phoneRecordingActive);
  }

  final picker = find.byKey(const ValueKey('phone-mic-picker'));
  final takeMic = find.byKey(const ValueKey('phone-recording-mic'));
  final notice = find.byKey(const ValueKey('phone-recording-mic-notice'));

  testWidgets(
    'the microphone chosen is the one takes record from, after a relaunch too',
    (tester) async {
      final mics = _Mics([builtIn, usb]);
      final controller = await openNewRecording(tester, mics);

      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text(usb.label).last);
      await tester.pumpAndSettle();
      final kept = File('${directory.path}/microphone.json');
      await settle(tester, kept.existsSync);

      await startTake(tester, controller);
      expect(mics.startedFrom, [usb.id]);
      expect(tester.widget<Text>(takeMic).data, usb.label);
      expect(notice, findsNothing);

      await tester.tap(find.byKey(const ValueKey('stop-phone-recording')));
      await settle(tester, () => controller.library.assets.length == 1);
      await tester.pumpAndSettle();

      // A relaunch reads the choice back before its first take.
      final relaunched = _Mics([builtIn, usb]);
      final again = (await tester.runAsync(() async {
        final again = build(relaunched);
        await again.startPhoneRecording();
        await again.discardPhoneRecording();
        return again;
      }))!;
      addTearDown(again.dispose);
      expect(relaunched.startedFrom, [usb.id]);
      expect(again.phoneMicChoice?.id, usb.id);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'a chosen microphone that is not connected gives way to the system '
    'default, and the take says so',
    (tester) async {
      await tester.runAsync(
        () => MicInput.write(File('${directory.path}/microphone.json'), usb),
      );
      final mics = _Mics([builtIn]);
      final controller = await openNewRecording(tester, mics);

      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: picker, matching: find.textContaining('没有连接')),
        findsOneWidget,
      );

      await startTake(tester, controller);
      expect(mics.startedFrom, [null]);
      expect(tester.widget<Text>(takeMic).data, '系统默认麦克风');
      expect(
        tester.widget<Text>(notice).data,
        '选的麦克风「${usb.label}」没有连接，这次用系统默认麦克风录',
      );
      // Plugged back in, it is used again.
      expect(controller.phoneMicChoice?.id, usb.id);

      await tester.tap(find.byKey(const ValueKey('stop-phone-recording')));
      await settle(tester, () => controller.library.assets.length == 1);
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

class _NoPlace implements PlaceCapture {
  @override
  Future<RecordingPlace?> capture() async => null;
}

/// Microphones as the record plugin offers them on macOS: starting from an
/// input that is not connected fails.
class _Mics implements PhoneRecorder, PhoneMicInputs {
  _Mics(this.connected);

  final List<MicInput> connected;
  MicInput? _input;

  /// The input each take started from; null is the system default.
  final startedFrom = <String?>[];

  @override
  Future<List<MicInput>> inputs() async => connected;

  @override
  void useInput(MicInput? input) => _input = input;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<PhoneMicState> get states => const Stream.empty();

  @override
  Future<void> start(String path) async {
    final input = _input;
    if (input != null && !connected.any((mic) => mic.id == input.id)) {
      throw StateError('Input device not found from available list.');
    }
    startedFrom.add(input?.id);
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
