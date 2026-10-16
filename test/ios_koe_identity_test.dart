import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// #37: iOS shows Koe on the home screen, in Settings, in permission prompts,
// in Shortcuts and in install-ios.sh output. Unchanged identifiers (Bundle ID,
// URL scheme, AppIntent/AppShortcutsProvider type names, MethodChannel and
// UserDefaults key) are verified via diff rather than unchanged-string tests.

String read(String path) => File(path).readAsStringSync();

String? plistString(String plist, String key) => RegExp(
  '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
).firstMatch(plist)?.group(1);

void main() {
  group('iOS display identity', () {
    test('home screen and Settings show Koe', () {
      final plist = read('ios/Runner/Info.plist');
      expect(plistString(plist, 'CFBundleDisplayName'), 'Koe');
      expect(plistString(plist, 'CFBundleName'), 'Koe');
    });

    test('permission prompts name Koe and the supported device', () {
      final plist = read('ios/Runner/Info.plist');
      for (final key in [
        'NSBluetoothAlwaysUsageDescription',
        'NSBluetoothPeripheralUsageDescription',
        'NSLocalNetworkUsageDescription',
      ]) {
        final text = plistString(plist, key)!;
        expect(text, startsWith('Koe '), reason: key);
        expect(text, contains('安克录音豆'), reason: key);
        expect(text, isNot(contains('Soundcore Manager')), reason: key);
      }
      expect(plist, isNot(contains('Soundcore Manager')));
    });
  });

  group('iOS recording shortcut', () {
    test('shortcut text names Koe and the supported device', () {
      final swift = read('ios/Runner/RecordingShortcut.swift');
      expect(swift, isNot(contains('Soundcore Manager')));
      final description = RegExp(
        r'IntentDescription\(\s*"([^"]*)"',
      ).firstMatch(swift)!.group(1)!;
      expect(description, contains('Koe — 安克录音豆录音与转写工具'));
      expect(description, contains('soundcore Work / D3200'));
      final title = RegExp(
        r'static let title: LocalizedStringResource = "([^"]*)"',
      ).firstMatch(swift)!.group(1)!;
      expect(title, '用 Koe 开始录音');
      final shortTitle = RegExp(
        r'shortTitle:\s*"([^"]*)"',
      ).firstMatch(swift)!.group(1)!;
      expect(shortTitle, '开始录音');
    });
  });

  test('install-ios.sh --help and install prompt name Koe', () async {
    final help = await Process.run('bash', ['scripts/install-ios.sh', '--help']);
    expect(help.exitCode, 0, reason: '${help.stderr}');
    expect(
      help.stdout as String,
      contains('Build Koe using Xcode-managed iOS signing'),
    );
    expect(help.stdout as String, isNot(contains('Soundcore Manager')));

    final script = read('scripts/install-ios.sh');
    expect(script, isNot(contains('Soundcore Manager')));
    expect(script, contains("printf '==> Installing Koe\\n'"));
  });
}

