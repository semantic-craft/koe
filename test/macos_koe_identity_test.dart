import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// #36: the macOS product, menus, permission prompts and every script that
// locates the built or installed bundle use Koe, while the install identity
// (Bundle ID, URL scheme, signing requirement) stays unchanged so existing
// recordings, settings, device bindings and Keychain access keep working.

const bundleId = 'com.anker.ankerRecorder';

String read(String path) => File(path).readAsStringSync();

String? plistString(String plist, String key) => RegExp(
  '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
).firstMatch(plist)?.group(1);

void main() {
  group('macOS product identity', () {
    test('product is Koe; Bundle ID and copyright source are accurate', () {
      final config = read('macos/Runner/Configs/AppInfo.xcconfig');
      expect(config, contains('PRODUCT_NAME = Koe\n'));
      expect(config, contains('PRODUCT_BUNDLE_IDENTIFIER = $bundleId\n'));
      final copyright = RegExp(
        r'^PRODUCT_COPYRIGHT = (.*)$',
        multiLine: true,
      ).firstMatch(config)!.group(1)!;
      expect(copyright, isNot(contains('com.anker')));
      expect(copyright, contains('tacshi'));
      expect(copyright, isNot(contains('//')), reason: 'xcconfig comment');
    });

    test('Info.plist shows Koe and keeps the legacy URL entry', () {
      final plist = read('macos/Runner/Info.plist');
      expect(plistString(plist, 'CFBundleName'), r'$(PRODUCT_NAME)');
      expect(plistString(plist, 'CFBundleDisplayName'), 'Koe');
      expect(plistString(plist, 'CFBundleIdentifier'),
          r'$(PRODUCT_BUNDLE_IDENTIFIER)');
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
      expect(plistString(plist, 'CFBundleURLName'),
          'com.anker.soundcoreManager');
      expect(plist, contains('<string>soundcore</string>'));
    });

    test('menu items and window title name Koe, not a placeholder', () {
      final xib = read('macos/Runner/Base.lproj/MainMenu.xib');
      expect(xib, isNot(contains('APP_NAME')));
      for (final title in ['About Koe', 'Hide Koe', 'Quit Koe']) {
        expect(xib, contains('title="$title"'));
      }
      expect(xib, contains('<window title="Koe"'));
    });

    test('Xcode product, scheme and test host reference Koe.app', () {
      final project = read('macos/Runner.xcodeproj/project.pbxproj');
      final scheme = read(
        'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
      );
      for (final file in [project, scheme]) {
        expect(file, isNot(contains('Soundcore Manager')));
      }
      expect(project, contains('path = Koe.app;'));
      expect(
        RegExp(r'TEST_HOST = "\$\(BUILT_PRODUCTS_DIR\)/Koe\.app/'
                r'\$\(BUNDLE_EXECUTABLE_FOLDER_PATH\)/Koe";')
            .allMatches(project)
            .length,
        3,
      );
      expect(
        'PRODUCT_BUNDLE_IDENTIFIER = $bundleId.RunnerTests;'
            .allMatches(project)
            .length,
        3,
      );
      expect('BuildableName = "Koe.app"'.allMatches(scheme).length, 5);
    });
  });

  group('macOS scripts use the Koe bundle', () {
    test('install, DMG, debug and validation entry points', () {
      final install = read('scripts/install-macos.sh');
      expect(install,
          contains(r'TARGET="${MACOS_INSTALL_PATH:-/Applications/Koe.app}"'));
      expect(install, contains('scripts/retire-legacy-macos-app.sh'));
      expect(install, contains('--check-running'));

      final dmg = read('scripts/build-dmg.sh');
      expect(dmg, contains('APP_NAME="koe"\nDISPLAY_NAME="Koe"'));
      expect(dmg, contains(r'${APP_NAME}-${VERSION}-macos.dmg'));

      expect(read('scripts/debug-mac.sh'), contains('APP_NAME="Koe"'));
      expect(read('scripts/run-with-secrets.py'),
          contains("'/Applications/Koe.app/Contents/MacOS/Koe'"));
      expect(read('scripts/check-macos-accessibility.py'),
          contains('Debug/Koe.app/Contents/MacOS/Koe'));

      final check = read('skills/verify-koe/scripts/check.py');
      expect(check, contains("INSTALLED = Path('/Applications/Koe.app')"));
      expect(check, contains('Release/Koe.app'));
      expect(check, contains('Debug/Koe.app'));
      expect(check, contains("'Contents/MacOS/Koe'"));
    });

    test('signing keeps the Bundle ID that Keychain authorizations use', () {
      expect(read('scripts/sign-macos.sh'),
          contains(r'BUNDLE_ID="${BUNDLE_ID:-' '$bundleId' '}"'));
    });

    test('no script still launches or builds the pre-rename binary', () {
      for (final path in [
        'scripts/install-macos.sh',
        'scripts/build-dmg.sh',
        'scripts/debug-mac.sh',
        'scripts/run-with-secrets.py',
        'scripts/check-macos-accessibility.py',
        'skills/verify-koe/scripts/check.py',
      ]) {
        final text = read(path);
        expect(text, isNot(contains('MacOS/Soundcore Manager')), reason: path);
        expect(text, isNot(contains('Products/Release/Soundcore Manager')),
            reason: path);
        expect(text, isNot(contains('Products/Debug/Soundcore Manager')),
            reason: path);
        expect(text, isNot(contains('soundcore-manager')), reason: path);
      }
    });
  });

  group('retire-legacy-macos-app.sh', () {
    late Directory root;
    late String legacy;
    late String backups;

    setUp(() {
      root = Directory.systemTemp.createTempSync('koe-legacy-test');
      legacy = '${root.path}/Applications/Soundcore Manager.app';
      backups = '${root.path}/backups';
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<ProcessResult> retire() => Process.run(
      'bash',
      ['scripts/retire-legacy-macos-app.sh'],
      environment: {
        'MACOS_LEGACY_INSTALL_PATH': legacy,
        'MACOS_LEGACY_BACKUP_DIR': backups,
      },
    );

    test('archives, verifies, then removes the old bundle', () async {
      Directory('$legacy/Contents/MacOS').createSync(recursive: true);
      File('$legacy/Contents/Info.plist').writeAsStringSync('<plist/>');
      File('$legacy/Contents/MacOS/Soundcore Manager').writeAsStringSync('x');

      final result = await retire();
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(Directory(legacy).existsSync(), isFalse);

      final archives = Directory(backups)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.zip'))
          .toList();
      expect(archives, hasLength(1));
      expect(result.stdout, contains('Restore with: ditto -x -k'));

      final restore = Directory('${root.path}/restore')..createSync();
      final unpacked = await Process.run(
        'ditto',
        ['-x', '-k', archives.single.path, restore.path],
      );
      expect(unpacked.exitCode, 0);
      expect(
        File('${restore.path}/Soundcore Manager.app/Contents/MacOS/'
                'Soundcore Manager')
            .readAsStringSync(),
        'x',
      );
    });

    test('does nothing when no old bundle is installed', () async {
      final result = await retire();
      expect(result.exitCode, 0);
      expect(result.stdout, contains('nothing to retire'));
      expect(Directory(backups).existsSync(), isFalse);
    });
  }, skip: Platform.isMacOS ? false : 'needs macOS ditto');
}
