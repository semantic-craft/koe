import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_kind.dart';

/// What Koe's Mac menu bar item shows: idle, a take running or paused, or
/// work (transcription, analysis, pulling recordings) under way.
enum MacAppState { idle, recording, paused, working }

/// One command in the menu bar item's menu.
@immutable
class MacMenuAction {
  const MacMenuAction(this.id, this.title);

  /// `start`, `pause`, `resume` or `stop`, as [MacApp.onAction] receives
  /// it. `stop` ends the take, or text capture when no take runs.
  final String id;
  final String title;

  @override
  bool operator ==(Object other) =>
      other is MacMenuAction && other.id == id && other.title == title;

  @override
  int get hashCode => Object.hash(id, title);
}

/// Everything the Mac shows for Koe at one moment: the menu bar item and
/// its menu, whether the Mac stays awake, and what to ask before quitting.
@immutable
class MacAppStatus {
  const MacAppStatus({
    this.state = MacAppState.idle,
    this.take,
    this.elapsed = Duration.zero,
    this.running = false,
    this.lines = const [],
    this.actions = const [],
    this.keepAwake,
    this.quitMessage,
    this.quitInfo = '',
  });

  final MacAppState state;

  /// The running take's line in the menu, such as 录音中, shown with
  /// [elapsed]; null without a take.
  final String? take;

  /// Time recorded so far. The Mac side advances it while [running], so it
  /// is left out of `==` and a change of it alone is not sent.
  final Duration elapsed;
  final bool running;

  /// Lines under the take, such as the transcription under way.
  final List<String> lines;
  final List<MacMenuAction> actions;

  /// Why the Mac must not idle-sleep, in English: `pmset -g assertions`
  /// leaves out other names. Null lets it sleep.
  final String? keepAwake;

  /// The question before quitting; null quits without asking.
  final String? quitMessage;
  final String quitInfo;

  Map<String, Object?> toMap() => {
    'state': state.name,
    'take': take,
    'elapsedMs': elapsed.inMilliseconds,
    'running': running,
    'lines': lines,
    'actions': [
      for (final action in actions) {'id': action.id, 'title': action.title},
    ],
    'keepAwake': keepAwake,
    'quitMessage': quitMessage,
    'quitInfo': quitInfo,
  };

  @override
  bool operator ==(Object other) =>
      other is MacAppStatus &&
      other.state == state &&
      other.take == take &&
      other.running == running &&
      listEquals(other.lines, lines) &&
      listEquals(other.actions, actions) &&
      other.keepAwake == keepAwake &&
      other.quitMessage == quitMessage &&
      other.quitInfo == quitInfo;

  @override
  int get hashCode => Object.hash(
    state,
    take,
    running,
    Object.hashAll(lines),
    Object.hashAll(actions),
    keepAwake,
    quitMessage,
    quitInfo,
  );
}

/// Koe's app-level Mac controls, run by `macos/Runner/AppDelegate.swift`:
/// the menu bar item, keeping the Mac awake, asking before quitting and the
/// space left for takes. Elsewhere every call does nothing.
class MacApp {
  MacApp({this._channel = const MethodChannel(_channelName), bool? enabled})
    : _enabled = enabled ?? runsOnMac {
    if (_enabled) _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channelName = 'com.semanticcraft.koe/mac_app';

  /// The app-wide controls. Tests replace them with ones on a mock channel.
  static MacApp shared = MacApp();

  final MethodChannel _channel;
  final bool _enabled;

  bool get enabled => _enabled;

  /// Runs a menu command; see [MacMenuAction.id].
  void Function(String action)? onAction;

  /// Keeps what must not be lost (the take, the text so far) once the user
  /// confirmed quitting. Koe quits when it returns, or after ten seconds.
  Future<void> Function()? onQuit;

  MacAppStatus _status = const MacAppStatus();
  MacAppStatus? _sent;

  /// Shows [status], sending it only when it changed.
  Future<void> show(MacAppStatus status) async {
    if (!_enabled) return;
    _status = status;
    if (status == _sent) return;
    await _send();
  }

  Future<void> _send() async {
    final status = _status;
    try {
      await _channel.invokeMethod<void>('update', status.toMap());
      _sent = status;
    } on MissingPluginException {
      // Not listening yet; it says `ready` once it is.
    } on PlatformException catch (error) {
      debugPrint('[MacApp] Could not update: $error');
    }
  }

  /// Bytes free for new takes on the volume holding [path]; null when Koe
  /// cannot tell.
  Future<int?> availableSpace(String path) async {
    if (!_enabled) return null;
    try {
      return await _channel.invokeMethod<int>('availableSpace', {'path': path});
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('[MacApp] Could not read free space: $error');
      return null;
    }
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'ready':
        _sent = null;
        await _send();
      case 'menu':
        onAction?.call(call.arguments as String);
      case 'quit':
        await onQuit?.call();
      default:
        throw MissingPluginException(call.method);
    }
    return null;
  }
}
