import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/speaker_distribution.dart';
import 'package:koe/state/transcript_store.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TranscriptSegment seg(
    String text,
    int startSec,
    int endSec, {
    String? speaker,
    bool changed = false,
  }) => TranscriptSegment(
    text: text,
    start: Duration(seconds: startSec),
    end: Duration(seconds: endSec),
    speaker: speaker,
    speakerChanged: changed,
  );

  test(
    '(1) 合并发言人：合并后段落与发言人分布正确，别名保留规则明确（目标已有别名保留目标别名；目标无别名而来源有别名时继承来源别名）',
    () async {
      const path = '/tmp/koe-merge-test.wav';
      final c = RecorderController(
        loadPersistedState: false,
        transcriptPersister: ({bool strict = false}) async {},
      );
      addTearDown(c.dispose);

      c.rememberTranscript(
        path,
        '甲先发言。\n乙接话。\n丙补充。\n乙总结。',
        segments: [
          seg('甲先发言。', 0, 10, speaker: '1', changed: true),
          seg('乙接话。', 10, 25, speaker: '2', changed: true),
          seg('丙补充。', 25, 35, speaker: '3', changed: true),
          seg('乙总结。', 35, 45, speaker: '2', changed: true),
        ],
      );

      // 情况 A：目标（1）已有自定义别名「张总」，来源（2）有别名「李工」 -> 合并 2 到 1 后，1 保留「张总」，2 的别名被清理
      await c.renameTranscriptSpeaker(path, '1', '张总');
      await c.renameTranscriptSpeaker(path, '2', '李工');
      await c.mergeTranscriptSpeakers(
        path,
        fromSpeakerId: '2',
        intoSpeakerId: '1',
      );

      final segmentsAfterA = c.transcriptSegmentsForPath(path);
      expect(segmentsAfterA.map((s) => s.speaker).toList(), ['1', '1', '3', '1']);
      expect(
        segmentsAfterA.map((s) => s.speakerChanged).toList(),
        [true, false, true, true],
      );
      expect(c.speakerAliasesForPath(path), {'1': '张总'});
      expect(
        c.transcriptSpeakersForPath(path).map((s) => s.id).toList(),
        ['1', '3'],
      );
      final distA = buildSpeakerDistribution(
        segmentsAfterA,
        total: const Duration(seconds: 45),
      );
      expect(
        distA.speakers.map((s) => (s.speakerId, s.talk.inSeconds)).toList(),
        [('1', 35), ('3', 10)],
      );

      // 情况 B：目标（3）未设别名（默认「说话人 3」），来源（1）有别名「张总」 -> 合并 1 到 3 后，3 继承「张总」
      await c.mergeTranscriptSpeakers(
        path,
        fromSpeakerId: '1',
        intoSpeakerId: '3',
      );
      expect(
        c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(),
        ['3', '3', '3', '3'],
      );
      expect(c.speakerAliasesForPath(path), {'3': '张总'});
    },
  );

  test(
    '(2) 按「大约几个人」重新区分：文字不变，手动改过归属的段落保持手改值，旧版 TranscriptStore 数据读回兼容',
    () async {
      const path = '/tmp/koe-rediarize-test.wav';
      final diarizer = _RecordingSpeakerDiarizer([
        const DiarizationTurn(
          speaker: 10,
          start: Duration.zero,
          end: Duration(seconds: 10),
        ),
        const DiarizationTurn(
          speaker: 20,
          start: Duration(seconds: 10),
          end: Duration(seconds: 20),
        ),
        const DiarizationTurn(
          speaker: 30,
          start: Duration(seconds: 20),
          end: Duration(seconds: 30),
        ),
      ]);
      final c = RecorderController(
        loadPersistedState: false,
        speakerDiarizer: diarizer,
        rawExportConverter: (p) async => p,
        transcriptPersister: ({bool strict = false}) async {},
      );
      addTearDown(c.dispose);

      const originalText = '第一句内容不变。\n第二句人工确认归属。\n第三句重分给第三人。';
      c.rememberTranscript(
        path,
        originalText,
        segments: [
          seg('第一句内容不变。', 0, 10, speaker: '1', changed: true),
          seg('第二句人工确认归属。', 10, 20, speaker: '1', changed: false),
          seg('第三句重分给第三人。', 20, 30, speaker: '2', changed: true),
        ],
      );

      // 手动把第 1 段（index = 1）改为说话人 '9'
      await c.setSegmentSpeaker(path, 1, '9');
      expect(c.transcriptSegmentsForPath(path)[1].speaker, '9');

      // 按「大约 3 个人」重新区分发言人
      await c.rediarizeSpeakers(path, expectedSpeakers: 3);

      expect(diarizer.lastExpectedSpeakers, 3);
      expect(c.expectedSpeakersForPath(path), 3);
      // 逐字稿文字与每段文字完全不变
      expect(c.transcriptForPath(path), originalText);
      final updated = c.transcriptSegmentsForPath(path);
      expect(
        updated.map((s) => s.text).toList(),
        ['第一句内容不变。', '第二句人工确认归属。', '第三句重分给第三人。'],
      );
      // 未手改的第 0、2 段按新 turn 更新为 '1'、'3'，手改过的第 1 段保持 '9'
      expect(updated.map((s) => s.speaker).toList(), ['1', '9', '3']);

      // 旧格式 JSON（缺 expectedSpeakersByKey / diarizationQualityByKey / speakerUndoByKey）读回兼容
      final legacyDecoded = TranscriptStore.decode({
        'version': 4,
        'byPath': {path: originalText},
        'byFileId': const <String, Object?>{},
        'aliasesByPath': const <String, Object?>{},
        'aliasesByFileId': const <String, Object?>{},
        'metadata': const <String, Object?>{},
        'translations': const <String, Object?>{},
        'segments': {
          'path:$path': [
            seg('第一句内容不变。', 0, 10, speaker: '1', changed: true).toJson(),
            seg('第二句人工确认归属。', 10, 20, speaker: '2', changed: true).toJson(),
          ],
        },
        'manualByKey': const <String, Object?>{},
        'incomingByKey': const <String, Object?>{},
        'segmentSpeakersByKey': {
          'path:$path': {'1': '9'},
        },
      });
      expect(legacyDecoded.segmentSpeakersByKey['path:$path'], {1: '9'});
    },
  );

  test(
    '(3) 复原：合并发言人或按人数重新区分后，均能复原到前一状态',
    () async {
      const path = '/tmp/koe-undo-test.wav';
      final c = RecorderController(
        loadPersistedState: false,
        transcriptPersister: ({bool strict = false}) async {},
      );
      addTearDown(c.dispose);

      c.rememberTranscript(
        path,
        '甲第一句。\n乙第二句。\n丙第三句。',
        segments: [
          seg('甲第一句。', 0, 10, speaker: '1', changed: true),
          seg('乙第二句。', 10, 20, speaker: '2', changed: true),
          seg('丙第三句。', 20, 30, speaker: '3', changed: true),
        ],
      );
      await c.renameTranscriptSpeaker(path, '2', '王五');
      await c.setSegmentSpeaker(path, 2, '2');

      // 1) 合并发言人 2 -> 1，然后复原
      expect(c.canUndoSpeakerEdit(path), isFalse);
      await c.mergeTranscriptSpeakers(
        path,
        fromSpeakerId: '2',
        intoSpeakerId: '1',
      );
      expect(c.canUndoSpeakerEdit(path), isTrue);
      expect(
        c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(),
        ['1', '1', '1'],
      );

      expect(await c.undoSpeakerEdit(path), isTrue);
      expect(c.canUndoSpeakerEdit(path), isFalse);
      expect(
        c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(),
        ['1', '2', '2'],
      );
      expect(c.speakerAliasesForPath(path), {'2': '王五'});

      // 2) 重新区分发言人，然后复原
      await c.rediarizeSpeakers(
        path,
        expectedSpeakers: 2,
        turnsOverride: const [
          DiarizationTurn(
            speaker: 1,
            start: Duration.zero,
            end: Duration(seconds: 20),
          ),
          DiarizationTurn(
            speaker: 2,
            start: Duration(seconds: 20),
            end: Duration(seconds: 30),
          ),
        ],
      );
      expect(c.canUndoSpeakerEdit(path), isTrue);
      expect(c.expectedSpeakersForPath(path), 2);
      // 第 0、1 段在 turn 1 内都变成 '1'，第 2 段因手动改成 '2' 仍保持 '2'
      expect(
        c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(),
        ['1', '1', '2'],
      );

      expect(await c.undoSpeakerEdit(path), isTrue);
      expect(c.canUndoSpeakerEdit(path), isFalse);
      expect(c.expectedSpeakersForPath(path), isNull);
      expect(
        c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(),
        ['1', '2', '2'],
      );
    },
  );

  testWidgets(
    '(4) 录音详情页：可能并错人时在逐字稿上方显示提示条，支持按人数重新区分与复原',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      late Directory dir;
      late String path;
      late _RecordingSpeakerDiarizer diarizer;
      late RecorderController c;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('koe-speaker-ui-');
        path = '${dir.path}/meeting.wav';
        await File(path).writeAsBytes(wavBytes([1, 2, 3, 4]));

        diarizer = _RecordingSpeakerDiarizer([
          const DiarizationTurn(
            speaker: 1,
            start: Duration.zero,
            end: Duration(seconds: 10),
          ),
          const DiarizationTurn(
            speaker: 2,
            start: Duration(seconds: 10),
            end: Duration(seconds: 20),
          ),
          const DiarizationTurn(
            speaker: 3,
            start: Duration(seconds: 20),
            end: Duration(seconds: 30),
          ),
        ]);

        c = RecorderController(
          loadPersistedState: false,
          speakerDiarizer: diarizer,
          rawExportConverter: (p) async => p,
          localDurationReader: (_) async => const Duration(seconds: 30),
          transcriptPersister: ({bool strict = false}) async {},
        )..exportedPaths = [path];

        c.rememberTranscript(
          path,
          '第一句。\n第二句。\n第三句。',
          segments: [
            seg('第一句。', 0, 10, speaker: '1', changed: true),
            seg('第二句。', 10, 20, speaker: '1', changed: false),
            seg('第三句。', 20, 30, speaker: '1', changed: false),
          ],
        );
        await c.setDiarizationQualityForPath(
          path,
          const DiarizationQuality(chunks: 36, clusters: 1, cohesion: 0.48),
        );
      });
      addTearDown(() => dir.delete(recursive: true));
      addTearDown(c.dispose);
      expect(c.shouldShowSpeakerMergeHint(path), isTrue);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: c,
          child: MaterialApp(
            theme: AppTheme.light,
            home: RecordingDetailScreen(
              reference: RecordingReference(path: path),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 逐字稿上方出现并错人提示条
      expect(
        find.byKey(const ValueKey('speaker-merge-risk-banner')),
        findsOneWidget,
      );

      // 点击「重新区分发言人…」，选择「3 人」开始区分
      await tester.tap(
        find.byKey(const ValueKey('speaker-merge-risk-rediarize')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('expected-speakers-3')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('confirm-rediarize-speakers')),
      );
      await tester.pumpAndSettle();

      expect(diarizer.lastExpectedSpeakers, 3);
      expect(
        c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(),
        ['1', '2', '3'],
      );
      // 选过人数后不再提示并错人
      expect(
        find.byKey(const ValueKey('speaker-merge-risk-banner')),
        findsNothing,
      );
    },
  );
}

class _RecordingSpeakerDiarizer implements SpeakerDiarizer {
  _RecordingSpeakerDiarizer(this.turns);

  final List<DiarizationTurn> turns;
  int? lastExpectedSpeakers;

  @override
  Future<DiarizationResult> diarize(
    String audioPath, {
    int? expectedSpeakers,
    void Function(double progress)? onProgress,
  }) async {
    lastExpectedSpeakers = expectedSpeakers;
    return DiarizationResult(
      turns: turns,
      quality: const DiarizationQuality(
        chunks: 36,
        clusters: 3,
        cohesion: 0.82,
      ),
    );
  }
}
