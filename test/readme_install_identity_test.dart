import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #39: the install guide has to name the same product, disk image, install
/// path and shortcut the scripts and the iOS intent actually ship.
///
/// On main before this change the guide still titled the app
/// "Soundcore Manager（安克录音豆）", told users to pick
/// "安克录音豆 → Start Recording", and pointed at
/// `dist/soundcore-manager-<version>-macos.dmg`.
void main() {
  test('README title, DMG name, install path and shortcut match artifacts', () {
    final readme = File('README.md').readAsStringSync();
    final dmg = File('scripts/build-dmg.sh').readAsStringSync();
    final install = File('scripts/install-macos.sh').readAsStringSync();
    final shortcut = File('ios/Runner/RecordingShortcut.swift').readAsStringSync();

    expect(readme, contains('<h1 align="center">Koe</h1>'));

    final dmgName = RegExp(r'dist/koe-<version>-macos\.dmg')
        .firstMatch(dmg)!
        .group(0)!;
    expect(readme, contains(dmgName));
    expect(readme, isNot(contains('soundcore-manager-')));

    final target = RegExp(r'MACOS_INSTALL_PATH:-([^}]+)')
        .firstMatch(install)!
        .group(1)!;
    expect(readme, contains(target));

    final shortTitle = RegExp(r'shortTitle: "([^"]+)"')
        .firstMatch(shortcut)!
        .group(1)!;
    final title = RegExp(
      r'static let title: LocalizedStringResource = "([^"]+)"',
    ).firstMatch(shortcut)!.group(1)!;
    expect(readme, contains('Koe → $shortTitle'));
    expect(readme, contains(title));
    expect(readme, isNot(contains('Start Recording')));
  });
}
