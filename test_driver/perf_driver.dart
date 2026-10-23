import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:integration_test/integration_test_driver.dart';

/// Writes each scenario's timeline summary and the frame/memory numbers to
/// build/perf/ for scripts/perf-check. When the app stopped the run because
/// macOS drew no frames, writes only the reason, to build/perf/no_frames.txt.
Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    if (data == null) return;
    final out = Directory('build/perf')..createSync(recursive: true);
    final noFrames = data['no_frames'];
    if (noFrames != null) {
      File('${out.path}/no_frames.txt').writeAsStringSync('$noFrames\n');
      return;
    }
    for (final entry in data.entries) {
      if (!entry.key.endsWith('_timeline')) continue;
      final timeline = driver.Timeline.fromJson(
        entry.value as Map<String, dynamic>,
      );
      try {
        await driver.TimelineSummary.summarize(timeline).writeTimelineToFile(
          entry.key,
          destinationDirectory: out.path,
          pretty: true,
          includeSummary: true,
        );
      } on StateError catch (error) {
        // No frame events in this window; keep the raw timeline.
        stderr.writeln('[perf] ${entry.key}: $error');
        await driver.TimelineSummary.summarize(timeline).writeTimelineToFile(
          entry.key,
          destinationDirectory: out.path,
          pretty: true,
          includeSummary: false,
        );
      }
    }
    File('${out.path}/results.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(data['perf']),
    );
  },
);
