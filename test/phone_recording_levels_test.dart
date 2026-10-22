import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/recorder_controller.dart';

import 'support/wav_fixture.dart';

/// The microphone while a take records (#401): its level on a meter, hints
/// when it hears nothing, and a take the system ends saved like 结束并保存.
void main() {
  late Directory directory;
  late _Mic mic;
  late RecorderController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-mic-levels-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

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

  Future<void> startRecording(WidgetTester tester) async {
    controller = (await tester.runAsync(() async {
      mic = _Mic();
      return RecorderController(
        loadPersistedState: false,
        libraryDirectory: Directory('${directory.path}/imports'),
        phoneRecorder: mic,
        phoneRecordingEnabled: true,
        placeCapture: _NoPlace(),
      );
    }))!;
    addTearDown(controller.dispose);
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    await tester.tap(find.byKey(const ValueKey('new-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-record-phone')));
    await settle(tester, () => controller.phoneRecordingActive);
  }

  testWidgets('a take the system ends is saved, and the panel says why', (
    tester,
  ) async {
    await startRecording(tester);

    mic.cutOff();
    await settle(
      tester,
      () => find.textContaining('录音被系统停下了').evaluate().isNotEmpty,
    );

    expect(find.textContaining('已录的部分已保存'), findsOneWidget);
    expect(controller.phoneRecordingActive, isFalse);
    expect(controller.library.assets.single.path, mic.path);
    expect(controller.exportedPaths, contains(mic.path));
  });

  testWidgets('the meter follows the microphone, and one that hears nothing '
      'is pointed out until dismissed', (tester) async {
    await startRecording(tester);
    double meter() => tester
        .widget<FractionallySizedBox>(
          find.byKey(const ValueKey('phone-recording-level')),
        )
        .widthFactor!;
    final hint = find.textContaining('麦克风没有收到声音');

    mic.levels$.add(-30);
    await tester.pump();
    expect(meter(), 0.5);

    // Eleven seconds of zeros, as from a muted input.
    for (var i = 0; i < 110; i++) {
      mic.levels$.add(-160);
    }
    await tester.pump();
    expect(meter(), 0);
    expect(hint, findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('dismiss-phone-recording-level-hint')),
    );
    await tester.pump();
    for (var i = 0; i < 300; i++) {
      mic.levels$.add(-160);
    }
    await tester.pump();
    expect(hint, findsNothing);
  });
}

class _NoPlace implements PlaceCapture {
  @override
  Future<RecordingPlace?> capture() async => null;
}

/// A microphone the test drives: it records real audio from the start and
/// reports levels and state changes when told.
class _Mic implements PhoneRecorder, PhoneMicLevels {
  final states$ = StreamController<PhoneMicState>.broadcast();
  final levels$ = StreamController<double>.broadcast();
  String? path;

  /// The system ends the take, as when the microphone is unplugged.
  void cutOff() => states$.add(PhoneMicState.stopped);

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<PhoneMicState> get states => states$.stream;

  @override
  Stream<double> levels(Duration interval) => levels$.stream;

  @override
  Future<void> start(String path) async {
    this.path = path;
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
