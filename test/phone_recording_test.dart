import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/recorder_controller.dart';

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
    bytes.setUint8(44 + i, i % 251);
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

/// Writes a real WAV on stop so the save path runs on actual bytes.
class _FakePhoneRecorder implements PhoneRecorder {
  _FakePhoneRecorder({required this.permission});

  final bool permission;
  final states$ = StreamController<PhoneMicState>.broadcast();
  String? path;
  int starts = 0;
  int pauses = 0;

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
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
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
