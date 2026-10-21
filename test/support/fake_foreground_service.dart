import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/background_sync_service.dart';

/// Stands in for Koe's Android foreground service: replaces
/// [BackgroundSyncService.shared] with one on a mock channel, records what
/// the notification would show, and taps its 停止 the way the native side
/// does. Restores the real service when the test ends.
class FakeForegroundService {
  FakeForegroundService() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_permissions, (call) async {
      if (call.method == 'checkPermissionStatus') return 1; // granted
      return null;
    });
    messenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'update':
          final args = (call.arguments as Map).cast<String, Object?>();
          types = (args['types'] as List).cast<String>().toSet();
          text = args['text'] as String?;
          stoppable = args['stoppable'] == true;
          return types.toList();
        case 'stop':
          types = {};
          text = null;
          stoppable = false;
          stops++;
          return null;
      }
      return null;
    });
    final previous = BackgroundSyncService.shared;
    BackgroundSyncService.shared = BackgroundSyncService(
      channel: _channel,
      enabled: true,
    );
    addTearDown(() {
      BackgroundSyncService.shared = previous;
      messenger.setMockMethodCallHandler(_permissions, null);
      messenger.setMockMethodCallHandler(_channel, null);
    });
  }

  static const _channel = MethodChannel('test/foreground_service');
  static const _permissions = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );

  /// Foreground types the service runs as; empty when stopped.
  Set<String> types = {};

  /// The notification's line; null when stopped.
  String? text;

  /// Whether the notification offers 停止.
  bool stoppable = false;
  int stops = 0;

  bool get running => types.isNotEmpty;

  /// Taps 停止 on the notification.
  Future<void> pressStop() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(const MethodCall('stopRequested')),
      (_) {},
    );
  }
}
