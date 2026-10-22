import 'dart:io';

typedef WifiCheck = Future<bool> Function();

/// Checks whether the device currently has an active Wi-Fi (or wired LAN)
/// interface using `dart:io` [NetworkInterface.list], without extra packages.
///
/// On iOS/macOS, Wi-Fi/Ethernet interfaces are `en0`..`en9` while cellular is
/// `pdp_ip*`; on Android, Wi-Fi is `wlan*`/`eth*` while cellular is
/// `rmnet*`/`ccmni*`.
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
    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      final isWifiOrLan =
          RegExp(r'^(en\d+|wlan\d+|eth\d+|ap\d+|wi-?fi)$').hasMatch(name);
      if (!isWifiOrLan) continue;
      final hasUsableAddress = iface.addresses.any((addr) => !addr.isLoopback);
      if (hasUsableAddress) return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}
