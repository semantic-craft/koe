import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 全天常驻 on Android, through the companion device manager: with the
/// recorder associated, Koe may start its foreground service from the
/// background, and while Koe observes the recorder, Android starts Koe when
/// it comes near and says when it is near or gone. Apple platforms bring the
/// recorder back through Core Bluetooth state restoration instead; there,
/// and wherever Android lacks the feature, every call does nothing.
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

  /// Told whether the observed recorder is near, each time that changes.
  ValueChanged<bool>? onPresence;

  /// Whether this phone can associate devices, the address of the recorder
  /// Koe is associated with (null when none), and whether it is near now.
  Future<({bool supported, String? address, bool present})> state() async {
    const none = (supported: false, address: null, present: false);
    if (!_enabled) return none;
    final state = await _call(
      () => _channel.invokeMapMethod<String, Object?>('state'),
    );
    if (state == null) return none;
    return (
      supported: state['supported'] == true,
      address: state['address'] as String?,
      present: state['present'] == true,
    );
  }

  /// Associates the recorder at [address]. Android asks the user in its own
  /// dialog, which needs Koe on screen; returns whether they allowed it.
  Future<bool> associate(String address) async {
    if (!_enabled) return false;
    return await _call(
          () => _channel.invokeMethod<bool>('associate', {'address': address}),
        ) ??
        false;
  }

  /// Starts or stops observing the associated recorder.
  Future<void> observe(bool on) async {
    if (!_enabled) return;
    await _call(() => _channel.invokeMethod<void>('observe', {'on': on}));
  }

  /// Stops observing and drops the association.
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
        onPresence?.call(call.arguments == true);
      default:
        throw MissingPluginException(call.method);
    }
    return null;
  }
}
