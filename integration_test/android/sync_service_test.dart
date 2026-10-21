// Android scenario: recorder sync keeps Koe's foreground service, its
// notification and the Dart side running after Koe leaves the screen. Needs
// no recorder; pulling recordings over BLE is the #345 device pass. Run with
// `scripts/android-check`, which grants notifications and Bluetooth first.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/platform/background_sync_service.dart';

const _native = MethodChannel('com.anker.anker_recorder/background_sync');

Future<Map<String, Object?>> _status() async =>
    Map<String, Object?>.from((await _native.invokeMapMethod('status'))!);

Future<Map<String, Object?>> _statusWhen(
  bool Function(Map<String, Object?>) ready,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  var status = await _status();
  while (!ready(status) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    status = await _status();
  }
  return status;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recorder sync keeps running in the background with a '
      'notification that opens Koe', (tester) async {
    final sync = BackgroundSyncService();
    addTearDown(() => sync.end(BackgroundWork.recorderSync));

    await sync.begin(BackgroundWork.recorderSync);
    final started = await _statusWhen(
      (s) => s['running'] == true && s['notificationPosted'] == true,
    );
    expect(started['types'], ['connectedDevice']);
    expect(started['text'], 'Koe 正在同步录音');
    expect(started['opensKoe'], isTrue);
    expect(started['wakeLockHeld'], isTrue);

    // Leave the screen as the Home gesture does. No frames are drawn from
    // here on, so wait on real time rather than pumping.
    expect(await _native.invokeMethod<bool>('moveTaskToBack'), isTrue);
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => ticks++,
    );
    await Future<void>.delayed(const Duration(seconds: 30));
    timer.cancel();

    expect(ticks, greaterThanOrEqualTo(25), reason: 'Dart kept running');
    final behind = await _status();
    expect(behind['running'], isTrue);
    expect(behind['notificationPosted'], isTrue);
    expect(behind['wakeLockHeld'], isTrue);

    await sync.end(BackgroundWork.recorderSync);
    final stopped = await _statusWhen(
      (s) => s['running'] == false && s['notificationPosted'] == false,
    );
    expect(stopped['running'], isFalse);
    expect(stopped['notificationPosted'], isFalse);
  });
}
