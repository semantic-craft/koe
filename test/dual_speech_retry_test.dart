import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native silent lane waits for voice without starving the other lane',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'koe-speech-retry-',
      );
      try {
        final binary = '${directory.path}/retry-check';
        final build = await Process.run('xcrun', [
          'swiftc',
          'macos/Runner/DualSpeechRetryGate.swift',
          'tool/native_tests/dual_speech_retry.swift',
          '-o',
          binary,
        ]);
        expect(build.exitCode, 0, reason: '${build.stderr}');
        final run = await Process.run(binary, []);
        expect(run.exitCode, 0, reason: '${run.stderr}');
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}
