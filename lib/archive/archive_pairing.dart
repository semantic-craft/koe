import 'dart:convert';
import 'dart:typed_data';

import 'archive_wire.dart';

/// Explicit, user-copied pairing information for one Mac receiving service.
///
/// The encoded string is deliberately opaque and not a URL: the pairing secret
/// never appears in a query string, log line or share link. The Mac UI only
/// renders it after the user expands the pairing panel.
class ArchivePairing {
  ArchivePairing({
    required this.deskId,
    required this.key,
    required List<String> hosts,
    required this.port,
  }) : hosts = List.unmodifiable(hosts);

  final String deskId;

  /// base64url (no padding) of the 32-byte pre-shared pairing key.
  final String key;
  final List<String> hosts;
  final int port;

  Uint8List get keyBytes => decodeKey(key);

  static Uint8List decodeKey(String value) {
    final decoded = base64Url.decode(base64Url.normalize(value));
    if (decoded.length != 32) {
      throw const ArchiveProtocolException('配对密钥长度不正确');
    }
    return decoded;
  }

  String get address {
    final host = hosts.isEmpty ? '127.0.0.1' : hosts.first;
    return '$host:$port';
  }

  /// Never include the key in logs or diagnostics.
  String get redacted => 'Mac $address';

  String encode() {
    final encoded = base64Url
        .encode(utf8.encode(jsonEncode(toJson())))
        .replaceAll('=', '');
    return 'KOE1.$encoded';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': archiveProtocolVersion,
    'd': deskId,
    'k': key,
    'h': hosts,
    'p': port,
  };

  static ArchivePairing? tryParse(String raw) {
    try {
      return parse(raw);
    } on ArchiveException {
      return null;
    }
  }

  static ArchivePairing parse(String raw) {
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    if (compact.length < 16 || compact.length > 4096) {
      throw const ArchiveProtocolException('配对信息长度不正确');
    }
    if (!compact.startsWith('KOE1.')) {
      throw const ArchiveProtocolException('这不是 Koe 的配对信息');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(compact.substring(5))),
        ),
      );
    } catch (_) {
      throw const ArchiveProtocolException('配对信息无法读取');
    }
    if (decoded is! Map) {
      throw const ArchiveProtocolException('配对信息格式不正确');
    }
    final version = decoded['v'];
    if (version is! int || version != archiveProtocolVersion) {
      throw const ArchiveProtocolException('配对信息版本不受支持');
    }
    final deskId = decoded['d'];
    final key = decoded['k'];
    final rawHosts = decoded['h'];
    final port = decoded['p'];
    if (deskId is! String ||
        !RegExp(r'^[a-f0-9]{16,64}$').hasMatch(deskId) ||
        key is! String ||
        rawHosts is! List ||
        rawHosts.isEmpty ||
        rawHosts.length > 8 ||
        port is! int ||
        port < 1 ||
        port > 65535) {
      throw const ArchiveProtocolException('配对信息缺少有效字段');
    }
    final hosts = <String>[];
    for (final value in rawHosts) {
      if (value is! String) {
        throw const ArchiveProtocolException('配对地址格式不正确');
      }
      final host = value.trim();
      if (host.isEmpty ||
          host.length > 253 ||
          host.contains(':') ||
          !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(host)) {
        throw const ArchiveProtocolException('配对地址格式不正确');
      }
      if (!hosts.contains(host)) hosts.add(host);
    }
    if (hosts.isEmpty) {
      throw const ArchiveProtocolException('配对信息没有可用地址');
    }
    final pairing = ArchivePairing(
      deskId: deskId,
      key: key,
      hosts: hosts,
      port: port,
    );
    // Validate the key length without exposing it.
    pairing.keyBytes;
    return pairing;
  }

  static String generateKey() =>
      base64Url.encode(archiveRandomBytes(32)).replaceAll('=', '');

  static String generateDeskId() => archiveRandomHex(16);

  @override
  String toString() =>
      'ArchivePairing(desk: $deskId, address: $address, key: <redacted>)';
}
