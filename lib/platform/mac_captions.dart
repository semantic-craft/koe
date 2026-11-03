import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One latest snapshot may wait behind the current native update.
class MacCaptions {
  MacCaptions({MethodChannel? channel, bool? enabled})
    : _channel =
          channel ?? const MethodChannel('com.semanticcraft.koe/captions'),
      enabled =
          enabled ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS);
  final MethodChannel _channel;
  final bool enabled;
  Map<String, Object?>? _latest;
  Future<void>? _sending;
  int _revision = 0;
  Future<void> show({
    required String mode,
    String original = '',
    String translation = '',
    String minutes = '',
  }) {
    if (!enabled) return Future.value();
    _latest = {
      'mode': mode,
      'original': original,
      'translation': translation,
      'minutes': minutes,
      'revision': ++_revision,
    };
    return _sending ??= _drain().whenComplete(() => _sending = null);
  }

  Future<void> _drain() async {
    while (_latest != null) {
      final next = _latest;
      _latest = null;
      await _channel.invokeMethod<void>('show', next);
    }
  }

  Future<void> hide() => show(mode: 'hidden');
}
