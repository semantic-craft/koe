// Explicit real-device probe: flutter drive --debug -d macos
// --driver=test_driver/dual_capture_driver.dart
// --target=integration_test/macos/dual_capture_test.dart
// Requires microphone/system-audio permission. Play audio from another app
// during the 12-second capture; silence is a failure, not a synthetic pass.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/platform/mac_dual_recorder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real process tap produces nonzero aligned system audio', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('双路录音验收 · 12 秒'))),
      ),
    );
    final directory = await Directory.systemTemp.createTemp('koe-dual-probe-');
    final path = '${directory.path}/phone_probe.wav';
    final recorder = MacDualRecorder()..enabled = true;
    try {
      expect(await recorder.requestPermission(), isTrue);
      const channel = MethodChannel('com.semanticcraft.koe/dual_recording');
      expect(await channel.invokeMethod<bool>('supported'), isTrue);
      // Capture is checked separately from Speech authorization: flutter drive
      // launches the executable with a non-bundled responsible process.
      await channel.invokeMethod<void>('start', {
        'path': path,
        'transcribe': false,
      });
      debugPrint('DUAL_CAPTURE_STARTED');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 12)),
      );
      await channel.invokeMethod<void>('stop');
      final mic = await File(path).readAsBytes();
      final system = await File(MacDualRecorder.systemPath(path)).readAsBytes();
      expect(mic.length, greaterThan(32000));
      expect((mic.length - system.length).abs(), lessThanOrEqualTo(2));
      final data = ByteData.sublistView(system);
      var peak = 0;
      for (var i = 44; i + 1 < system.length; i += 2) {
        final value = data.getInt16(i, Endian.little).abs();
        if (value > peak) peak = value;
      }
      expect(
        peak,
        greaterThan(20),
        reason: 'system tap is all-zero or nearly silent',
      );
      debugPrint(
        'DUAL_CAPTURE_PASS micBytes=${mic.length} systemBytes=${system.length} peak=$peak',
      );
    } finally {
      await recorder.dispose();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
