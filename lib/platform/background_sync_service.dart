import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Android foreground-service types Koe's one service can run as. Each needs
/// its runtime permission granted before it starts: Bluetooth connect for
/// [connectedDevice], microphone for [microphone].
enum ForegroundServiceType { connectedDevice, microphone }

/// One piece of work that must keep running after Koe leaves the screen.
///
/// Works share a single Android foreground service and notification: the
/// service runs as the union of the active works' types and shows the text
/// of the work begun last. New kinds of work (phone recording, all-day
/// listening) add a `static const` here.
@immutable
class BackgroundWork {
  const BackgroundWork(this.id, {required this.type, required this.text});

  /// Pulling recordings from the recorder over Bluetooth.
  static const recorderSync = BackgroundWork(
    'recorderSync',
    type: ForegroundServiceType.connectedDevice,
    text: 'Koe 正在同步录音',
  );

  final String id;
  final ForegroundServiceType type;

  /// Notification text while this is the latest work.
  final String text;

  @override
  bool operator ==(Object other) => other is BackgroundWork && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Keeps the Android process eligible to finish active work after the UI
/// moves to the background, through `RecordingSyncService`. Apple platforms
/// use Core Bluetooth's background mode and state restoration instead.
///
/// Start work while Koe is on screen: Android refuses to start most
/// foreground services from the background.
class BackgroundSyncService {
  BackgroundSyncService({
    this._channel = const MethodChannel(_channelName),
    bool? enabled,
  }) : _enabled = enabled ?? (!kIsWeb && Platform.isAndroid);

  static const _channelName = 'com.anker.anker_recorder/background_sync';

  /// The app-wide service.
  static final shared = BackgroundSyncService();

  final MethodChannel _channel;
  final bool _enabled;

  // Insertion order: the last entry's text is on the notification.
  final _works = <String, BackgroundWork>{};
  final _texts = <String, String>{};
  bool _askedForNotifications = false;
  _Request? _applied;

  /// Starts [work], or brings its notification text back to the front. Safe
  /// to call again for running work, for example to retry once a permission
  /// the service type needs has been granted.
  Future<void> begin(BackgroundWork work, {String? text}) async {
    if (!_enabled) return;
    _works.remove(work.id);
    _works[work.id] = work;
    _texts[work.id] = text ?? work.text;
    await _ensureNotificationPermission();
    await _apply();
  }

  /// Changes the notification text of running [work].
  Future<void> updateText(BackgroundWork work, String text) async {
    if (!_enabled || !_works.containsKey(work.id)) return;
    _texts[work.id] = text;
    await _apply();
  }

  /// Ends [work]; the service stops once no work is left.
  Future<void> end(BackgroundWork work) async {
    if (!_enabled || _works.remove(work.id) == null) return;
    _texts.remove(work.id);
    await _apply();
  }

  /// Before the first background work, ask for notifications so the
  /// ongoing notification can show and lead back to Koe. A refusal gets one
  /// explanation per launch with a way to the system settings; the work runs
  /// either way, only without a visible notification.
  Future<void> _ensureNotificationPermission() async {
    if (_askedForNotifications) return;
    _askedForNotifications = true;
    try {
      var status = await Permission.notification.status;
      if (status.isGranted) return;
      if (!status.isPermanentlyDenied) {
        status = await Permission.notification.request();
        if (status.isGranted) return;
      }
      await _channel.invokeMethod<void>('explainNotificationsOff');
    } on PlatformException catch (error) {
      debugPrint('[BackgroundSync] Notification permission: $error');
    } on MissingPluginException catch (error) {
      debugPrint('[BackgroundSync] Notification permission: $error');
    }
  }

  Future<void> _apply() async {
    final request = _works.isEmpty
        ? null
        : _Request(
            types: {for (final work in _works.values) work.type.name},
            text: _texts[_works.keys.last]!,
          );
    if (request == _applied) return;
    try {
      if (request == null) {
        await _channel.invokeMethod<void>('stop');
        _applied = null;
        return;
      }
      // The service answers with the types it could start; a type whose
      // permission is still missing is left out and retried on next begin.
      final started = await _channel.invokeListMethod<String>('update', {
        'types': request.types.toList(),
        'text': request.text,
      });
      _applied = started != null && started.toSet().containsAll(request.types)
          ? request
          : null;
    } on PlatformException catch (error) {
      debugPrint('[BackgroundSync] Could not update: $error');
    } on MissingPluginException catch (error) {
      debugPrint('[BackgroundSync] Native bridge unavailable: $error');
    }
  }
}

@immutable
class _Request {
  const _Request({required this.types, required this.text});

  final Set<String> types;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is _Request &&
      other.text == text &&
      setEquals(other.types, types);

  @override
  int get hashCode => Object.hash(text, Object.hashAllUnordered(types));
}
