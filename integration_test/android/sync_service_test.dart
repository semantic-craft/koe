// Android scenario: recorder sync keeps Koe's foreground service, its
// notification and the Dart side running after Koe leaves the screen; only
// moving recordings keeps the phone awake, an idle link to the recorder does
// not (#438). Needs no recorder; pulling recordings over BLE is the #345
// device pass. Run with `scripts/android-check`, which grants notifications
// and Bluetooth first.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/platform/background_sync_service.dart';

import 'background_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recorder sync keeps running in the background with a '
      'notification that opens Koe; the phone is kept awake only while '
      'recordings move', (tester) async {
    if (await skipIfLocked('sync_service_test.dart')) return;
    final sync = BackgroundSyncService();
    addTearDown(() async {
      await sync.end(BackgroundWork.recorderSync);
      await sync.end(BackgroundWork.recorderLink);
    });

    await sync.begin(BackgroundWork.recorderLink);
    final linked = await serviceStatusWhen(
      (s) => s['running'] == true && s['notificationPosted'] == true,
    );
    expect(linked['types'], ['connectedDevice']);
    expect(linked['text'], 'Koe 已连接录音豆');
    expect(linked['opensKoe'], isTrue);
    expect(linked['wakeLockHeld'], isFalse);

    await sync.begin(BackgroundWork.recorderSync);
    final syncing = await serviceStatusWhen(
      (s) => s['wakeLockHeld'] == true && s['text'] == 'Koe 正在同步录音',
    );
    expect(syncing['text'], 'Koe 正在同步录音');
    expect(syncing['wakeLockHeld'], isTrue);

    // Leave the screen as the Home gesture does. No frames are drawn from
    // here on, so wait on real time rather than pumping.
    expect(await native.invokeMethod<bool>('moveTaskToBack'), isTrue);
    var ticks = 0;
    final timer = Timer.periodic(const Duration(seconds: 1), (_) => ticks++);
    await Future<void>.delayed(const Duration(seconds: 30));
    timer.cancel();

    expect(ticks, greaterThanOrEqualTo(25), reason: 'Dart kept running');
    final behind = await serviceStatus();
    expect(behind['running'], isTrue);
    expect(behind['notificationPosted'], isTrue);
    expect(behind['wakeLockHeld'], isTrue);

    await sync.end(BackgroundWork.recorderSync);
    final idle = await serviceStatusWhen(
      (s) => s['wakeLockHeld'] == false && s['text'] == 'Koe 已连接录音豆',
    );
    expect(idle['running'], isTrue);
    expect(idle['notificationPosted'], isTrue);
    expect(idle['text'], 'Koe 已连接录音豆');
    expect(idle['wakeLockHeld'], isFalse);

    await sync.end(BackgroundWork.recorderLink);
    final stopped = await serviceStatusWhen(
      (s) => s['running'] == false && s['notificationPosted'] == false,
    );
    expect(stopped['running'], isFalse);
    expect(stopped['notificationPosted'], isFalse);
  });
}
