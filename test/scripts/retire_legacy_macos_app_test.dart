import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// #59: scripts/retire-legacy-macos-app.sh must never retire the bundle that is
// being installed (same path, or one bundle inside the other), and must keep
// the old bundle unless its archive restores byte-identical content. Runs headless; the archive cases need macOS ditto.

const script = 'scripts/retire-legacy-macos-app.sh';
const binary = 'Contents/MacOS/Soundcore Manager';

void main() {
  late Directory root;
  late String apps;
  late String legacy;
  late String backups;

  setUp(() {
    root = Directory.systemTemp.createTempSync('koe-retire-test');
    // Resolve the temp dir itself (macOS /var -> /private/var) so the paths
    // the script compares are not affected by it.
    apps = '${root.resolveSymbolicLinksSync()}/Applications';
    legacy = '$apps/Soundcore Manager.app';
    backups = '${root.path}/backups';
    Directory('$legacy/Contents/MacOS').createSync(recursive: true);
    File('$legacy/Contents/Info.plist').writeAsStringSync('<plist/>');
    File('$legacy/$binary').writeAsStringSync('original');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> retire({
    required String target,
    List<String> args = const [],
    String? path,
  }) => Process.run(
    'bash',
    [script, ...args],
    environment: {
      'MACOS_LEGACY_INSTALL_PATH': legacy,
      'MACOS_LEGACY_BACKUP_DIR': backups,
      'MACOS_INSTALL_PATH': target,
      'PATH': ?path,
    },
  );

  void expectLegacyUntouched(ProcessResult result) {
    expect(result.exitCode, isNot(0), reason: '${result.stdout}');
    expect(File('$legacy/$binary').readAsStringSync(), 'original');
    expect(File('$legacy/Contents/Info.plist').existsSync(), isTrue);
  }

  group('refuses when the install target is the old bundle', () {
    test('identical path', () async {
      final result = await retire(target: legacy);
      expectLegacyUntouched(result);
      expect(result.stderr, contains('refusing to retire'));
      expect(Directory(backups).existsSync(), isFalse);
    });

    test('trailing slash variants', () async {
      for (final target in ['$legacy/', '$legacy//']) {
        final result = await retire(target: target);
        expectLegacyUntouched(result);
        expect(result.stderr, contains('refusing to retire'), reason: target);
      }
      expect(Directory(backups).existsSync(), isFalse);
    });

    test('target is a symlink to the old bundle', () async {
      final link = Link('$apps/Koe.app')..createSync(legacy);
      final result = await retire(target: link.path);
      expectLegacyUntouched(result);
      expect(result.stderr, contains('refusing to retire'));
      expect(Directory(backups).existsSync(), isFalse);
    });

    test('target reached through a symlinked parent directory', () async {
      final alias = Link('${root.path}/AppsAlias')..createSync(apps);
      final result = await retire(
        target: '${alias.path}/Soundcore Manager.app/',
      );
      expectLegacyUntouched(result);
      expect(result.stderr, contains('refusing to retire'));
    });

    test('--check-running also refuses, so install stops before building',
        () async {
      final result = await retire(target: '$legacy/', args: ['--check-running']);
      expectLegacyUntouched(result);
      expect(result.stderr, contains('refusing to retire'));
    });

    test('a different target passes --check-running', () async {
      final result = await retire(
        target: '$apps/Koe.app',
        args: ['--check-running'],
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(File('$legacy/$binary').readAsStringSync(), 'original');
    });

    test('install-macos.sh hands its target to both retire calls', () {
      final install = File('scripts/install-macos.sh').readAsStringSync();
      expect(
        'MACOS_INSTALL_PATH="\$TARGET" "\$ROOT/$script"'.allMatches(install),
        hasLength(2),
      );
    });
  });

  group('refuses when the install target and the old bundle are nested', () {
    // Deleting the old bundle would delete (or gut) the bundle being installed.
    late String nested;
    setUp(() {
      nested = '$legacy/Contents/Koe.app';
      Directory('$nested/Contents').createSync(recursive: true);
      File('$nested/Contents/Info.plist').writeAsStringSync('new');
    });

    void expectBothUntouched(ProcessResult result, String target) {
      expectLegacyUntouched(result);
      expect(result.stderr, contains('refusing to retire'), reason: target);
      expect(File('$nested/Contents/Info.plist').readAsStringSync(), 'new');
      expect(Directory(backups).existsSync(), isFalse, reason: target);
    }

    test('target inside the old bundle', () async {
      final link = Link('$apps/Koe.app')..createSync(nested);
      for (final target in [
        nested,
        '$nested/',
        link.path,
        '$legacy/Contents/Not Yet/Koe.app',
      ]) {
        expectBothUntouched(await retire(target: target), target);
      }
    });

    test('old bundle inside the target', () async {
      final alias = Link('${root.path}/AppsAlias')..createSync(apps);
      for (final target in [apps, '$apps/', alias.path]) {
        expectBothUntouched(await retire(target: target), target);
      }
    });

    test('--check-running also refuses a nested target', () async {
      final result = await retire(target: nested, args: ['--check-running']);
      expectBothUntouched(result, nested);
    });

    test('differently cased path on a case-insensitive volume', () async {
      final cased = '$apps/soundcore manager.app';
      if (!File('$cased/Contents/Info.plist').existsSync()) {
        markTestSkipped('volume is case-sensitive');
        return;
      }
      final target = '$cased/Contents/Koe.app';
      expectBothUntouched(await retire(target: target), target);
    });
  });

  group('archive verification', () {
    // A ditto wrapper that, after a real extraction, rewrites the restored
    // binary with different bytes of the same length: the file list is
    // unchanged, only content differs.
    String tamperingPath() {
      final bin = Directory('${root.path}/bin')..createSync();
      final shim = File('${bin.path}/ditto')
        ..writeAsStringSync('''
#!/bin/bash
/usr/bin/ditto "\$@" || exit \$?
if [[ "\$1" == "-x" ]]; then
  dest="\${@: -1}"
  printf 'tampered' > "\$dest/Soundcore Manager.app/$binary"
fi
''');
      Process.runSync('chmod', ['+x', shim.path]);
      return '${bin.path}:${Platform.environment['PATH']}';
    }

    test('content changed inside the archive keeps the old bundle, exit 1',
        () async {
      final result = await retire(
        target: '$apps/Koe.app',
        path: tamperingPath(),
      );
      expect(result.exitCode, 1, reason: '${result.stdout}${result.stderr}');
      expect(result.stderr, contains('does not restore identical file contents'));
      expect(result.stderr, contains('left in place'));
      expectLegacyUntouched(result);
    });

    test('untampered archive retires the old bundle', () async {
      final result = await retire(target: '$apps/Koe.app');
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(Directory(legacy).existsSync(), isFalse);
      final archives = Directory(backups)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.zip'));
      expect(archives, hasLength(1));
    });
  }, skip: Platform.isMacOS ? false : 'needs macOS ditto');
}
