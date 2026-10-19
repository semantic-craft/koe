import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/context/context_file.dart';
import 'package:koe/state/recording.dart';
import 'package:koe/state/transcript_store.dart';
import 'package:koe/util/off_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory documents;
  late File transcripts;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('koe-json-store');
    transcripts = File('${documents.path}/AnkerRecorder/transcripts.json');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => documents.path,
        );
    offUiFallbacks = 0;
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await documents.delete(recursive: true);
  });

  test('旧的带缩进逐字稿仍能读取，再次保存后不带缩进', () async {
    await transcripts.parent.create(recursive: true);
    await transcripts.writeAsString(
      const JsonEncoder.withIndent('  ').convert(
        TranscriptStore.encode(
          byPath: const {'/tmp/123.wav': '说话人 1：你好'},
          byFileId: const {123: '说话人 1：你好'},
          aliasesByPath: const {},
          aliasesByFileId: const {},
        ),
      ),
    );

    final legacy = await TranscriptStore.load();
    expect(legacy.byFileId[123], '说话人 1：你好');

    await TranscriptStore.save(
      byPath: legacy.byPath,
      byFileId: {...legacy.byFileId, 124: '第二段'},
      aliasesByPath: legacy.aliasesByPath,
      aliasesByFileId: legacy.aliasesByFileId,
      strict: true,
    );

    expect(await transcripts.readAsString(), isNot(contains('\n')));
    final reloaded = await TranscriptStore.load();
    expect(reloaded.byFileId, {123: '说话人 1：你好', 124: '第二段'});
  });

  test('逐字稿很大时在后台编码，存取结果不变', () async {
    final segments = [
      for (var i = 0; i < 6000; i++)
        TranscriptSegment(
          text: '第$i句：下周和供应商确认报价单',
          start: Duration(seconds: i * 3),
          end: Duration(seconds: i * 3 + 2),
          speaker: '${i % 3 + 1}',
        ),
    ];
    final text = segments.map((s) => s.text).join('\n');
    Future<void> save() => TranscriptStore.save(
      byPath: {'/tmp/178.wav': text},
      byFileId: {178: text},
      aliasesByPath: const {},
      aliasesByFileId: const {},
      segments: {'file:178': segments},
      strict: true,
    );

    await save();
    expect(
      await transcripts.length(),
      greaterThan(TranscriptStore.backgroundEncodeThreshold),
    );
    await save();

    final reloaded = await TranscriptStore.load();
    expect(reloaded.byFileId[178], text);
    expect(reloaded.segments['file:178'], hasLength(6000));
    expect(reloaded.segments['file:178']!.last.text, segments.last.text);
    expect(offUiFallbacks, 0);
  });

  test('个人记录文件：旧的带缩进文件仍能读取，再次保存后不带缩进', () async {
    final file = File('${documents.path}/todos.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'todos': [
          {'id': 't1', 'title': '确认报价单'},
        ],
      }),
    );
    final store = ContextFile('todos.json', file: file);

    final legacy = await store.read();
    expect((legacy!['todos'] as List).single, {'id': 't1', 'title': '确认报价单'});

    await store.write({...legacy, 'version': 1});

    expect(await file.readAsString(), isNot(contains('\n')));
    expect(await store.read(), legacy);
  });
}
