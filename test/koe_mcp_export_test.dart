import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/material_pack.dart';
import 'package:koe/state/recording.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/recording_library.dart';

const _sources = [
  '主持人：决定先做指定导出目录的只读接入，不支持原音频和写回。',
  '小林：我提议本周五上线。',
  '主持人：不采纳周五上线的日期，完成测试后再决定上线时间。',
  '小林：我负责兼容性测试，本周四前完成。',
  '主持人：还需要核对导出字段，这件事尚未分配负责人，也没有期限。',
  '小林：本地模型选择还没有决定。',
  '主持人：以上全部是合成测试内容，不是真实会议记录。',
];

void main() {
  test(
    'production no-audio export is readable through all three MCP tools',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'koe-mcp-export-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final pack = MaterialPack(
        exportedAt: DateTime.utc(2026, 11, 4, 2),
        material: PackMaterial(
          contentHash: analysisFingerprint(
            'synthetic audio identity; no audio exists',
          ),
          title: '合成测试：只读 MCP 试点会议',
          source: RecordingSource.device,
          recordedAt: DateTime.utc(2026, 11, 4, 1),
        ),
        transcript: PackTranscript(
          text: _sources.join('\n'),
          revision: 1,
          segments: [
            for (var index = 0; index < _sources.length; index++)
              TranscriptSegment(
                text: _sources[index],
                start: Duration(seconds: index * 10),
                end: Duration(seconds: index * 10 + 8),
                speaker: index == 1 || index == 3 || index == 5 ? '2' : '1',
              ),
          ],
          speakerAliases: const {'1': '主持人', '2': '小林'},
        ),
        minutes: PackMinutes(
          current: AnalysisResult(
            text: jsonEncode({
              'schemaVersion': 2,
              'title': '合成旧纪要，故意包含错误',
              'overview': '计划周五上线。此句故意错误，须对照原文纠正。',
              'topics': <Object>[],
              'terms': <Object>[],
              'decisions': [
                {
                  'text': '周五上线',
                  'sources': ['S2'],
                },
              ],
              'actions': <Object>[],
              'questions': <Object>[],
            }),
            sourceHash: analysisFingerprint(_sources.join('\n')),
            model: 'synthetic-fixture-no-model-called',
            instruction: '合成旧纪要，保留错误用于逐字稿对照',
            sources: _sources,
            createdAt: DateTime.utc(2026, 11, 4, 1, 30),
            templateId: 'meeting',
            templateVersion: 2,
          ),
        ),
      );
      // Exercise the production format validator as well as its writer.
      final validated = MaterialPack.fromJson(pack.toJson());
      final file = File('${directory.path}/synthetic-meeting.koepack');
      await writeMaterialPack(validated, file);
      final process = await Process.run('python3', [
        '-B',
        'tools/koe-mcp/test_server.py',
        '--probe',
        directory.path,
      ]).timeout(const Duration(seconds: 30));
      expect(process.exitCode, 0, reason: '${process.stderr}');
      final result = jsonDecode(process.stdout as String) as Map;
      expect(result['tools'], [
        'list_recordings',
        'get_transcript',
        'get_minutes',
      ]);
      expect(result['rejectedCount'], 0);
      final recording = (result['recordings'] as List).single as Map;
      final transcript = recording['transcript'] as Map;
      expect(transcript['text'], _sources.join('\n'));
      expect(transcript['timingReliable'], isTrue);
      expect((transcript['sources'] as List)[3]['speaker'], '小林');
      expect((transcript['sources'] as List)[3]['startMs'], 30000);
      final minutes = recording['minutes'] as Map;
      expect(minutes['hasMinutes'], isTrue);
      expect(minutes['freshness'], 'unverified');
      expect(minutes['current']['sources'], _sources);
      expect(minutes['current']['text'], contains('周五上线'));
      final evidence = Platform.environment['KOE_MCP_EVIDENCE_DIR'];
      if (evidence != null && evidence.isNotEmpty) {
        final target = Directory(evidence);
        await target.create(recursive: true);
        await file.copy('${target.path}/synthetic-meeting.koepack');
        await File(
          '${target.path}/protocol-output.json',
        ).writeAsString(process.stdout as String);
      }
    },
  );
}
