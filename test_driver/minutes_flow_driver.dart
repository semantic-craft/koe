import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final output = Platform.environment['KOE_MINUTES_PROOF_DIR'];
  if (output == null || output.isEmpty) {
    throw StateError('Run scripts/verify-minutes-flow ios to isolate evidence');
  }
  final directory = Directory(output);
  await integrationDriver(
    onScreenshot: (name, bytes, [arguments]) async {
      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name) || bytes.isEmpty) {
        return false;
      }
      final screenshots = Directory('${directory.path}/screenshots');
      await screenshots.create(recursive: true);
      await File(
        '${screenshots.path}/$name.png',
      ).writeAsBytes(bytes, flush: true);
      return true;
    },
    responseDataCallback: (data) async {
      await File(
        '${directory.path}/ios-proof.json',
      ).writeAsString(jsonEncode(data), flush: true);
    },
  );
}
