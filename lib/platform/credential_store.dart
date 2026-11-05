import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CredentialStorageException implements Exception {
  const CredentialStorageException();
  String get message => '无法确认系统安全存储状态；请在设置中点击“重试读取安全配置”完成授权';
  @override
  String toString() => message;
}

/// One atomic Keychain item. Null values are tombstones: a cleared credential
/// must never be resurrected from a legacy JSON file after an interrupted save.
///
/// Android keeps the same item in flutter_secure_storage, whose Keystore key
/// never leaves the device; uninstalling or clearing data removes both, so the
/// app starts again with no saved keys.
class CredentialStore {
  static const channel = MethodChannel(
    'com.semanticcraft.soundcore/credentials',
  );

  /// `resetOnError: false`: the plugin otherwise deletes an item it cannot
  /// decrypt and reports it missing, which would let a legacy JSON key
  /// silently replace it (FlutterSecureStorage.java:1316-1344 in 11.2.0).
  static const _android = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  static const _androidKey = 'engines-v1';

  static bool get _onAndroid => defaultTargetPlatform == TargetPlatform.android;

  Future<bool> get isIsolated async {
    if (_onAndroid) return false;
    return await channel.invokeMethod<String>('mode') != 'system';
  }

  Future<void> authorize() async {
    try {
      if (_onAndroid) {
        await _android.read(key: _androidKey);
      } else {
        await channel.invokeMethod<void>('authorize');
      }
    } catch (_) {
      throw const CredentialStorageException();
    }
  }

  Future<String?> _readItem() => _onAndroid
      ? _android.read(key: _androidKey)
      : channel.invokeMethod<String>('read');

  Future<void> _writeItem(String encoded) => _onAndroid
      ? _android.write(key: _androidKey, value: encoded)
      : channel.invokeMethod<void>('write', encoded);

  Future<Map<String, String?>> read() async {
    try {
      final encoded = await _readItem();
      if (encoded == null) return {};
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      if (decoded.entries.any(
        (e) =>
            !const [
              'qwen',
              'doubao',
              'analysisOpenAiCompatible',
              'mcpSyncToken',
            ].contains(e.key) ||
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
      await _writeItem(jsonEncode(values));
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
