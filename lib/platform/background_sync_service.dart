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

  /// A phone microphone take that keeps the audio as an original.
  static const phoneRecording = BackgroundWork(
    'phoneRecording',
    type: ForegroundServiceType.microphone,
    text: 'Koe 正在录音',
  );

  /// Text-only capture and all-day listening from the phone microphone.
  static const textCapture = BackgroundWork(
    'textCapture',
    type: ForegroundServiceType.microphone,
    text: 'Koe 正在监听（只留文字）',
  );

  final String id;
  final ForegroundServiceType type;

  /// Microphone work can be stopped from its notification; recorder sync
  /// ends on its own.
  bool get stoppable => type == ForegroundServiceType.microphone;

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
  }) : _enabled = enabled ?? (!kIsWeb && Platform.isAndroid) {
    if (_enabled) _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channelName = 'com.anker.anker_recorder/background_sync';

  /// The app-wide service. Tests replace it with one on a mock channel.
  static BackgroundSyncService shared = BackgroundSyncService();

  final MethodChannel _channel;
  final bool _enabled;

  // Insertion order: the last entry's text is on the notification.
  final _works = <String, BackgroundWork>{};
  final _texts = <String, String>{};
  final _onStops = <String, VoidCallback>{};
  final _onRefused = <String, VoidCallback>{};
  bool _askedForNotifications = false;
  _Request? _applied;

  /// Starts [work], or brings its notification text back to the front. Safe
  /// to call again for running work, for example to retry once a permission
  /// the service type needs has been granted.
  ///
  /// [onStop] runs when the user taps 停止 on the notification of
  /// [BackgroundWork.stoppable] work. It should finish the work and [end] it;
  /// nothing restarts the work afterwards.
  ///
  /// [onRefused] runs when Android will not run the service as the work's
  /// type, as it refuses microphone work begun while Koe is off screen
  /// (behind the lock screen, say). The work is already ended by then; its
  /// owner should stop it and may begin it again once Koe is on screen.
  /// Work without [onRefused] stays and is retried on the next begin.
  Future<void> begin(
    BackgroundWork work, {
    String? text,
    VoidCallback? onStop,
    VoidCallback? onRefused,
  }) async {
    if (!_enabled) return;
    _works.remove(work.id);
    _works[work.id] = work;
    _texts[work.id] = text ?? work.text;
    if (onStop != null) _onStops[work.id] = onStop;
    if (onRefused != null) _onRefused[work.id] = onRefused;
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
    _onStops.remove(work.id);
    _onRefused.remove(work.id);
    await _apply();
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'stopRequested':
        await _stopRequested();
      case 'refused':
        // The service has stopped: Android refused the types it was
        // starting as after `update` had answered.
        _applied = null;
        await _refuse({...(call.arguments as List).cast<String>()});
      default:
        throw MissingPluginException(call.method);
    }
    return null;
  }

  /// The notification's 停止 was tapped: stops every stoppable work.
  Future<void> _stopRequested() async {
    final handlers = <VoidCallback>[];
    var dropped = false;
    for (final work in [..._works.values]) {
      if (!work.stoppable) continue;
      final handler = _onStops[work.id];
      if (handler != null) {
        handlers.add(handler);
      } else {
        // Nothing here can finish this work; drop it rather than leave a
        // notification whose button does nothing.
        _works.remove(work.id);
        _texts.remove(work.id);
        dropped = true;
      }
    }
    if (dropped) await _apply();
    for (final handler in handlers) {
      handler();
    }
  }

  /// Ends the works of the refused [types] that have an `onRefused`, runs
  /// the service as what is left and tells their owners. Nothing changes
  /// when none has one, so a refusal never starts a retry loop.
  Future<void> _refuse(Set<String> types) async {
    final handlers = <VoidCallback>[];
    for (final work in [..._works.values]) {
      final handler = _onRefused[work.id];
      if (handler == null || !types.contains(work.type.name)) continue;
      _works.remove(work.id);
      _texts.remove(work.id);
      _onStops.remove(work.id);
      _onRefused.remove(work.id);
      handlers.add(handler);
    }
    if (handlers.isEmpty) return;
    await _apply();
    for (final handler in handlers) {
      handler();
    }
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
            stoppable: _works.values.any((work) => work.stoppable),
          );
    if (request == _applied) return;
    try {
      if (request == null) {
        await _channel.invokeMethod<void>('stop');
        _applied = null;
        return;
      }
      // The service answers with the types it could start. One left out,
      // for a missing permission or refused by Android, ends the works that
      // can be told; the others are retried on the next begin.
      final started = await _channel.invokeListMethod<String>('update', {
        'types': request.types.toList(),
        'text': request.text,
        'stoppable': request.stoppable,
      });
      final missing = request.types.difference({...?started});
      _applied = missing.isEmpty ? request : null;
      if (missing.isNotEmpty) await _refuse(missing);
    } on PlatformException catch (error) {
      debugPrint('[BackgroundSync] Could not update: $error');
    } on MissingPluginException catch (error) {
      debugPrint('[BackgroundSync] Native bridge unavailable: $error');
    }
  }
}

@immutable
class _Request {
  const _Request({
    required this.types,
    required this.text,
    required this.stoppable,
  });

  final Set<String> types;
  final String text;
  final bool stoppable;

  @override
  bool operator ==(Object other) =>
      other is _Request &&
      other.text == text &&
      other.stoppable == stoppable &&
      setEquals(other.types, types);

  @override
  int get hashCode =>
      Object.hash(text, stoppable, Object.hashAllUnordered(types));
}
