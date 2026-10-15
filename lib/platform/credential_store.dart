import 'dart:convert';

import 'package:flutter/services.dart';

class CredentialStorageException implements Exception {
  const CredentialStorageException();
  String get message => '无法确认系统安全存储状态；请解锁设备后重试读取配置';
  @override
  String toString() => message;
}

/// One atomic Keychain item. Null values are tombstones: a cleared credential
/// must never be resurrected from a legacy JSON file after an interrupted save.
class CredentialStore {
  static const channel = MethodChannel(
    'com.semanticcraft.soundcore/credentials',
  );

  Future<Map<String, String?>> read() async {
    try {
      final encoded = await channel.invokeMethod<String>('read');
      if (encoded == null) return {};
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      if (decoded.entries.any(
        (e) =>
            !const ['qwen', 'doubao'].contains(e.key) ||
            (e.value != null && e.value is! String),
      )) {
        throw const CredentialStorageException();
      }
      return decoded.cast<String, String?>();
    } catch (_) {
      throw const CredentialStorageException();
    }
  }

  Future<void> write(Map<String, String?> values) async {
    try {
      await channel.invokeMethod<void>('write', jsonEncode(values));
      final saved = await read();
      if (saved.length != values.length ||
          values.entries.any(
            (e) => !saved.containsKey(e.key) || saved[e.key] != e.value,
          )) {
        throw const CredentialStorageException();
      }
    } catch (_) {
      throw const CredentialStorageException();
    }
  }
}
