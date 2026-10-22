import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/background_sync_service.dart';

// permission_handler's wire values.
const _notification = 17;
const _denied = 0;
const _granted = 1;
const _permanentlyDenied = 4;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/background_sync');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  late List<MethodCall> calls;
  late int notificationStatus;
  late int afterRequest;
  late List<String>? Function(List<String> types) nativeStarts;

  setUp(() {
    calls = [];
    notificationStatus = _granted;
    afterRequest = _granted;
    nativeStarts = (types) => types;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permissions, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'checkPermissionStatus':
          return notificationStatus;
        case 'requestPermissions':
          return {_notification: afterRequest};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'update') {
        final types = (call.arguments as Map)['types'] as List;
        return nativeStarts(types.cast<String>());
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(permissions, null);
      messenger.setMockMethodCallHandler(channel, null);
    });
  });

  BackgroundSyncService service() =>
      BackgroundSyncService(channel: channel, enabled: true);

  Future<void> nativeTapsStop() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('stopRequested')),
        (_) {},
      );

  Future<void> nativeRefuses(List<String> types) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(MethodCall('refused', types)),
            (_) {},
          );

  List<String> methods() => [for (final call in calls) call.method];

  Map<String, Object?> lastUpdate() => Map<String, Object?>.from(
    calls.lastWhere((call) => call.method == 'update').arguments as Map,
  );

  test('first recorder sync asks for notifications before the service '
      'starts as a connected device', () async {
    notificationStatus = _denied;
    final sync = service();

    await sync.begin(BackgroundWork.recorderSync);

    expect(methods(), [
      'checkPermissionStatus',
      'requestPermissions',
      'update',
    ]);
    expect(lastUpdate(), {
      'types': ['connectedDevice'],
      'text': 'Koe 正在同步录音',
      'stoppable': false,
    });
  });

  test(
    'refused notifications are explained once and sync still runs',
    () async {
      notificationStatus = _denied;
      afterRequest = _permanentlyDenied;
      final sync = service();

      await sync.begin(BackgroundWork.recorderSync);
      await sync.end(BackgroundWork.recorderSync);
      await sync.begin(BackgroundWork.recorderSync);

      expect(
        methods().where((m) => m == 'explainNotificationsOff'),
        hasLength(1),
      );
      expect(methods().where((m) => m == 'requestPermissions'), hasLength(1));
      expect(methods().last, 'update');
    },
  );

  test('concurrent works share one service as the union of their types, '
      'showing the latest work', () async {
    final sync = service();

    await sync.begin(BackgroundWork.recorderSync);
    await sync.begin(BackgroundWork.phoneRecording);
    expect(lastUpdate(), {
      'types': ['connectedDevice', 'microphone'],
      'text': 'Koe 正在录音',
      'stoppable': true,
    });

    await sync.updateText(BackgroundWork.phoneRecording, 'Koe 正在录音 · 03:12');
    expect(lastUpdate()['text'], 'Koe 正在录音 · 03:12');

    await sync.end(BackgroundWork.phoneRecording);
    expect(lastUpdate(), {
      'types': ['connectedDevice'],
      'text': 'Koe 正在同步录音',
      'stoppable': false,
    });

    await sync.end(BackgroundWork.recorderSync);
    expect(methods().last, 'stop');
  });

  test('a start refused for a missing permission is retried on the next '
      'begin', () async {
    nativeStarts = (_) => const [];
    final sync = service();

    await sync.begin(BackgroundWork.recorderSync);
    nativeStarts = (types) => types;
    await sync.begin(BackgroundWork.recorderSync);
    await sync.begin(BackgroundWork.recorderSync);

    expect(methods().where((m) => m == 'update'), hasLength(2));
  });

  test('停止 on the notification asks microphone work to finish and leaves '
      'recorder sync running', () async {
    final sync = service();
    final stopped = <String>[];
    await sync.begin(BackgroundWork.recorderSync);
    await sync.begin(
      BackgroundWork.phoneRecording,
      onStop: () {
        stopped.add('phoneRecording');
        sync.end(BackgroundWork.phoneRecording);
      },
    );

    await nativeTapsStop();
    await pumpEventQueue();

    expect(stopped, ['phoneRecording']);
    expect(lastUpdate(), {
      'types': ['connectedDevice'],
      'text': 'Koe 正在同步录音',
      'stoppable': false,
    });
  });

  test('microphone work Android refuses after update answered is dropped and '
      'its owner told; recorder sync starts again on its own', () async {
    final sync = service();
    final refused = <String>[];
    await sync.begin(BackgroundWork.recorderSync);
    await sync.begin(
      BackgroundWork.textCapture,
      onRefused: () => refused.add('textCapture'),
    );

    // Behind the lock screen startForeground throws in the service, which
    // then stops.
    await nativeRefuses(['connectedDevice', 'microphone']);
    await pumpEventQueue();

    expect(refused, ['textCapture']);
    expect(lastUpdate(), {
      'types': ['connectedDevice'],
      'text': 'Koe 正在同步录音',
      'stoppable': false,
    });
  });

  test('microphone work the running service cannot add is dropped and its '
      'owner told', () async {
    nativeStarts = (types) => [
      for (final type in types)
        if (type != 'microphone') type,
    ];
    final sync = service();
    final refused = <String>[];
    await sync.begin(BackgroundWork.recorderSync);

    await sync.begin(
      BackgroundWork.phoneRecording,
      onRefused: () => refused.add('phoneRecording'),
    );

    expect(refused, ['phoneRecording']);
    expect(lastUpdate(), {
      'types': ['connectedDevice'],
      'text': 'Koe 正在同步录音',
      'stoppable': false,
    });
  });

  test(
    'microphone work nobody can finish is dropped when 停止 is tapped',
    () async {
      final sync = service();
      await sync.begin(BackgroundWork.textCapture);

      await nativeTapsStop();
      await pumpEventQueue();

      expect(methods().last, 'stop');
    },
  );
}
