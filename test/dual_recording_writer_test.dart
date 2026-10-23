import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/phone_recorder.dart';

void main() {
  test(
    'native dual writer keeps timelines and recovers unfinalized audio',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'koe-dual-native-',
      );
      try {
        final binary = '${directory.path}/writer-check';
        final build = await Process.run('xcrun', [
          'swiftc',
          'macos/Runner/DualRecordingWriter.swift',
          'tool/native_tests/dual_writer.swift',
          '-o',
          binary,
        ]);
        expect(build.exitCode, 0, reason: '${build.stderr}');
        final run = await Process.run(binary, [directory.path]);
        expect(run.exitCode, 0, reason: '${run.stderr}');
        final path = '${directory.path}/crash.wav';
        expect(await repairWavSizes(path), isTrue);
        final bytes = await File(path).readAsBytes();
        expect(ByteData.sublistView(bytes).getUint32(40, Endian.little), 3200);
        expect(bytes.length, 3244);
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}
