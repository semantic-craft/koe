import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/speaker_distribution.dart';
import 'package:koe/state/transcript_store.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:provider/provider.dart';

import 'support/scripted_speaker_diarizer.dart';
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
      expect(segmentsAfterA.map((s) => s.speaker).toList(), [
        '1',
        '1',
        '3',
        '1',
      ]);
      expect(segmentsAfterA.map((s) => s.speakerChanged).toList(), [
        true,
        false,
        true,
        true,
      ]);
      expect(c.speakerAliasesForPath(path), {'1': '张总'});
      expect(c.transcriptSpeakersForPath(path).map((s) => s.id).toList(), [
        '1',
        '3',
      ]);
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
      expect(c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(), [
        '3',
        '3',
        '3',
        '3',
      ]);
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
      expect(updated.map((s) => s.text).toList(), [
        '第一句内容不变。',
        '第二句人工确认归属。',
        '第三句重分给第三人。',
      ]);
      // 未手改的第 0、2 段新分群都只有原来的 '1'、'2'，沿用原编号；手改过的第 1 段保持 '9'
      expect(updated.map((s) => s.speaker).toList(), ['1', '9', '2']);

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

  test('(2b) 重新区分后，取过的名字跟着人走：新发言人的话大部分原来是同一个名字，就沿用这个名字（拾音 R22.2）', () async {
    const path = '/tmp/koe-rediarize-names-test.wav';
    final c = RecorderController(
      loadPersistedState: false,
      transcriptPersister: ({bool strict = false}) async {},
    );
    addTearDown(c.dispose);

    // 第一次区分把王五的开场并进了张总（1）。
    c.rememberTranscript(
      path,
      '王五开场。\n李工汇报。\n张总提问。\n李工回答。\n张总总结。',
      segments: [
        seg('王五开场。', 0, 6, speaker: '1', changed: true),
        seg('李工汇报。', 6, 16, speaker: '2', changed: true),
        seg('张总提问。', 16, 30, speaker: '1', changed: true),
        seg('李工回答。', 30, 40, speaker: '2', changed: true),
        seg('张总总结。', 40, 52, speaker: '1', changed: true),
      ],
    );
    await c.renameTranscriptSpeaker(path, '1', '张总');
    await c.renameTranscriptSpeaker(path, '2', '李工');

    // 按「大约 3 人」重新区分：王五、李工、张总各成一群，王五最先说话。
    await c.rediarizeSpeakers(
      path,
      expectedSpeakers: 3,
      turnsOverride: const [
        DiarizationTurn(
          speaker: 0,
          start: Duration.zero,
          end: Duration(seconds: 6),
        ),
        DiarizationTurn(
          speaker: 1,
          start: Duration(seconds: 6),
          end: Duration(seconds: 16),
        ),
        DiarizationTurn(
          speaker: 2,
          start: Duration(seconds: 16),
          end: Duration(seconds: 30),
        ),
        DiarizationTurn(
          speaker: 1,
          start: Duration(seconds: 30),
          end: Duration(seconds: 40),
        ),
        DiarizationTurn(
          speaker: 2,
          start: Duration(seconds: 40),
          end: Duration(seconds: 52),
        ),
      ],
    );

    final labels = {
      for (final s in c.transcriptSpeakersForPath(path)) s.id: s.displayLabel,
    };
    expect(
      [for (final s in c.transcriptSegmentsForPath(path)) labels[s.speaker]],
      ['说话人 3', '李工', '张总', '李工', '张总'],
    );
  });

  test('(3) 复原：合并发言人或按人数重新区分后，均能复原到前一状态', () async {
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
    expect(c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(), [
      '1',
      '1',
      '1',
    ]);

    expect(await c.undoSpeakerEdit(path), isTrue);
    expect(c.canUndoSpeakerEdit(path), isFalse);
    expect(c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(), [
      '1',
      '2',
      '2',
    ]);
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
    expect(c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(), [
      '1',
      '1',
      '2',
    ]);

    expect(await c.undoSpeakerEdit(path), isTrue);
    expect(c.canUndoSpeakerEdit(path), isFalse);
    expect(c.expectedSpeakersForPath(path), isNull);
    expect(c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(), [
      '1',
      '2',
      '2',
    ]);
  });

  test('重新区分期间文字换了：迟到的结果不覆盖新文字，同时也不能再区分一次', () async {
    const path = '/tmp/koe-rediarize-race-test.wav';
    final diarizer = ScriptedSpeakerDiarizer([
      [
        const DiarizationTurn(
          speaker: 0,
          start: Duration.zero,
          end: Duration(seconds: 10),
        ),
        const DiarizationTurn(
          speaker: 1,
          start: Duration(seconds: 10),
          end: Duration(seconds: 30),
        ),
      ],
    ])..gate = Completer<void>();
    final c = RecorderController(
      loadPersistedState: false,
      speakerDiarizer: diarizer,
      rawExportConverter: (p) async => p,
      transcriptPersister: ({bool strict = false}) async {},
    );
    addTearDown(c.dispose);
    addTearDown(() {
      if (!diarizer.gate!.isCompleted) diarizer.gate!.complete();
    });
    c.rememberTranscript(
      path,
      '甲。\n乙。\n丙。',
      segments: [
        seg('甲。', 0, 10, speaker: '1', changed: true),
        seg('乙。', 10, 20, speaker: '1'),
        seg('丙。', 20, 30, speaker: '1'),
      ],
    );

    Future<Object?> outcome(Future<void> run) =>
        run.then<Object?>((_) => null, onError: (Object error) => error);
    final first = outcome(c.rediarizeSpeakers(path, expectedSpeakers: 2));
    await until(() => diarizer.calls == 1);
    final second = outcome(c.rediarizeSpeakers(path, expectedSpeakers: 3));
    c.rememberTranscript(
      path,
      '新的一句。\n又一句。',
      segments: [
        seg('新的一句。', 0, 15, speaker: '1', changed: true),
        seg('又一句。', 15, 30, speaker: '2', changed: true),
      ],
    );
    diarizer.gate!.complete();

    expect(await second, isA<StateError>());
    expect(await first, isA<StateError>());
    expect(diarizer.calls, 1);
    expect(c.transcriptSegmentsForPath(path).map((s) => (s.text, s.speaker)), [
      ('新的一句。', '1'),
      ('又一句。', '2'),
    ]);
    expect(c.canUndoSpeakerEdit(path), isFalse);
  });

  test('区分不出任何发言人时，重新区分不清掉原有的发言人', () async {
    const path = '/tmp/koe-rediarize-empty-test.wav';
    final c = RecorderController(
      loadPersistedState: false,
      speakerDiarizer: ScriptedSpeakerDiarizer([const []]),
      rawExportConverter: (p) async => p,
      transcriptPersister: ({bool strict = false}) async {},
    );
    addTearDown(c.dispose);
    c.rememberTranscript(
      path,
      '甲。\n乙。',
      segments: [
        seg('甲。', 0, 10, speaker: '1', changed: true),
        seg('乙。', 10, 20, speaker: '2', changed: true),
      ],
    );

    await expectLater(
      c.rediarizeSpeakers(path, expectedSpeakers: 2),
      throwsStateError,
    );
    expect(c.transcriptSegmentsForPath(path).map((s) => s.speaker), ['1', '2']);
    expect(c.canUndoSpeakerEdit(path), isFalse);
  });

  test('重新区分带「说话人 N：」前缀的云端逐字稿时，正文前缀跟着改', () async {
    const path = '/tmp/koe-rediarize-cloud-test.wav';
    final c = RecorderController(
      loadPersistedState: false,
      speakerDiarizer: ScriptedSpeakerDiarizer([
        const [
          DiarizationTurn(
            speaker: 0,
            start: Duration.zero,
            end: Duration(seconds: 10),
          ),
          DiarizationTurn(
            speaker: 1,
            start: Duration(seconds: 10),
            end: Duration(seconds: 20),
          ),
          DiarizationTurn(
            speaker: 0,
            start: Duration(seconds: 20),
            end: Duration(seconds: 30),
          ),
        ],
      ]),
      rawExportConverter: (p) async => p,
      transcriptPersister: ({bool strict = false}) async {},
    );
    addTearDown(c.dispose);
    c.rememberTranscript(
      path,
      '说话人 1：甲。\n说话人 2：乙。\n丙。',
      provider: SttProvider.doubao,
      segments: [
        seg('甲。', 0, 10, speaker: '1', changed: true),
        seg('乙。', 10, 20, speaker: '2', changed: true),
        seg('丙。', 20, 30, speaker: '2'),
      ],
    );

    await c.rediarizeSpeakers(path, expectedSpeakers: 2);

    expect(c.transcriptForPath(path), '说话人 1：甲。\n说话人 2：乙。\n说话人 1：丙。');
    expect(await c.undoSpeakerEdit(path), isTrue);
    expect(c.transcriptForPath(path), '说话人 1：甲。\n说话人 2：乙。\n丙。');
  });

  test('合并发言人时，用户改过的正文也一起合并', () async {
    const path = '/tmp/koe-merge-edited-test.wav';
    final c = RecorderController(
      loadPersistedState: false,
      transcriptPersister: ({bool strict = false}) async {},
    );
    addTearDown(c.dispose);
    c.rememberTranscript(
      path,
      '说话人 1：甲开场。\n说话人 2：乙汇报。',
      provider: SttProvider.doubao,
      segments: [
        seg('甲开场。', 0, 10, speaker: '1', changed: true),
        seg('乙汇报。', 10, 20, speaker: '2', changed: true),
      ],
    );
    await c.renameTranscriptSpeaker(path, '2', '李工');
    await c.saveManualTranscript(path, '说话人 1：甲开场了。\n说话人 2：乙汇报。');

    await c.mergeTranscriptSpeakers(
      path,
      fromSpeakerId: '2',
      intoSpeakerId: '1',
    );

    expect(c.transcriptForPath(path), '李工：甲开场了。\n李工：乙汇报。');
    expect(c.transcriptSpeakersForPath(path).map((s) => s.id), ['1']);
    expect(await c.undoSpeakerEdit(path), isTrue);
    expect(c.transcriptForPath(path), '说话人 1：甲开场了。\n李工：乙汇报。');
  });

  test('合并之后又改了名字或换了正文，就不再提供复原到合并前', () async {
    const path = '/tmp/koe-undo-stale-test.wav';
    final c = RecorderController(
      loadPersistedState: false,
      transcriptPersister: ({bool strict = false}) async {},
    );
    addTearDown(c.dispose);
    void remember(String text) => c.rememberTranscript(
      path,
      text,
      provider: SttProvider.doubao,
      segments: [
        seg('甲。', 0, 10, speaker: '1', changed: true),
        seg('乙。', 10, 20, speaker: '2', changed: true),
      ],
    );
    remember('说话人 1：甲。\n说话人 2：乙。');

    await c.mergeTranscriptSpeakers(
      path,
      fromSpeakerId: '2',
      intoSpeakerId: '1',
    );
    await c.renameTranscriptSpeaker(path, '1', '张总');
    expect(c.canUndoSpeakerEdit(path), isFalse);

    remember('说话人 1：甲。\n说话人 2：乙。');
    await c.saveManualTranscript(path, '说话人 1：甲改过。\n说话人 2：乙。');
    await c.mergeTranscriptSpeakers(
      path,
      fromSpeakerId: '2',
      intoSpeakerId: '1',
    );
    // A newer provider text arrives under the manual edit and is adopted.
    remember('说话人 1：甲的新版本。\n说话人 2：乙。');
    await c.adoptIncomingTranscript(path);
    expect(c.canUndoSpeakerEdit(path), isFalse);
    expect(c.transcriptForPath(path), '说话人 1：甲的新版本。\n说话人 2：乙。');
  });

  test('保存失败时合并、重新区分和复原都退回原状态', () async {
    const path = '/tmp/koe-speaker-save-failure-test.wav';
    var failStrict = false;
    final c = RecorderController(
      loadPersistedState: false,
      speakerDiarizer: ScriptedSpeakerDiarizer([
        const [
          DiarizationTurn(
            speaker: 0,
            start: Duration.zero,
            end: Duration(seconds: 30),
          ),
        ],
      ]),
      rawExportConverter: (p) async => p,
      transcriptPersister: ({bool strict = false}) async {
        if (strict && failStrict) {
          throw const FileSystemException('磁盘已满');
        }
      },
    );
    addTearDown(c.dispose);
    c.rememberTranscript(
      path,
      '说话人 1：甲。\n说话人 2：乙。\n说话人 3：丙。',
      provider: SttProvider.doubao,
      segments: [
        seg('甲。', 0, 10, speaker: '1', changed: true),
        seg('乙。', 10, 20, speaker: '2', changed: true),
        seg('丙。', 20, 30, speaker: '3', changed: true),
      ],
    );
    await c.renameTranscriptSpeaker(path, '2', '李工');
    List<String?> speakers() =>
        c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList();

    failStrict = true;
    await expectLater(
      c.mergeTranscriptSpeakers(path, fromSpeakerId: '2', intoSpeakerId: '1'),
      throwsA(isA<FileSystemException>()),
    );
    expect(speakers(), ['1', '2', '3']);
    expect(c.speakerAliasesForPath(path), {'2': '李工'});
    expect(c.transcriptForPath(path), '说话人 1：甲。\n李工：乙。\n说话人 3：丙。');
    expect(c.canUndoSpeakerEdit(path), isFalse);

    await expectLater(
      c.rediarizeSpeakers(path, expectedSpeakers: 1),
      throwsA(isA<FileSystemException>()),
    );
    expect(speakers(), ['1', '2', '3']);
    expect(c.expectedSpeakersForPath(path), isNull);
    expect(c.canUndoSpeakerEdit(path), isFalse);

    failStrict = false;
    await c.mergeTranscriptSpeakers(
      path,
      fromSpeakerId: '3',
      intoSpeakerId: '1',
    );
    failStrict = true;
    await expectLater(
      c.undoSpeakerEdit(path),
      throwsA(isA<FileSystemException>()),
    );
    expect(speakers(), ['1', '2', '1']);
    expect(c.canUndoSpeakerEdit(path), isTrue);
  });

  testWidgets('(4) 录音详情页：可能并错人时在逐字稿上方显示提示条，支持按人数重新区分与复原', (tester) async {
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
    await tester.tap(find.byKey(const ValueKey('confirm-rediarize-speakers')));
    await tester.pumpAndSettle();

    expect(diarizer.lastExpectedSpeakers, 3);
    expect(c.transcriptSegmentsForPath(path).map((s) => s.speaker).toList(), [
      '1',
      '2',
      '3',
    ]);
    // 选过人数后不再提示并错人
    expect(
      find.byKey(const ValueKey('speaker-merge-risk-banner')),
      findsNothing,
    );
  });

  testWidgets('还没标出发言人的本机逐字稿，也能从「更多操作」区分发言人', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory dir;
    late String path;
    late RecorderController c;
    final diarizer = ScriptedSpeakerDiarizer([
      const [
        DiarizationTurn(
          speaker: 0,
          start: Duration.zero,
          end: Duration(seconds: 10),
        ),
        DiarizationTurn(
          speaker: 1,
          start: Duration(seconds: 10),
          end: Duration(seconds: 20),
        ),
      ],
    ]);
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('koe-speaker-ui-');
      path = '${dir.path}/meeting.wav';
      await File(path).writeAsBytes(wavBytes([1, 2, 3, 4]));
      c = RecorderController(
        loadPersistedState: false,
        speakerDiarizer: diarizer,
        rawExportConverter: (p) async => p,
        localDurationReader: (_) async => const Duration(seconds: 20),
        transcriptPersister: ({bool strict = false}) async {},
      )..exportedPaths = [path];
      c.rememberTranscript(
        path,
        '第一句。\n第二句。',
        provider: SttProvider.apple,
        segments: [seg('第一句。', 0, 10), seg('第二句。', 10, 20)],
      );
    });
    addTearDown(() => dir.delete(recursive: true));
    addTearDown(c.dispose);

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
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('区分发言人…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-rediarize-speakers')));
    await tester.pumpAndSettle();

    expect(diarizer.calls, 1);
    expect(c.transcriptSegmentsForPath(path).map((s) => s.speaker), ['1', '2']);
  });
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
