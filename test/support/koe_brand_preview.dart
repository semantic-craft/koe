// Run with flutter run -d macos -t test/support/koe_brand_preview.dart.
// Uses synthetic recordings; never loads saved settings or connects a device.
import 'package:flutter/widgets.dart';
import 'package:koe/main.dart';

import 'macos_accessibility_app.dart' show PreviewController;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(KoeApp(controller: PreviewController()));
}
