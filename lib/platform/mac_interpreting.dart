import 'package:flutter/services.dart';

/// Text-only protocol; audio and input ownership remain on the Mac.
class MacInterpreting {
  MacInterpreting({MethodChannel? channel, EventChannel? eventChannel})
    : _channel =
          channel ?? const MethodChannel('com.semanticcraft.koe/interpreting'),
      _events =
          eventChannel ??
          const EventChannel('com.semanticcraft.koe/interpreting/events');
  final MethodChannel _channel;
  final EventChannel _events;
  Stream<Map<String, dynamic>> get events => _events
      .receiveBroadcastStream()
      .map((value) => Map<String, dynamic>.from(value as Map));
  Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]) =>
      _channel.invokeMethod<dynamic>(method, args);
}
