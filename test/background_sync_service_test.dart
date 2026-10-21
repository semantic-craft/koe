import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/background_sync_service.dart';

// permission_handler's wire values.
const _notification = 17;
const _denied = 0;
const _granted = 1;
const _permanentlyDenied = 4;

const _phoneRecording = BackgroundWork(
  'phoneRecording',
  type: ForegroundServiceType.microphone,
  text: 'Koe 正在录音',
);

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
    });
  });

  test('refused notifications are explained once and sync still runs', () async {
    notificationStatus = _denied;
    afterRequest = _permanentlyDenied;
    final sync = service();

    await sync.begin(BackgroundWork.recorderSync);
    await sync.end(BackgroundWork.recorderSync);
    await sync.begin(BackgroundWork.recorderSync);

    expect(methods().where((m) => m == 'explainNotificationsOff'), hasLength(1));
    expect(methods().where((m) => m == 'requestPermissions'), hasLength(1));
    expect(methods().last, 'update');
  });

  test('concurrent works share one service as the union of their types, '
      'showing the latest work', () async {
    final sync = service();

    await sync.begin(BackgroundWork.recorderSync);
    await sync.begin(_phoneRecording);
    expect(lastUpdate(), {
      'types': ['connectedDevice', 'microphone'],
      'text': 'Koe 正在录音',
    });

    await sync.updateText(_phoneRecording, 'Koe 正在录音 · 03:12');
    expect(lastUpdate()['text'], 'Koe 正在录音 · 03:12');

    await sync.end(_phoneRecording);
    expect(lastUpdate(), {
      'types': ['connectedDevice'],
      'text': 'Koe 正在同步录音',
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
}
