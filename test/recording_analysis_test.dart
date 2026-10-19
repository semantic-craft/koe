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
  test(
    'template library persists custom templates across upgrade, protects built-ins, '
    'and marks results stale on template edit without auto re-running',
    () async {
      final dir = await Directory.systemTemp.createTemp('analysis-templates');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/analysis.json');
      final legacySummaryHash = analysisFingerprint('hello');
      final legacyLongText = List.filled(13000, '文').join();
      final legacyLongHash = analysisFingerprint(legacyLongText);
      final legacyJobHash = analysisFingerprint(
        '$legacyLongHash/qwen3.8-flash/$defaultSummaryPrompt/v1',
      );
      await file.writeAsString('''
{
  "version": 1,
  "model": "qwen3.8-flash",
  "results": {
    "file:1/summary": {
      "text": "旧摘要 [S1]",
      "sourceHash": "$legacySummaryHash",
      "model": "qwen3.8-flash",
      "provider": "qwen",
      "instruction": "$defaultSummaryPrompt",
      "sources": ["hello"],
      "createdAt": "2026-10-16T00:00:00.000Z",
      "editedAt": null,
      "promptVersion": 1
    },
    "file:1/analysis": {
      "text": "旧自定义结果 [S1]",
      "sourceHash": "$legacySummaryHash",
      "model": "qwen3.8-flash",
      "provider": "qwen",
      "instruction": "提取待办",
      "sources": ["hello"],
      "createdAt": "2026-10-16T00:00:00.000Z",
      "editedAt": null,
      "promptVersion": 1
    }
  },
  "checkpoints": {
    "file:2/summary": {
      "片段 1/3": "已付费片段 [S1]"
    }
  },
  "jobHashes": {
    "file:2/summary": "$legacyJobHash"
  },
  "pending": ["file:2/summary"],
  "errors": {}
}
''');

      final service = FakeAnalysis();
      final manager = RecordingAnalysis(file: file, service: service);
      addTearDown(manager.dispose);
      await manager.load();

      // Built-in templates are lookup-accessible by id for #51 and minutes.
      expect(
        manager.requireTemplate(summaryTemplateId).prompt,
        defaultSummaryPrompt,
      );
      expect(manager.requireTemplate(minutesTemplateId).builtIn, isTrue);
      expect(manager.requireTemplate(bookNoteTemplateId).builtIn, isTrue);
      expect(manager.requireTemplate(thinkingNoteTemplateId).builtIn, isTrue);
      expect(
        () => manager.deleteTemplate(summaryTemplateId),
        throwsStateError,
      );
      expect(
        () => manager.updateTemplate(
          bookNoteTemplateId,
          name: '改名',
          prompt: '新正文',
        ),
        throwsStateError,
      );

      // Existing results, custom instruction, and interrupted job checkpoints survive upgrade.
      expect(manager.results['file:1/summary']!.text, '旧摘要 [S1]');
      expect(
        manager.isStale(manager.results['file:1/summary']!, source: 'hello'),
        isFalse,
      );
      expect(manager.results['file:1/analysis']!.instruction, '提取待办');
      expect(manager.customInstructions['file:1'], '提取待办');
      expect(manager.errors['file:2/summary'], contains('重新计费'));

      // Duplicate built-in template as custom.
      final copied = await manager.duplicateTemplate(bookNoteTemplateId);
      expect(copied.builtIn, isFalse);
      expect(copied.prompt, manager.requireTemplate(bookNoteTemplateId).prompt);

      // Create custom template and run analysis with it.
      final created = await manager.createTemplate(
        name: '行动项模板',
        prompt: '只列出负责人与截止时间',
      );
      await manager.run(
        recording: 'file:1',
        source: 'hello',
        apiKey: 'secret-example',
        templateId: created.id,
        currentSource: () => 'hello',
      );
      expect(service.calls, 1);
      final slot = RecordingAnalysis.keyForTemplate('file:1', created.id);
      final generated = manager.results[slot]!;
      expect(generated.templateId, created.id);
      expect(generated.templateVersion, 1);
      expect(generated.templateFingerprint, created.fingerprint);
      expect(manager.isStale(generated, source: 'hello'), isFalse);

      // Editing the template bumps version & fingerprint, marks old result stale,
      // and never auto-resubmits a paid request.
      final updated = await manager.updateTemplate(
        created.id,
        name: '行动项模板',
        prompt: '只列出负责人、截止时间与阻塞项',
      );
      expect(updated.version, 2);
      expect(updated.fingerprint, isNot(created.fingerprint));
      expect(service.calls, 1);
      expect(manager.results[slot]!.text, generated.text);
      expect(manager.isStale(manager.results[slot]!, source: 'hello'), isTrue);

      // Reload preserves custom templates, results, and upgraded checkpoints.
      final reloadedService = FakeAnalysis();
      final reloaded = RecordingAnalysis(file: file, service: reloadedService);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.requireTemplate(created.id).version, 2);
      expect(reloaded.requireTemplate(copied.id).builtIn, isFalse);
      expect(
        reloaded.isStale(reloaded.results[slot]!, source: 'hello'),
        isTrue,
      );
      await reloaded.run(
        recording: 'file:2',
        source: legacyLongText,
        apiKey: 'secret-example',
        custom: false,
        currentSource: () => legacyLongText,
      );
      expect(reloadedService.inputs.first, startsWith('[S2]'));

      await reloaded.deleteTemplate(copied.id);
      expect(reloaded.templateById(copied.id), isNull);
    },
  );
}
