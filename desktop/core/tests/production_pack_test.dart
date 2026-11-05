import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:koe/state/material_pack.dart';
import 'package:koe/state/recording.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/recording_bookmarks.dart';
import 'package:koe/state/recording_library.dart';
import 'package:koe/state/topic_store.dart';

void main() {
  final binary = File('desktop/target/debug/koe-pack').existsSync()
      ? File('desktop/target/debug/koe-pack').absolute.path
      : File('desktop/core/target/debug/koe-pack').absolute.path;
  for (final version in [1, 2]) {
    for (final included in [false, true]) {
      test('Flutter writer to Rust reader v$version audio=$included', () async {
        final root = await Directory(
          '.scratch/pstack-auto/gpui-migration',
        ).create(recursive: true);
        final temp = await root.createTemp('interop-');
        addTearDown(() => temp.delete(recursive: true));
        final bytes = Uint8List.fromList(List.generate(150000, (i) => i % 251));
        final hash = SHA256Digest()
            .process(bytes)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        final audio = File('${temp.path}/synthetic.wav');
        await audio.writeAsBytes(bytes);
        final now = DateTime.utc(2026, 11, 5);
        const source = '江松说明接口未联调，下周完成。';
        final minutesText = jsonEncode({
          'schemaVersion': 2,
          'title': '联调会议',
          'overview': '讨论联调',
          'topics': [
            {
              'text': '延期',
              'sources': ['S1'],
              'summary': '尚未联调',
              'points': [
                {
                  'text': '下周完成',
                  'sources': ['S1'],
                },
              ],
              'fishbone': {
                'question': '为何延期',
                'branches': [
                  {
                    'text': '接口',
                    'detail': '未联调',
                    'sources': ['S1'],
                  },
                ],
              },
            },
          ],
          'terms': [
            {
              'name': '江充',
              'note': '人名校订',
              'heard': ['江松'],
              'sources': ['S1'],
              'adoption': {
                'kind': 'vocabulary',
                'at': now.toIso8601String(),
                'previousVersion': hash,
              },
            },
          ],
          'decisions': [],
          'actions': [
            {
              'text': '联调',
              'owner': '江充',
              'due': '下周',
              'sources': ['S1'],
            },
          ],
          'questions': [],
          'custom': [
            {
              'title': '补充',
              'items': [
                {
                  'text': '接口',
                  'sources': ['S1'],
                },
              ],
            },
          ],
          'reviewItems': ['确认日期'],
        });
        final current = AnalysisResult(
          text: minutesText,
          sourceHash: hash,
          model: 'synthetic',
          instruction: '会议纪要',
          sources: [source],
          createdAt: now,
          templateId: 'meeting',
          templateVersion: 2,
        );
        final pack = MaterialPack(
          exportedAt: now,
          material: PackMaterial(
            contentHash: hash,
            title: '生产写入器样本',
            source: RecordingSource.phone,
            recordedAt: now,
            audioExtension: '.wav',
            place: RecordingPlace(
              label: '合成地点',
              source: RecordingPlaceSource.manual,
              capturedAt: now,
            ),
          ),
          transcript: PackTranscript(
            text: source,
            manual: version == 2 ? '' : '人工校订',
            segments: const [
              TranscriptSegment(
                text: source,
                start: Duration.zero,
                end: Duration(seconds: 2),
                speaker: '1',
              ),
              TranscriptSegment(
                text: '结尾',
                start: Duration(seconds: 2),
                speaker: '1',
              ),
            ],
            segmentSpeakers: const {0: '2', 1: ''},
            speakerAliases: const {'1': '甲', '2': '乙'},
            revision: 3,
          ),
          bookmarks: [
            PackBookmark(
              RecordingBookmark(
                id: 'bookmark',
                recordingKey: 'synthetic-only',
                position: const Duration(seconds: 1),
                note: '保留书签',
                segmentText: source,
                segmentStart: Duration.zero,
                segmentEnd: const Duration(seconds: 2),
                transcriptRevision: 3,
                audioVersion: hash,
                createdAt: now,
                updatedAt: now,
              ),
            ),
          ],
          topic: const PackTopic(title: '合成主题', kind: TopicKind.general),
          minutes: version == 2
              ? PackMinutes(current: current, history: [current])
              : null,
          audio: included
              ? PackAudio(extension: '.wav', bytes: bytes.length, sha256: hash)
              : null,
        );
        final file = File('${temp.path}/fixture.koepack');
        await writeMaterialPack(
          pack,
          file,
          audioPath: included ? audio.path : null,
        );
        final before = await file.readAsBytes();
        final paths = temp.listSync().map((f) => f.path).toSet();
        final result = await Process.run(binary, ['inspect', file.path]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final output = jsonDecode(result.stdout as String) as Map;
        expect(output['title'], pack.material.title);
        expect(output['text'], version == 2 ? '' : '人工校订');
        expect(output['segments'][0]['speaker'], '乙');
        expect(
          (output['segments'] as List).map((s) => s['speakerChanged']).toList(),
          pack.transcript!.effectiveSegments
              .map((s) => s.speakerChanged)
              .toList(),
        );
        expect(output['segments'][1]['speaker'], isNull);
        expect(output['segments'][1]['endMs'], isNull);
        expect(output['manifest'], pack.toJson());
        expect(output['minutes'], pack.toJson()['minutes']);
        expect(await file.readAsBytes(), before);
        expect(temp.listSync().map((f) => f.path).toSet(), paths);
        if (version == 2) {
          for (final mutation in [
            'future',
            'source',
            'heard',
            'type',
            'history',
          ]) {
            final value = jsonDecode(jsonEncode(pack.toJson())) as Map;
            final result = value['minutes']['current'] as Map;
            final body = jsonDecode(result['text'] as String) as Map;
            switch (mutation) {
              case 'future':
                body['schemaVersion'] = 3;
              case 'source':
                body['topics'][0]['sources'] = ['S2'];
              case 'heard':
                body['terms'][0]['heard'] = ['没有说过'];
              case 'type':
                result['isDraft'] = 'false';
              case 'history':
                value['minutes']['history'] = List.filled(11, result);
            }
            result['text'] = jsonEncode(body);
            final data = utf8.encode(jsonEncode(value));
            await file.writeAsBytes([
              ...utf8.encode('KOEPACK1\n${data.length}\n'),
              ...data,
              if (included) ...bytes,
            ]);
            final rejected = await Process.run(binary, ['inspect', file.path]);
            expect(rejected.exitCode, isNot(0), reason: mutation);
            expect(rejected.stdout, isEmpty);
            expect(rejected.stderr, isNot(contains('panicked')));
          }
        }
      });
    }
  }
}
