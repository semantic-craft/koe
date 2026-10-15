import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recording_analysis.dart';

class FakeAnalysis implements AnalysisService {
  int calls = 0;
  int? failAt;
  Completer<String>? wait;
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
    if (calls == failAt) throw StateError('offline');
    if (wait != null) return wait!.future;
    return 'result $calls [S1]';
  }

  @override
  void dispose() {}
}

void main() {
  test('source splitting retains all characters and supplementary unicode', () {
    final text = List.filled(7001, '一🙂\n').join();
    final blocks = analysisSourceBlocks(text);
    expect(blocks.join(), text);
    expect(blocks.every((b) => b.runes.length <= 6000), isTrue);
  });
  test(
    'summary and custom analysis persist independently without credentials',
    () async {
      final dir = await Directory.systemTemp.createTemp('analysis');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/analysis.json');
      final service = FakeAnalysis();
      final manager = RecordingAnalysis(file: file, service: service);
      addTearDown(manager.dispose);
      await manager.run(
        recording: 'file:1',
        source: 'hello',
        apiKey: 'secret-example',
        custom: false,
        currentSource: () => 'hello',
      );
      await manager.run(
        recording: 'file:1',
        source: 'hello',
        apiKey: 'secret-example',
        custom: true,
        instruction: '提取待办',
        currentSource: () => 'hello',
      );
      expect(manager.results.length, 2);
      expect(await file.readAsString(), isNot(contains('secret-example')));
      final reloaded = RecordingAnalysis(file: file, service: FakeAnalysis());
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.results.length, 2);
      expect(reloaded.results['file:1/analysis']!.instruction, '提取待办');
      expect(
        reloaded.results['file:1/summary']!.exportText,
        contains('[S1] hello'),
      );
    },
  );
  test(
    'changed source and cancelled requests cannot overwrite prior result',
    () async {
      final service = FakeAnalysis();
      final manager = RecordingAnalysis(inMemory: true, service: service);
      addTearDown(manager.dispose);
      var source = 'old';
      await manager.run(
        recording: 'x',
        source: source,
        apiKey: 'key',
        custom: false,
        currentSource: () => source,
      );
      final old = manager.results['x/summary'];
      source = 'new';
      service.wait = Completer<String>();
      final job = manager.run(
        recording: 'x',
        source: source,
        apiKey: 'key',
        custom: false,
        currentSource: () => source,
      );
      await Future<void>.delayed(Duration.zero);
      manager.cancel('x/summary');
      service.wait!.complete('late text');
      await job;
      expect(manager.results['x/summary'], same(old));
      source = 'third';
      service.wait = Completer<String>();
      final changed = manager.run(
        recording: 'x',
        source: source,
        apiKey: 'key',
        custom: false,
        currentSource: () => source,
      );
      await Future<void>.delayed(Duration.zero);
      source = 'fourth';
      service.wait!.complete('stale text');
      await changed;
      expect(manager.results['x/summary'], same(old));
    },
  );
  test(
    'interrupted long text resumes completed segments without pretending success',
    () async {
      final dir = await Directory.systemTemp.createTemp('analysis-resume');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/analysis.json');
      final service = FakeAnalysis()..failAt = 2;
      final manager = RecordingAnalysis(file: file, service: service);
      final text = List.filled(13000, '文').join();
      await manager.run(
        recording: 'x',
        source: text,
        apiKey: 'key',
        custom: false,
        currentSource: () => text,
      );
      expect(manager.results, isEmpty);
      expect(manager.errors, isNotEmpty);
      manager.dispose();
      final resumedService = FakeAnalysis();
      final resumed = RecordingAnalysis(file: file, service: resumedService);
      addTearDown(resumed.dispose);
      await resumed.run(
        recording: 'x',
        source: text,
        apiKey: 'key',
        custom: false,
        currentSource: () => text,
      );
      expect(resumedService.inputs.first, startsWith('[S2]'));
      expect(resumed.results['x/summary']!.sources.join(), text);
    },
  );
}
