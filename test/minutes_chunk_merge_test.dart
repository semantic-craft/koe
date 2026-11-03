import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/recording_analysis.dart';

Map<String, dynamic> _part(String id) => {
  'schemaVersion': 2,
  'title': '合并会议',
  'overview': '逐项保留讨论',
  'topics': [
    {
      'text': '议题$id',
      'sources': [id],
      'summary': '概括$id',
      'points': [
        {
          'text': '要点$id',
          'sources': [id],
        },
      ],
      'fishbone': {
        'question': '原因$id',
        'branches': [
          {
            'text': '因素$id',
            'detail': '解释$id',
            'sources': [id],
          },
        ],
      },
    },
  ],
  'terms': [
    {
      'name': '姓名$id',
      'note': '参会人',
      'heard': ['错名$id'],
      'sources': [id],
    },
  ],
  'decisions': [],
  'actions': [],
  'questions': [],
};

Map<String, dynamic> _legacyPart(String id) => {
  'title': '旧格式会议',
  'overview': '旧格式概括',
  'topics': [
    {
      'text': '旧议题$id',
      'sources': [id],
    },
  ],
  'decisions': [],
  'actions': [],
  'questions': [],
};

class _ResultWriteFails extends RecordingAnalysis {
  _ResultWriteFails({super.file, super.service});
  @override
  Future<void> save() async {
    if (results.isNotEmpty) throw const FileSystemException('disk full');
    return super.save();
  }
}

class _Service implements AnalysisService {
  bool legacyLeaf = false;
  bool legacyMerge = false;
  bool invalidLeaf = false;
  bool foreignLeaf = false;
  final List<List<String>> mergedTopics = [];
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    if (source.startsWith('[S')) {
      final id = RegExp(r'^\[(S\d+)\]').firstMatch(source)!.group(1)!;
      if (legacyLeaf) return jsonEncode(_legacyPart(id));
      if (invalidLeaf && id == 'S1') return '{}';
      if (foreignLeaf && id == 'S1') return jsonEncode(_part('S2'));
      return jsonEncode(_part(id));
    }
    if (legacyMerge) return jsonEncode(_legacyPart('S1'));
    // Each valid intermediate object stays a complete JSON object. Decode
    // concatenated objects without relying on request text or node counts.
    final documents = <Map<String, dynamic>>[];
    var depth = 0, start = -1;
    var quoted = false, escaped = false;
    for (var i = 0; i < source.length; i++) {
      final c = source[i];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          quoted = false;
        }
        continue;
      }
      if (c == '"') {
        quoted = true;
        continue;
      }
      if (c == '{') {
        if (depth == 0) start = i;
        depth++;
      }
      if (c == '}') {
        depth--;
        if (depth == 0 && start >= 0) {
          documents.add(
            Map<String, dynamic>.from(
              jsonDecode(source.substring(start, i + 1)),
            ),
          );
        }
      }
    }
    final result = _part('S1');
    result['topics'] = [
      for (final d in documents) ...((d['topics'] as List?) ?? []),
    ];
    result['terms'] = [
      for (final d in documents) ...((d['terms'] as List?) ?? []),
    ];
    mergedTopics.add([
      for (final t in result['topics'] as List) t['text'] as String,
    ]);
    return jsonEncode(result);
  }

  @override
  void dispose() {}
}

Future<void> _run(RecordingAnalysis manager, List<String> sources) =>
    manager.run(
      recording: 'meeting',
      source: sources.join('\n'),
      apiKey: 'test',
      custom: true,
      instruction: minutesInstruction,
      resultSlot: 'minutes',
      sourceBlocks: sources,
      validateResult: validateMinutes,
      currentSource: () => sources.join('\n'),
    );
void main() {
  for (final stage in ['single', 'leaf', 'merge']) {
    test('reject valid legacy output at $stage minutes node', () async {
      final service = _Service();
      final manager = RecordingAnalysis(inMemory: true, service: service);
      addTearDown(manager.dispose);
      await _run(manager, ['错名S1 旧资料']);
      final previous = manager.results['meeting/minutes'];
      service.legacyLeaf = stage != 'merge';
      service.legacyMerge = stage == 'merge';
      await _run(manager, ['错名S1 新资料', if (stage != 'single') '错名S2 另一段']);
      expect(manager.results['meeting/minutes'], same(previous));
      expect(manager.errors['meeting/minutes'], isNotEmpty);
    });
  }

  test('invalidate legacy checkpoint and regenerate v2 on retry', () async {
    final dir = await Directory.systemTemp.createTemp('minutes-v2-cache');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/analysis.json');
    final first = _ResultWriteFails(file: file, service: _Service());
    addTearDown(first.dispose);
    final sources = ['错名S1 原资料'];
    await _run(first, sources);
    expect(first.results, isEmpty);
    final stored =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final checkpoint = stored['checkpoints']['meeting/minutes'] as Map;
    expect(checkpoint, isNotEmpty);
    for (final id in checkpoint.keys.toList()) {
      checkpoint[id] = jsonEncode(_legacyPart('S1'));
    }
    await file.writeAsString(jsonEncode(stored));
    final retry = RecordingAnalysis(file: file, service: _Service());
    addTearDown(retry.dispose);
    await retry.load();
    await _run(retry, sources);
    expect(retry.results, isEmpty, reason: 'invalid cache is never published');
    expect(retry.errors['meeting/minutes'], isNotEmpty);
    await _run(retry, sources);
    final body = jsonDecode(retry.results['meeting/minutes']!.text) as Map;
    expect(body['schemaVersion'], 2);
    expect(body['topics'][0]['summary'], '概括S1');
  });

  test(
    'four fragments survive two merge levels with nested evidence intact',
    () async {
      final service = _Service();
      final manager = RecordingAnalysis(inMemory: true, service: service);
      addTearDown(manager.dispose);
      final sources = [for (var i = 1; i <= 4; i++) '错名S$i 说明第$i项'];
      await _run(manager, sources);
      final result = manager.results['meeting/minutes']!;
      final body = jsonDecode(result.text) as Map;
      expect((body['topics'] as List).map((t) => t['summary']), [
        '概括S1',
        '概括S2',
        '概括S3',
        '概括S4',
      ]);
      expect((body['terms'] as List).map((t) => t['heard']), [
        ['错名S1'],
        ['错名S2'],
        ['错名S3'],
        ['错名S4'],
      ]);
      expect(service.mergedTopics.last, ['议题S1', '议题S2', '议题S3', '议题S4']);
      expect(result.sources, sources);
    },
  );
  for (final foreign in [false, true]) {
    test(
      'invalid intermediate ${foreign ? 'foreign citation' : 'JSON'} cannot replace completed minutes',
      () async {
        final service = _Service();
        final manager = RecordingAnalysis(inMemory: true, service: service);
        addTearDown(manager.dispose);
        await _run(manager, ['错名S1 旧资料']);
        final previous = manager.results['meeting/minutes'];
        service.invalidLeaf = !foreign;
        service.foreignLeaf = foreign;
        await _run(manager, ['错名S1 新资料', '错名S2 另一段']);
        expect(manager.results['meeting/minutes'], same(previous));
        expect(manager.errors['meeting/minutes'], isNotEmpty);
      },
    );
  }
}
