import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recording_analysis.dart';

/// #10: summary/analysis requests are paid per segment. A process exit while a
/// request is outstanding must not auto-resubmit it, and a failed result write
/// must never be shown as a finished result.
void main() {
  late Directory dir;
  late File file;
  final longText = List.filled(13000, '文').join();
  const shortText = '会议决定下周发布。';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('analysis-recovery');
    file = File('${dir.path}/analysis.json');
  });
  tearDown(() => dir.delete(recursive: true));

  test('process exit during a segment request keeps finished segments and does '
      'not resubmit the outstanding one on reload', () async {
    final service = _Service()..hangAt = 2;
    final dying = RecordingAnalysis(file: file, service: service);
    unawaited(
      dying.run(
        recording: 'x',
        source: longText,
        apiKey: 'key',
        custom: false,
        currentSource: () => longText,
      ),
    );
    await _settle(() => service.calls == 2);
    // No dispose: the process is gone with segment 2 still in flight.

    final service2 = _Service();
    final reloaded = RecordingAnalysis(file: file, service: service2);
    addTearDown(reloaded.dispose);
    await reloaded.load();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(service2.calls, 0, reason: 'never auto-resubmit on reload');
    expect(reloaded.results, isEmpty);
    expect(reloaded.errors['x/summary'], contains('重新计费'));

    await reloaded.run(
      recording: 'x',
      source: longText,
      apiKey: 'key',
      custom: false,
      currentSource: () => longText,
    );
    expect(service2.inputs.first, startsWith('[S2]'), reason: 'S1 reused');
    expect(reloaded.results['x/summary'], isNotNull);
    expect(reloaded.errors['x/summary'], isNull);
  });

  test('result write failure is reported as unfinished and the paid output is '
      'reused on retry instead of requested again', () async {
    final service = _Service();
    final failing = _ResultWriteFails(file: file, service: service);
    addTearDown(failing.dispose);
    await failing.run(
      recording: 'x',
      source: shortText,
      apiKey: 'key',
      custom: false,
      currentSource: () => shortText,
    );
    expect(service.calls, 1);
    expect(failing.results, isEmpty, reason: 'no success without a save');
    expect(failing.errors['x/summary'], contains('分析未完成'));

    final service2 = _Service();
    final retry = RecordingAnalysis(file: file, service: service2);
    addTearDown(retry.dispose);
    await retry.load();
    expect(retry.results, isEmpty, reason: 'nothing finished on disk');
    await retry.run(
      recording: 'x',
      source: shortText,
      apiKey: 'key',
      custom: false,
      currentSource: () => shortText,
    );
    expect(service2.calls, 0, reason: 'saved checkpoint is reused');
    expect(retry.results['x/summary']!.text, 'result 1 [S1]');
  });
}

class _Service implements AnalysisService {
  int calls = 0;
  int? hangAt;
  final List<String> inputs = [];

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    calls++;
    inputs.add(source);
    if (calls == hangAt) return Completer<String>().future;
    return 'result $calls [S1]';
  }

  @override
  void dispose() {}
}

/// Disk is full exactly when a finished result would be written.
class _ResultWriteFails extends RecordingAnalysis {
  _ResultWriteFails({super.file, super.service});

  @override
  Future<void> save() async {
    if (results.isNotEmpty) throw const FileSystemException('disk full');
    return super.save();
  }
}

Future<void> _settle(bool Function() predicate) async {
  for (var i = 0; i < 200 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue);
}
