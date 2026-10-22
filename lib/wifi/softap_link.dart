import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How Koe reaches the recorder's Wi‑Fi hotspot for an export
/// (PROTOCOL.md §6.4–6.5): joining it, opening the WebSocket's TCP
/// connection on it, and sending the UDP keepalive there.
abstract class SoftApLink {
  factory SoftApLink.forPlatform() =>
      Platform.isAndroid ? AndroidSoftApLink() : SystemWifiSoftApLink();

  /// Whether Koe joins the hotspot itself; otherwise the user joins it in
  /// the system's Wi‑Fi settings before the transfer starts.
  bool get joinsItself;

  /// Joins the hotspot. Throws [SoftApJoinException] with the reason shown
  /// to the user when that fails.
  Future<void> join({required String ssid, required String password});

  /// Opens TCP connections on the hotspot; null when ordinary connections
  /// get there.
  SoftApDial? get dial;

  /// Starts the recorder's UDP keepalive (port 32003, every 2 s).
  Future<void> startKeepalive(String host);

  /// Stops the keepalive and leaves the hotspot.
  Future<void> release();
}

typedef SoftApDial = Future<Socket> Function(String host, int port);

class SoftApJoinException implements Exception {
  const SoftApJoinException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// iOS and macOS: the user joins the hotspot in system settings and it
/// becomes the Wi‑Fi network, so ordinary sockets reach the recorder.
class SystemWifiSoftApLink implements SoftApLink {
  RawDatagramSocket? _udp;
  Timer? _udpTimer;

  @override
  bool get joinsItself => false;

  @override
  Future<void> join({required String ssid, required String password}) async {}

  @override
  SoftApDial? get dial => null;

  @override
  Future<void> startKeepalive(String host) async {
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final addr = InternetAddress(host);
      final payload = utf8.encode('soundcore-keep-alive-unicast');
      void ping() {
        try {
          _udp?.send(payload, addr, 32003);
        } catch (e) {
          debugPrint('[WiFiExport] UDP ping fail: $e');
        }
      }

      ping();
      _udpTimer = Timer.periodic(const Duration(seconds: 2), (_) => ping());
    } catch (e) {
      debugPrint('[WiFiExport] UDP keepalive unavailable: $e');
    }
  }

  @override
  Future<void> release() async {
    _udpTimer?.cancel();
    _udpTimer = null;
    try {
      _udp?.close();
    } catch (_) {}
    _udp = null;
  }
}

/// Android: Koe asks the system to join the hotspot beside the phone's own
/// network (the system shows a "connect to device" dialog). Only traffic
/// bound to that network reaches the recorder, so the native side
/// (`SoftApNetwork.kt`) opens the connection and sends the keepalive; the
/// rest of Koe stays on the default network meanwhile.
class AndroidSoftApLink implements SoftApLink {
  AndroidSoftApLink({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.semanticcraft.koe/softap_network';

  /// How long the system looks for the hotspot and waits for the user's
  /// choice in its dialog.
  static const joinTimeout = Duration(seconds: 90);

  final MethodChannel _channel;

  @override
  bool get joinsItself => true;

  @override
  Future<void> join({required String ssid, required String password}) async {
    final allowed = await _channel.invokeMethod<bool>('ensureLocalNetwork');
    if (allowed != true) {
      throw const SoftApJoinException(
        'Koe 没有「附近的设备」权限，连不上录音豆的 Wi‑Fi。请在系统设置里允许后重试',
      );
    }
    final error = await _channel.invokeMethod<String>('join', {
      'ssid': ssid,
      'password': password,
      'timeoutMs': joinTimeout.inMilliseconds,
    });
    switch (error) {
      case null:
        return;
      case 'wifi_off':
        throw const SoftApJoinException('手机 Wi‑Fi 已关闭。打开 Wi‑Fi 后重试');
      default:
        throw SoftApJoinException(
          '没有连上录音豆的 Wi‑Fi「$ssid」：在系统弹窗里选它并点「连接」。'
          '录音豆请保持开机、打开充电盒',
        );
    }
  }

  @override
  SoftApDial get dial => _throughTunnel;

  Future<Socket> _throughTunnel(String host, int port) async {
    final local = await _channel.invokeMethod<int>('openTunnel', {
      'host': host,
      'port': port,
    });
    return Socket.connect(InternetAddress.loopbackIPv4, local!);
  }

  @override
  Future<void> startKeepalive(String host) =>
      _channel.invokeMethod<void>('startKeepalive', {'host': host});

  @override
  Future<void> release() => _channel.invokeMethod<void>('release');
}
