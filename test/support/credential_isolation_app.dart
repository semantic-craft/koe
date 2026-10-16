// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:koe/platform/credential_store.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/speech_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Text('Credential isolation verification'))));
  try {
    final store = CredentialStore();
    if (!await store.isIsolated) throw StateError('Personal credential mode');
    final settings = await AppSettingsStore.load();
    if (settings.storageError != null) throw StateError('Settings load failed');
    await AppSettingsStore.save(settings.copyWith(engines: {
      'qwen': const EngineConfig(apiKey: 'synthetic-verification-only'),
    }), strict: true);
    final reopened = await AppSettingsStore.load();
    if (reopened.engineConfig(SttProvider.qwen).apiKey != 'synthetic-verification-only') {
      throw StateError('Readback failed');
    }
    await store.authorize();
    final diagnostic = await CredentialStore.channel.invokeMapMethod<String, dynamic>('diagnostics');
    if (diagnostic?['securityCalls'] != 0) throw StateError('Reached Security');
    print('KOE_CREDENTIAL_ISOLATION_PASS: load/save/readback/authorize; Security calls=0');
    exit(0);
  } catch (_) {
    print('KOE_CREDENTIAL_ISOLATION_FAIL');
    exit(1);
  }
}
