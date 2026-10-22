import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:quick_actions/quick_actions.dart';

/// Hands 开始录音 to the controller: the iOS App Intent (Action Button,
/// Shortcuts), or on Android the launcher shortcut shown when the Koe icon is
/// long-pressed.
///
/// On iOS the native side keeps the action persisted until this service
/// consumes it, so an intent delivered during a cold launch cannot be lost
/// between native app startup and Dart method-channel registration. On
/// Android quick_actions holds a cold launch's shortcut until [initialize]
/// asks for it.
class RecordingShortcutService {
  RecordingShortcutService({MethodChannel? channel, QuickActions? quickActions})
    : _channel =
          channel ??
          const MethodChannel('com.capyvibe.soundcore/recording_shortcut'),
      _quickActions = quickActions ?? const QuickActions();

  static final instance = RecordingShortcutService();

  /// The Android launcher shortcut, shown as 开始录音.
  static const startRecordingShortcut = ShortcutItem(
    type: 'start_recording',
    localizedTitle: '开始录音',
    icon: 'ic_shortcut_record',
  );

  final MethodChannel _channel;
  final QuickActions _quickActions;
  Future<void> Function()? _onStartRecording;
  bool _consuming = false;
  bool _consumeAgain = false;
  bool _shortcutsReady = false;
  bool _launchShortcutSeen = false;

  Future<void> initialize({
    required Future<void> Function() onStartRecording,
  }) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      _onStartRecording = onStartRecording;
      await _initializeShortcuts();
      return;
    }
    if (!Platform.isIOS) return;
    _onStartRecording = onStartRecording;
    _channel.setMethodCallHandler(_handleNativeCall);
    await _consumePendingAction();
  }

  Future<void> _initializeShortcuts() async {
    try {
      await _quickActions.initialize(_handleShortcut);
      _shortcutsReady = true;
      await _quickActions.setShortcutItems(const [startRecordingShortcut]);
    } on MissingPluginException catch (error) {
      debugPrint('[RecordingShortcut] Launcher shortcuts unavailable: $error');
    } on PlatformException catch (error) {
      debugPrint('[RecordingShortcut] Could not set launcher shortcut: $error');
    }
  }

  void _handleShortcut(String type) {
    if (type != startRecordingShortcut.type) return;
    if (!_shortcutsReady) {
      // A cold launch reports its shortcut twice: from the launching intent,
      // then again when initialize asks for it.
      if (_launchShortcutSeen) return;
      _launchShortcutSeen = true;
    }
    unawaited(_onStartRecording?.call());
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method == 'pendingStartRecording') {
      await _consumePendingAction();
    }
    return null;
  }

  Future<void> _consumePendingAction() async {
    if (_consuming) {
      _consumeAgain = true;
      return;
    }
    _consuming = true;
    try {
      do {
        _consumeAgain = false;
        try {
          final pending =
              await _channel.invokeMethod<bool>(
                'consumePendingStartRecording',
              ) ??
              false;
          if (pending) await _onStartRecording?.call();
        } on MissingPluginException catch (error) {
          debugPrint('[RecordingShortcut] Native bridge unavailable: $error');
          return;
        } on PlatformException catch (error) {
          debugPrint('[RecordingShortcut] Could not consume action: $error');
          return;
        }
      } while (_consumeAgain);
    } finally {
      _consuming = false;
    }
  }
}
