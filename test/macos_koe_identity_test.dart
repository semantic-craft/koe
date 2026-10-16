import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/legacy_bundle.dart';

// #36: after Koe.app is installed, the pre-rename Soundcore Manager.app (same
// Bundle ID) is archived, verified and removed — and never Koe.app itself.

void main() {
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

    void installLegacy({String plist = '', String binary = 'x'}) {
      Directory('$legacy/Contents/MacOS').createSync(recursive: true);
      File(
        '$legacy/Contents/Info.plist',
      ).writeAsStringSync(plist.isEmpty ? legacyInfoPlist() : plist);
      File(
        '$legacy/Contents/MacOS/Soundcore Manager',
      ).writeAsStringSync(binary);
    }

    void expectKeptWithoutArchive(ProcessResult result) {
      expect(result.exitCode, isNot(0), reason: '${result.stdout}');
      expect(result.stderr, contains('left in place'));
      expect(
        File('$legacy/Contents/MacOS/Soundcore Manager').readAsStringSync(),
        'x',
      );
      expect(Directory(backups).existsSync(), isFalse);
    }

    test('archives, verifies, then removes the old bundle', () async {
      installLegacy();

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
      final unpacked = await Process.run('ditto', [
        '-x',
        '-k',
        archives.single.path,
        restore.path,
      ]);
      expect(unpacked.exitCode, 0);
      expect(
        File(
          '${restore.path}/Soundcore Manager.app/Contents/MacOS/'
          'Soundcore Manager',
        ).readAsStringSync(),
        'x',
      );
    });

    test('refuses Koe.app at the legacy path (executable Koe)', () async {
      installLegacy(
        plist: legacyInfoPlist(
          executable: 'Koe',
          name: 'Koe',
          displayName: 'Koe',
        ),
      );
      final result = await retire();
      expectKeptWithoutArchive(result);
      expect(result.stderr, contains("CFBundleExecutable 'Koe'"));
    });

    test(
      'refuses a build newer than Koe that is not a listed legacy version',
      () async {
        installLegacy(plist: legacyInfoPlist(version: '9.0.0'));
        final result = await retire();
        expectKeptWithoutArchive(result);
        expect(result.stderr, contains('has version 9.0.0+1'));
      },
    );

    test('does nothing when no old bundle is installed', () async {
      final result = await retire();
      expect(result.exitCode, 0);
      expect(result.stdout, contains('nothing to retire'));
      expect(Directory(backups).existsSync(), isFalse);
    });
  }, skip: Platform.isMacOS ? false : 'needs macOS ditto');
}
