import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/minutes_export.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/file_types.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('koe_492_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    AppSettingsStore.resetForTesting();
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'SRT and VTT subtitle export/import round-trips timestamps and speaker names',
    () async {
      final wav = File('${tempDir.path}/subtitle_take.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: tempDir,
        transcriptPersister: ({bool strict = false}) async {},
      );
      addTearDown(controller.dispose);

      await controller.library.upsert(
        RecordingAsset(
          path: wav.path,
          displayName: '字幕导出测试',
          source: RecordingSource.phone,
          recordedAt: DateTime(2026, 10, 24, 10),
          importedAt: DateTime(2026, 10, 24, 10, 5),
        ),
      );

      controller.rememberTranscript(
        wav.path,
        '说话人 1：大家好，今天讨论 Koe 纪要导出。\n说话人 2：支持 Word、PDF 与字幕文件。',
        segments: const [
          TranscriptSegment(
            start: Duration(milliseconds: 1250),
            end: Duration(milliseconds: 4500),
            text: '大家好，今天讨论 Koe 纪要导出。',
            speaker: '1',
          ),
          TranscriptSegment(
            start: Duration(milliseconds: 5000),
            end: Duration(milliseconds: 9750),
            text: '支持 Word、PDF 与字幕文件。',
            speaker: '2',
          ),
        ],
      );
      await controller.renameTranscriptSpeaker(wav.path, '1', '林工');
      await controller.renameTranscriptSpeaker(wav.path, '2', '周敏');

      final ref = RecordingReference(path: wav.path);
      final srtWithSpeakers = controller.exportTranscriptSrtText(
        ref,
        includeSpeakers: true,
      );
      expect(srtWithSpeakers, contains('00:00:01,250 --> 00:00:04,500'));
      expect(srtWithSpeakers, contains('林工：大家好，今天讨论 Koe 纪要导出。'));
      expect(srtWithSpeakers, contains('周敏：支持 Word、PDF 与字幕文件。'));

      final srtWithoutSpeakers = controller.exportTranscriptSrtText(
        ref,
        includeSpeakers: false,
      );
      expect(srtWithoutSpeakers, isNot(contains('林工：')));
      expect(srtWithoutSpeakers, contains('大家好，今天讨论 Koe 纪要导出。'));

      final vttWithSpeakers = controller.exportTranscriptVttText(
        ref,
        includeSpeakers: true,
      );
      expect(vttWithSpeakers, startsWith('WEBVTT'));
      expect(vttWithSpeakers, contains('00:00:01.250 --> 00:00:04.500'));
      expect(vttWithSpeakers, contains('<v 林工>大家好，今天讨论 Koe 纪要导出。'));

      // Round-trip SRT import into library.
      final importedOutcome = await controller.importMinutesText(
        '评审字幕.srt',
        srtWithSpeakers,
      );
      final importedSrtDoc = importedOutcome.document;
      expect(importedSrtDoc.title, '评审字幕');
      expect(importedSrtDoc.timingReliable, isTrue);
      expect(importedSrtDoc.segments, hasLength(2));
      expect(importedSrtDoc.segments[0].start.inMilliseconds, 1250);
      expect(importedSrtDoc.segments[0].end?.inMilliseconds, 4500);
      expect(importedSrtDoc.segments[0].speaker, '林工');
      expect(importedSrtDoc.segments[0].text, '大家好，今天讨论 Koe 纪要导出。');

      // Round-trip VTT import via parseMinutesDocument.
      final parsedVtt = parseMinutesDocument('回放字幕.vtt', vttWithSpeakers).document;
      expect(parsedVtt.title, '回放字幕');
      expect(parsedVtt.timingReliable, isTrue);
      expect(parsedVtt.segments, hasLength(2));
      expect(parsedVtt.segments[1].start.inMilliseconds, 5000);
      expect(parsedVtt.segments[1].end?.inMilliseconds, 9750);
      expect(parsedVtt.segments[1].speaker, '周敏');
      expect(parsedVtt.segments[1].text, '支持 Word、PDF 与字幕文件。');
    },
  );

  test(
    'Markdown notes import extracts heading title and timestamped segments, and file types include srt/vtt/md',
    () async {
      expect(
        minutesTextFileTypes.extensions,
        containsAll(<String>['txt', 'md', 'srt', 'vtt']),
      );

      const mdRaw = '''
# 产品周会纪要

- [00:12] 张三：先把导出功能落地
- [01:05] 李四：周五前完成回归测试
''';
      final parsedMd = parseMinutesDocument('weekly.md', mdRaw).document;
      expect(parsedMd.title, '产品周会纪要');
      expect(parsedMd.timingReliable, isTrue);
      expect(parsedMd.segments, hasLength(2));
      expect(parsedMd.segments[0].start.inMilliseconds, 12000);
      expect(parsedMd.segments[0].speaker, '张三');
      expect(parsedMd.segments[0].text, '先把导出功能落地');
      expect(parsedMd.segments[1].start.inMilliseconds, 65000);
      expect(parsedMd.segments[1].speaker, '李四');
    },
  );

  test(
    'DOCX, PDF, and HTML exports include sections, action table, review items, and [S#] sources',
    () {
      const minutes = MeetingMinutes(
        title: 'Koe 6A 导出评审',
        overview: '确认多格式导出结构与 [S1] 原文依据。',
        topics: [
          MinuteItem('支持导出 Word 与 PDF', ['S1']),
        ],
        decisions: [],
        actions: [
          MinuteItem(
            '补齐 SRT/VTT 字幕测试',
            ['S2'],
            owner: '林工',
            due: '周五',
          ),
        ],
        questions: [],
        reviewItems: ['确认发版时间是否为 10 月 28 日 [S2]'],
      );
      final result = AnalysisResult(
        text: '{}',
        sourceHash: 'hash492',
        model: 'qwen-plus',
        instruction: 'prompt',
        sources: const [
          '00:02 林工：我们需要直接导出 Word 和 PDF。',
          '00:08 周敏：周五前补齐 SRT 与 VTT 字幕测试，10 月 28 日发版。',
        ],
        createdAt: DateTime.utc(2026, 10, 24, 10),
      );

      // 1. Rich-text HTML export.
      final html = minutes.exportHtml(result);
      expect(html, contains('<h1>Koe 6A 导出评审</h1>'));
      expect(html, contains('<h2>议题</h2>'));
      expect(html, contains('<table border="1"'));
      expect(html, contains('补齐 SRT/VTT 字幕测试'));
      expect(html, contains('00:02 林工：我们需要直接导出 Word 和 PDF。'));

      // 2. DOCX export (OOXML PKZIP).
      final docxBytes = minutes.exportDocxBytes(result);
      expect(docxBytes.length, greaterThan(200));
      expect(docxBytes[0], 0x50); // 'P'
      expect(docxBytes[1], 0x4B); // 'K'
      final archive = readZipArchive(docxBytes);
      expect(
        archive.keys,
        containsAll(<String>[
          '[Content_Types].xml',
          '_rels/.rels',
          'word/_rels/document.xml.rels',
          'word/styles.xml',
          'word/document.xml',
        ]),
      );
      final documentXml = utf8.decode(archive['word/document.xml']!);
      expect(documentXml, contains('Koe 6A 导出评审'));
      expect(documentXml, contains('议题'));
      expect(documentXml, contains('<w:tbl>'));
      expect(documentXml, contains('补齐 SRT/VTT 字幕测试'));
      expect(documentXml, contains('林工'));
      expect(documentXml, contains('待确认问题'));
      expect(documentXml, contains('[S1]'));

      // 3. PDF export (%PDF-1.4 multi-page document).
      final pdfBytes = minutes.exportPdfBytes(result, linesPerPage: 6);
      final pdfText = latin1.decode(pdfBytes);
      expect(pdfText, startsWith('%PDF-1.4\n'));
      expect(pdfText, contains('/Type /Catalog'));
      expect(pdfText, contains('/Type /Pages'));
      expect(pdfText, contains('/Count '));
      expect(pdfText, contains('/UniGB-UTF16-H'));
      expect(pdfText, contains('<FEFF'));
      expect(pdfText, contains('xref\n'));
      expect(pdfText.trimRight(), endsWith('%%EOF'));
      // Embedded markdown stream preserves [S1] and title in UTF-8.
      final utf8Chunk = utf8.decode(pdfBytes, allowMalformed: true);
      expect(utf8Chunk, contains('Koe 6A 导出评审'));
      expect(utf8Chunk, contains('[S1]'));
    },
  );

  testWidgets(
    'MinutesPanel exposes rich-text copy, Word/PDF export, and SRT/VTT export actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final wav = File('${tempDir.path}/panel_export.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: tempDir,
        transcriptPersister: ({bool strict = false}) async {},
      );
      addTearDown(controller.dispose);

      await controller.library.upsert(
        RecordingAsset(
          path: wav.path,
          displayName: '面板导出测试',
          source: RecordingSource.phone,
          recordedAt: DateTime(2026, 10, 24, 11),
          importedAt: DateTime(2026, 10, 24, 11, 5),
        ),
      );
      controller.rememberTranscript(
        wav.path,
        '说话人 1：测试导出面板按钮。',
        segments: const [
          TranscriptSegment(
            start: Duration.zero,
            end: Duration(seconds: 3),
            text: '测试导出面板按钮。',
            speaker: '1',
          ),
        ],
      );
      final ref = RecordingReference(path: wav.path);
      final recKey = controller.analysisKey(ref);
      final view = controller.recordingView(ref);
      controller.analysis.results['$recKey/minutes'] = AnalysisResult(
        text: jsonEncode({
          'title': '面板导出测试',
          'overview': '验证导出入口齐全。',
          'topics': [
            {
              'text': '测试导出面板按钮',
              'sources': ['S1'],
            },
          ],
          'decisions': <Object>[],
          'actions': <Object>[],
          'questions': <Object>[],
        }),
        sourceHash: analysisFingerprint(view.text),
        model: 'qwen-plus',
        instruction: 'prompt',
        sources: const ['说话人 1：测试导出面板按钮。'],
        createdAt: DateTime.utc(2026, 10, 24, 11),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1100,
              height: 820,
              child: MinutesPanel(controller: controller, reference: ref),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('minutes-copy-rich')), findsOneWidget);
      expect(find.byKey(const Key('minutes-export-md')), findsOneWidget);
      expect(find.byKey(const Key('minutes-export-docx')), findsOneWidget);
      expect(find.byKey(const Key('minutes-export-pdf')), findsOneWidget);
      expect(find.byKey(const Key('minutes-export-srt')), findsOneWidget);
      expect(find.byKey(const Key('minutes-export-vtt')), findsOneWidget);
    },
  );
}
