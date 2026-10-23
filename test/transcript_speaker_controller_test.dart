import 'dart:io';

import 'package:koe/state/recorder_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'speaker aliases render by path and file id and reset on replacement',
    () async {
      const path = '/tmp/1783917051.wav';
      const raw = '说话人 1：你好\n说话人 2：再见';
      final controller = RecorderController(loadPersistedState: false)
        ..transcriptsByPath[path] = raw
        ..transcriptsByFileId[1783917051] = raw;
      addTearDown(controller.dispose);

      await controller.renameTranscriptSpeaker(path, '1', '张三：');

      expect(controller.transcriptForPath(path), '张三：你好\n说话人 2：再见');
      expect(controller.transcriptForFileId(1783917051), '张三：你好\n说话人 2：再见');
      expect(
        controller.transcriptSpeakersForPath(path).first.displayLabel,
        '张三',
      );

      controller.rememberTranscript(path, '说话人 1：新的结果');
      expect(controller.speakerAliasesByPath, isEmpty);
      expect(controller.speakerAliasesByFileId, isEmpty);
      expect(controller.transcriptForPath(path), '说话人 1：新的结果');
    },
  );

  test(
    'recording rename and deletion migrate then remove speaker aliases',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'anker-recorder-speaker-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/1783917051.wav');
      await source.writeAsBytes([1, 2, 3]);
      final controller = RecorderController(loadPersistedState: false)
        ..exportedPaths = [source.path]
        ..transcriptsByPath[source.path] = '说话人 1：你好'
        ..transcriptsByFileId[1783917051] = '说话人 1：你好'
        ..speakerAliasesByPath[source.path] = {'1': '张三'}
        ..speakerAliasesByFileId[1783917051] = {'1': '张三'};
      addTearDown(controller.dispose);

      final renamed = await controller.renameLocalExport(source.path, '访谈');
      expect(controller.speakerAliasesByPath[source.path], isNull);
      expect(controller.speakerAliasesByPath[renamed], {'1': '张三'});
      expect(controller.transcriptForPath(renamed), '张三：你好');
      await controller.saveManualTranscript(renamed, '人工校订');
      expect(controller.manualTranscriptForPath(renamed), '人工校订');

      final result = await controller.deleteLocalExports([renamed]);
      expect(result.deleted, 1);
      expect(controller.speakerAliasesByPath, isEmpty);
      expect(controller.speakerAliasesByFileId, isEmpty);
      expect(controller.manualTranscriptForPath(renamed), isNull);
      expect(controller.incomingTranscriptForPath(renamed), isNull);
    },
  );

  group('本机录音（按路径记）', () {
    TranscriptSegment seg(String text, int start, int end, String speaker) =>
        TranscriptSegment(
          text: text,
          start: Duration(seconds: start),
          end: Duration(seconds: end),
          speaker: speaker,
          speakerChanged: true,
        );

    Future<(RecorderController, String)> mergedTake() async {
      final directory = await Directory.systemTemp.createTemp(
        'koe-speaker-take-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/phone_1783917051.wav');
      await source.writeAsBytes([1, 2, 3]);
      final controller = RecorderController(
        loadPersistedState: false,
        transcriptPersister: ({bool strict = false}) async {},
      )..exportedPaths = [source.path];
      addTearDown(controller.dispose);
      controller.rememberTranscript(
        source.path,
        '甲。\n乙。\n丙。',
        provider: SttProvider.apple,
        segments: [
          seg('甲。', 0, 10, '1'),
          seg('乙。', 10, 20, '2'),
          seg('丙。', 20, 30, '3'),
        ],
      );
      await controller.saveManualTranscript(source.path, '甲。\n乙改过。\n丙。');
      await controller.mergeTranscriptSpeakers(
        source.path,
        fromSpeakerId: '3',
        intoSpeakerId: '1',
      );
      return (controller, source.path);
    }

    test('改名后，人工校订、段落归属和合并复原都跟到新名字下', () async {
      final (controller, path) = await mergedTake();

      final renamed = await controller.renameLocalExport(path, '周会');

      expect(renamed, isNot(path));
      expect(controller.transcriptForPath(renamed), '甲。\n乙改过。\n丙。');
      expect(
        controller.transcriptSegmentsForPath(renamed).map((s) => s.speaker),
        ['1', '2', '1'],
      );
      expect(controller.canUndoSpeakerEdit(renamed), isTrue);
      expect(await controller.undoSpeakerEdit(renamed), isTrue);
      expect(
        controller.transcriptSegmentsForPath(renamed).map((s) => s.speaker),
        ['1', '2', '3'],
      );
    });

    test('删除后，不再留着它的合并复原', () async {
      final (controller, path) = await mergedTake();
      expect(controller.canUndoSpeakerEdit(path), isTrue);

      final result = await controller.deleteLocalExports([path]);

      expect(result.deleted, 1);
      expect(controller.canUndoSpeakerEdit(path), isFalse);
    });
  });
}
