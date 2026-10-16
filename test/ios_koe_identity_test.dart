import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// #37: iOS shows Koe on the home screen, in Settings, in permission prompts
// and in Shortcuts, while the install identity (Bundle ID, URL entry) and the
// shortcut wiring (intent and provider type names, channel name, pending-start
// key) stay unchanged so existing shortcuts, data and device bindings work.

const bundleId = 'com.semanticcraft.soundcore';
const channelName = 'com.capyvibe.soundcore/recording_shortcut';

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

    test('Bundle ID, URL entry and background mode are unchanged', () {
      final plist = read('ios/Runner/Info.plist');
      expect(plistString(plist, 'CFBundleIdentifier'),
          r'$(PRODUCT_BUNDLE_IDENTIFIER)');
      expect(plistString(plist, 'CFBundleURLName'),
          'com.anker.soundcoreManager');
      expect(plist, contains('<string>soundcore</string>'));
      expect(plist, contains('<string>bluetooth-central</string>'));

      final project = read('ios/Runner.xcodeproj/project.pbxproj');
      expect(
        'PRODUCT_BUNDLE_IDENTIFIER = $bundleId;'.allMatches(project),
        hasLength(3),
      );
      expect(
        'PRODUCT_BUNDLE_IDENTIFIER = $bundleId.RunnerTests;'
            .allMatches(project),
        hasLength(3),
      );
    });
  });

  group('iOS recording shortcut', () {
    final swift = read('ios/Runner/RecordingShortcut.swift');

    test('identity of the action and its wiring is unchanged', () {
      expect(swift, contains('struct StartRecordingIntent: AppIntent'));
      expect(swift,
          contains('struct SoundcoreAppShortcuts: AppShortcutsProvider'));
      expect(swift, contains('intent: StartRecordingIntent()'));
      expect(swift, contains('static let channelName = "$channelName"'));
      expect(
        swift,
        contains('pendingStartKey = "recordingShortcut.pendingStartRecording"'),
      );
      expect(swift, contains('"consumePendingStartRecording"'));
      expect(swift, contains('invokeMethod("pendingStartRecording"'));
      expect(swift, contains(r'\(.applicationName)'));
      // The Dart side listens on the same channel.
      expect(read('lib/platform/recording_shortcut_service.dart'),
          contains("MethodChannel('$channelName')"));
    });

    test('shortcut text names Koe and the supported device', () {
      expect(swift, isNot(contains('Soundcore Manager')));
      final description = RegExp(r'IntentDescription\(\s*"([^"]*)"')
          .firstMatch(swift)!
          .group(1)!;
      expect(description, contains('Koe — 安克录音豆录音与转写工具'));
      expect(description, contains('soundcore Work / D3200'));
      final title = RegExp(r'static let title: LocalizedStringResource = "([^"]*)"')
          .firstMatch(swift)!
          .group(1)!;
      expect(title, contains('Koe'));
    });
  });

  test('install-ios.sh names Koe and keeps its build and install steps', () {
    final script = read('scripts/install-ios.sh');
    expect(script, isNot(contains('Soundcore Manager')));
    expect(script, contains("printf '==> Installing Koe\\n'"));
    expect(script, contains(r'TEAM_ID="${TEAM_ID:-LQAVR62TK2}"'));
    expect(script,
        contains(r'Build/Products/${CONFIGURATION}-iphoneos/Runner.app'));
    expect(script, contains('xcrun devicectl device install app'));
  });

  test('every AppIcon entry exists at its declared pixel size', () {
    const dir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final images = (jsonDecode(read('$dir/Contents.json'))
            as Map<String, dynamic>)['images'] as List<dynamic>;
    expect(images, isNotEmpty);
    var hasMarketing = false;
    for (final image in images.cast<Map<String, dynamic>>()) {
      final name = image['filename'] as String;
      final bytes = File('$dir/$name').readAsBytesSync();
      expect(bytes.sublist(0, 8),
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
          reason: name);
      final header = ByteData.sublistView(bytes, 16, 24);
      final points = double.parse((image['size'] as String).split('x').first);
      final scale = int.parse((image['scale'] as String).replaceAll('x', ''));
      final pixels = (points * scale).round();
      expect(header.getUint32(0), pixels, reason: name);
      expect(header.getUint32(4), pixels, reason: name);
      if (pixels == 1024) hasMarketing = true;
    }
    expect(hasMarketing, isTrue, reason: '1024 App Store icon');
  });
}
