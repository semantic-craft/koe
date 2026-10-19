import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:integration_test/integration_test_driver.dart';

/// Writes each scenario's timeline summary and the frame/memory numbers to
/// build/perf/ for scripts/perf-check.
Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null) return;
    final out = Directory('build/perf')..createSync(recursive: true);
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
