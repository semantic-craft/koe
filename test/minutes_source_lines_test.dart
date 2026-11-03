import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/recording.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/transcript_chapters.dart';

class _EvidenceService implements AnalysisService {
  final requests = <String>[];

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    requests.add(source);
    final ids = source.startsWith('[S')
        ? RegExp(
            r'^\[(S\d+)\]',
            multiLine: true,
          ).allMatches(source).map((m) => m[1]!).toList()
        : RegExp(
            r'"sources":\["(S\d+)"\]',
          ).allMatches(source).map((m) => m[1]!).toSet().toList();
    return jsonEncode({
      'schemaVersion': 2,
      'title': '来源验证',
      'overview': '保留每条原文的出处',
      'topics': [
        for (final id in ids)
          {
            'text': id,
            'summary': id,
            'points': [],
            'sources': [id],
          },
      ],
      'terms': [],
      'decisions': [],
      'actions': [],
      'questions': [],
    });
  }

  @override
  void dispose() {}
}

class _PublicationFails extends RecordingAnalysis {
  _PublicationFails({required super.file, required super.service});

  @override
  Future<void> save() async {
    if (results.isNotEmpty) throw const FileSystemException('disk full');
    await super.save();
  }
}

Future<void> _run(RecordingAnalysis manager, String text) => manager.run(
  recording: 'meeting',
  source: text,
  apiKey: 'test',
  custom: true,
  instruction: minutesInstruction,
  resultSlot: 'minutes',
  validateResult: validateMinutes,
  currentSource: () => text,
);

void main() {
  test(
    'short minutes retain later spoken evidence in one paid request',
    () async {
      final service = _EvidenceService();
      final manager = RecordingAnalysis(inMemory: true, service: service);
      addTearDown(manager.dispose);
      const lines = [
        '这是一个测试说话人日志的音频。',
        '下面我们来播放一些测试音频。',
        '非常累的时候，就会站在阳台上吹吹风，看远处的灯火。',
        '明明暗暗和你们一起走过很多很多的路，坚持到底。',
        '我们下面播放一条雷军的测试音频。',
        '这是我第4次办年度演讲。',
        '今天呢，我就先和大家聊聊五大往事。',
        '我没有停下对非凡的追求。',
        '这个就是所有的测试音频。',
      ];
      const seconds = [0, 4, 7, 12, 22, 27, 33, 48, 52];
      final segments = [
        for (var i = 0; i < lines.length; i++)
          TranscriptSegment(
            text: lines[i],
            start: Duration(seconds: seconds[i]),
            end: Duration(seconds: i + 1 < lines.length ? seconds[i + 1] : 56),
          ),
      ];
      const speakers = ['0', null, '1', '2', '0', '2', null, null, '0'];
      final transcriptLines = [
        for (var i = 0; i < lines.length; i++)
          '${speakers[i] == null ? '' : '说话人 ${speakers[i]}：'}${lines[i]}',
      ];
      final text = transcriptLines.join('\n');
      await _run(manager, text);
      final result = manager.results['meeting/minutes']!;
      expect(result.sources.map((s) => s.trim()), transcriptLines);
      expect(result.sources.join(), text);
      final matches = matchTranscriptSources(
        sources: result.sources,
        segments: segments,
        duration: const Duration(seconds: 56),
      );
      expect(
        matches.singleWhere((m) => m.sourceIndex == 4).start,
        const Duration(seconds: 22),
      );
      expect(
        matches.singleWhere((m) => m.sourceIndex == 5).start,
        const Duration(seconds: 27),
      );
      expect(
        service.requests,
        hasLength(1),
        reason: 'line citations must not multiply paid requests',
      );
      expect(service.requests.single, contains('[S6] 说话人 2：这是我第4次办年度演讲。'));
    },
  );

  test(
    'long minutes batch line citations without losing global source ids',
    () async {
      final service = _EvidenceService();
      final manager = RecordingAnalysis(inMemory: true, service: service);
      addTearDown(manager.dispose);
      final text = [
        for (var i = 0; i < 12; i++) '第$i段 ${'长文🙂' * 300}',
      ].join('\n\n');
      await _run(manager, text);
      final result = manager.results['meeting/minutes']!;
      expect(result.sources, hasLength(12));
      expect(result.sources.join(), text);
      final minutes = MeetingMinutes.parse(result.text, result.sources.length);
      expect(minutes.topics.expand((t) => t.sources), [
        for (var i = 1; i <= 12; i++) 'S$i',
      ]);
      final sourceRequests = service.requests
          .where((r) => r.startsWith('[S'))
          .toList();
      expect(sourceRequests.length, lessThan(12));
      expect(sourceRequests.every((r) => r.runes.length <= 6100), isTrue);
    },
  );

  test(
    'changed source layout cannot reuse a completed old checkpoint',
    () async {
      final dir = await Directory.systemTemp.createTemp('minute-source-layout');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/analysis.json');
      final service = _EvidenceService();
      final first = _PublicationFails(file: file, service: service);
      addTearDown(first.dispose);
      const text = '先讨论预算。\n然后决定下周再评估。';
      await first.run(
        recording: 'meeting',
        source: text,
        apiKey: 'test',
        custom: true,
        instruction: minutesInstruction,
        resultSlot: 'minutes',
        sourceBlocks: const [text],
        validateResult: validateMinutes,
        currentSource: () => text,
      );
      expect(first.results, isEmpty);
      final next = RecordingAnalysis(file: file, service: service);
      addTearDown(next.dispose);
      await _run(next, text);
      final result = next.results['meeting/minutes']!;
      expect(result.sources, hasLength(2));
      final minutes = MeetingMinutes.parse(result.text, result.sources.length);
      expect(minutes.topics.expand((t) => t.sources), ['S1', 'S2']);
    },
  );
}
