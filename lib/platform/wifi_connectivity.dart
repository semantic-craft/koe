import 'dart:io';

import 'package:flutter/services.dart';

typedef WifiCheck = Future<bool> Function();

/// Requires an addressed interface and an OS-confirmed Wi-Fi default path.
/// Interface names cannot distinguish Ethernet, Wi-Fi and AP mode. Darwin uses
/// NWPathMonitor; Android uses the active network's NetworkCapabilities.
/// Unknown/missing platform support fails closed. This is a path snapshot, not
/// socket binding: routing can change between a check and an HTTP operation.
Future<bool> defaultIsWifiConnected({
  Future<List<NetworkInterface>> Function()? listInterfaces,
}) async {
  try {
    final lister =
        listInterfaces ??
        () => NetworkInterface.list(
          includeLinkLocal: false,
          type: InternetAddressType.any,
        );
    final interfaces = await lister();
    if (!interfaces.any(
      (iface) => iface.addresses.any((addr) => !addr.isLoopback),
    )) {
      return false;
    }
    return await const MethodChannel(
          'com.semanticcraft.koe/wifi_connectivity',
        ).invokeMethod<bool>('isWifiConnected') ==
        true;
  } catch (_) {
    return false;
  }
}
