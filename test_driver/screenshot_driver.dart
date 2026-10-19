import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Saves each `takeScreenshot` of integration_test/screenshots/ as a PNG.
Future<void> main() => integrationDriver(
  onScreenshot: (name, bytes, [args]) async {
    final out = Directory(
      Platform.environment['KOE_SCREENSHOT_DIR'] ?? 'build/screenshots',
    )..createSync(recursive: true);
    File('${out.path}/$name.png').writeAsBytesSync(bytes);
    return true;
  },
);
