import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 全天常驻 on Android. Koe associates the recorder through the companion
/// device manager, which lets Koe start its foreground service from the
/// background, and watches for it with a Bluetooth scan Android runs for
/// Koe: Android starts Koe when the scan sees the recorder, even after the
/// user swiped Koe away, and says when it sees it or loses it.
///
/// The recorder's Bluetooth address changes, at least with every Wi‑Fi
/// export. The scan matches its classic address instead, which its
/// advertisement carries and which stays.
///
/// Apple platforms bring the recorder back through Core Bluetooth state
/// restoration instead; there, and wherever Android lacks the feature, every
/// call does nothing.
class RecorderPresence {
  RecorderPresence({
    this._channel = const MethodChannel(_channelName),
    bool? enabled,
  }) : _enabled = enabled ?? (!kIsWeb && Platform.isAndroid) {
    if (_enabled) _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channelName = 'com.semanticcraft.koe/recorder_presence';

  /// The app-wide instance. Tests replace it with one on a mock channel.
  static RecorderPresence shared = RecorderPresence();

  final MethodChannel _channel;
  final bool _enabled;

  bool get enabled => _enabled;

  /// Told when the scan sees the recorder, at which Bluetooth address, or
  /// loses it.
  void Function(bool near, String? address)? onPresence;

  /// Whether this phone can associate devices; whether Koe is associated
  /// with a recorder; the classic address Koe watches for (null when it
  /// watches none yet); and whether the scan sees the recorder now, at which
  /// Bluetooth address.
  Future<
    ({
      bool supported,
      bool associated,
      String? mac,
      bool present,
      String? address,
    })
  >
  state() async {
    const none = (
      supported: false,
      associated: false,
      mac: null,
      present: false,
      address: null,
    );
    if (!_enabled) return none;
    final state = await _call(
      () => _channel.invokeMapMethod<String, Object?>('state'),
    );
    if (state == null) return none;
    return (
      supported: state['supported'] == true,
      associated: state['associated'] == true,
      mac: state['mac'] as String?,
      present: state['present'] == true,
      address: state['address'] as String?,
    );
  }

  /// Associates the recorder at the Bluetooth [address]. Android asks the
  /// user in its own dialog, which needs Koe on screen; returns whether they
  /// allowed it.
  Future<bool> associate(String address) async {
    if (!_enabled) return false;
    return await _call(
          () => _channel.invokeMethod<bool>('associate', {'address': address}),
        ) ??
        false;
  }

  /// Starts or stops watching for the recorder with the classic address
  /// [mac].
  Future<void> observe(bool on, String? mac) async {
    if (!_enabled) return;
    await _call(
      () => _channel.invokeMethod<void>('observe', {'on': on, 'mac': mac}),
    );
  }

  /// Stops watching and drops the association.
  Future<void> disassociate() async {
    if (!_enabled) return;
    await _call(() => _channel.invokeMethod<void>('disassociate'));
  }

  Future<T?> _call<T>(Future<T?> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (error) {
      debugPrint('[RecorderPresence] $error');
    } on MissingPluginException catch (error) {
      debugPrint('[RecorderPresence] $error');
    }
    return null;
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'presence':
        final event = (call.arguments as Map).cast<String, Object?>();
        onPresence?.call(event['near'] == true, event['address'] as String?);
      default:
        throw MissingPluginException(call.method);
    }
    return null;
  }
}
