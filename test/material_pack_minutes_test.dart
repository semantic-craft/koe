import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

import 'support/wav_fixture.dart';

const _source = '江松说明：接口未联调造成延期，下周完成。';
String _body(String title) => jsonEncode({
  'schemaVersion': 2,
  'title': title,
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
      'note': '人名待确认',
      'heard': ['江松'],
      'sources': ['S1'],
    },
  ],
  'decisions': [],
  'actions': [],
  'questions': [],
});
AnalysisResult _result(String title, {int revision = 0}) => AnalysisResult(
  text: _body(title),
  sourceHash: analysisFingerprint(_source),
  model: 'test-model',
  instruction: '会议纪要',
  sources: [_source],
  createdAt: DateTime.utc(2026, 11, 3),
  editedAt: revision == 0 ? null : DateTime.utc(2026, 11, 3, revision),
  templateId: 'meeting',
  templateVersion: 2,
);

class _FailingAnalysis extends RecordingAnalysis {
  _FailingAnalysis(File file) : super(file: file);
  bool fail = false;
  @override
  Future<void> save() async {
    if (fail) throw const FileSystemException('injected persistence failure');
    await super.save();
  }
}

class _GatedAnalysis extends RecordingAnalysis {
  _GatedAnalysis(File file) : super(file: file);
  bool blockNext = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> save() async {
    if (blockNext) {
      blockNext = false;
      entered.complete();
      await release.future;
      throw const FileSystemException('injected first-slot save failure');
    }
    await super.save();
  }
}

class _DeferredSaveAnalysis extends RecordingAnalysis {
  _DeferredSaveAnalysis(File file) : super(file: file);
  bool blockNext = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> save() async {
    if (blockNext) {
      blockNext = false;
      entered.complete();
      await release.future;
    }
    await super.save();
  }
}

class _Library {
  _Library(this.root, {RecordingAnalysis? manager})
    : analysis =
          manager ??
          RecordingAnalysis(file: File('${root.path}/analysis.json')) {
    controller = RecorderController(
      loadPersistedState: false,
      phoneRecordingEnabled: false,
      analysisController: analysis,
      libraryStore: RecordingLibraryStore(
        file: File('${root.path}/library.json'),
      ),
      libraryDirectory: Directory('${root.path}/audio'),
      minutesStore: MinutesDocumentStore(
        file: File('${root.path}/documents.json'),
      ),
      topicStore: TopicStore(inMemory: true),
      topicsEnabled: false,
      transcriptPersister: ({bool strict = false}) async {},
    )..materialPackWorkDirectory = Directory('${root.path}/work');
  }
  final Directory root;
  final RecordingAnalysis analysis;
  late final RecorderController controller;
  Future<void> ready() async {
    await controller.waitForRecordingLibrary();
    await controller.waitForTranscripts();
    await controller.waitForBookmarks();
    await controller.waitForMinutesDocuments();
    await analysis.load();
  }

  RecordingReference ref(String path) =>
      RecordingReference(path: path, fileId: controller.fileIdFromPath(path));
  String slot(String path) => '${controller.analysisKey(ref(path))}/minutes';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('koe-pack-minutes-');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  Future<_Library> library(String name, {RecordingAnalysis? manager}) async {
    final lib = _Library(
      await Directory('${temp.path}/$name').create(recursive: true),
      manager: manager,
    );
    await lib.ready();
    addTearDown(lib.controller.dispose);
    return lib;
  }

  Future<String> material(_Library lib) async {
    final audio = File('${temp.path}/source.wav');
    await audio.writeAsBytes(wavBytes(List.generate(4000, (i) => i % 251)));
    final imported = await lib.controller.importLocalAudio(audio.path);
    lib.controller.rememberTranscript(imported.path, _source);
    // A complete save is the assertion boundary, not the synchronous remember call.
    await lib.controller.saveManualTranscript(imported.path, _source);
    lib.analysis.results[lib.slot(imported.path)] = _result(
      '当前纪要',
      revision: 12,
    );
    lib.analysis.versionHistory[lib.slot(imported.path)] = [
      for (var i = 1; i <= 12; i++) _result('历史$i', revision: i),
    ];
    await lib.analysis.save();
    return imported.path;
  }

  test(
    'controller pack exchange restores nested current and ten histories on another library and restart',
    () async {
      final a = await library('a');
      final path = await material(a);
      final exported = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: true,
      );
      final opened = await openMaterialPack(
        exported.path,
        workDirectory: Directory('${temp.path}/inspect'),
      );
      final manifest = opened.pack.toJson();
      expect(manifest['minutes'], isNotNull);
      expect(jsonEncode(manifest), isNot(contains(a.root.path)));
      await opened.discard();
      final b = await library('b');
      final imported = await b.controller.importMaterialPack(exported.path);
      final restored = b.analysis.results[b.slot(imported.path!)];
      expect(restored, isNotNull);
      expect(
        jsonDecode(restored!.text),
        jsonDecode(a.analysis.results[a.slot(path)]!.text),
      );
      expect(restored.sources, [_source]);
      expect(
        restored.staleFor(
          b.controller.recordingView(b.ref(imported.path!)).text,
        ),
        isFalse,
      );
      expect(b.analysis.versionsFor(b.slot(imported.path!)).length, 10);
      final duplicate = await b.controller.importMaterialPack(exported.path);
      expect(duplicate.duplicate, isTrue);
      expect(b.analysis.versionsFor(b.slot(imported.path!)).length, 10);
      final restarted = await library('b');
      final persisted =
          restarted.analysis.results[restarted.slot(imported.path!)]!;
      expect(
        MeetingMinutes.parse(
          persisted.text,
          persisted.sources.length,
          sourceTexts: persisted.sources,
        ).terms.single.heard,
        ['江松'],
      );
      expect(
        restarted.analysis.versionsFor(restarted.slot(imported.path!)).length,
        10,
      );
    },
  );

  test(
    'incoming minutes never overwrite local edits and repeated imports retain one conflict version',
    () async {
      final a = await library('a');
      final path = await material(a);
      final exported = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: true,
      );
      final b = await library('b');
      final first = await b.controller.importMaterialPack(exported.path);
      final key = b.slot(first.path!);
      final local = _result('本机手改', revision: 13);
      b.analysis.results[key] = local;
      await b.analysis.save();
      final incoming = await b.controller.importMaterialPack(exported.path);
      expect(incoming.conflict, isTrue);
      expect(b.analysis.results[key], same(local));
      expect(
        b.analysis
            .versionsFor(key)
            .where((v) => jsonDecode(v.text)['title'] == '当前纪要')
            .length,
        1,
      );
      final count = b.analysis.versionsFor(key).length;
      await b.controller.importMaterialPack(exported.path);
      expect(b.analysis.versionsFor(key).length, count);
    },
  );

  test(
    'without audio minutes and histories survive restart and migrate only after matching pairing',
    () async {
      final a = await library('a');
      final path = await material(a);
      final exported = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: false,
      );
      final b = await library('b');
      final imported = await b.controller.importMaterialPack(exported.path);
      final id = imported.minutesId!;
      final restarted = await library('b');
      final doc = restarted.controller.minutesDocumentById(id)!;
      expect(doc.restore!['minutes'], isNotNull);
      expect((doc.restore!['minutes'] as Map)['history'], hasLength(10));
      final paired = await restarted.controller.attachMinutesAudio(id, path);
      expect(paired.ok, isTrue);
      expect(
        jsonDecode(
          restarted
              .analysis
              .results[restarted.slot(paired.restoredPath!)]!
              .text,
        ),
        jsonDecode(_body('当前纪要')),
      );
      expect(restarted.controller.minutesDocumentById(id), isNull);
    },
  );

  test(
    'minutes save failure keeps previous current and history, and import reports failure',
    () async {
      final a = await library('a');
      final path = await material(a);
      final exported = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: true,
      );
      final manager = _FailingAnalysis(File('${temp.path}/b/analysis.json'));
      final b = await library('b', manager: manager);
      final localAudio = await b.controller.importLocalAudio(path);
      final key = b.slot(localAudio.path);
      final local = _result('本机手改');
      manager.results[key] = local;
      await manager.save();
      manager.fail = true;
      await expectLater(
        b.controller.importMaterialPack(exported.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(manager.results[key], same(local));
      expect(manager.versionsFor(key), isEmpty);
    },
  );
  test(
    'invalid minutes are rejected before any audio or transcript is imported',
    () async {
      final a = await library('a');
      final path = await material(a);
      final exported = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: true,
      );
      final bytes = await exported.readAsBytes();
      final first = bytes.indexOf(10),
          second = bytes.indexOf(10, bytes.indexOf(10) + 1);
      final size = int.parse(utf8.decode(bytes.sublist(first + 1, second)));
      final manifest =
          jsonDecode(utf8.decode(bytes.sublist(second + 1, second + 1 + size)))
              as Map<String, dynamic>;
      manifest['version'] = 1;
      manifest['minutes'] = {
        'current': _result('坏纪要').toJson()..['sources'] = <String>[],
        'history': [],
      };
      final json = utf8.encode(jsonEncode(manifest));
      final invalid = File('${temp.path}/invalid.koepack');
      await invalid.writeAsBytes([
        ...utf8.encode('KOEPACK1\n${json.length}\n'),
        ...json,
        ...bytes.sublist(second + 1 + size),
      ]);
      final b = await library('b');
      await expectLater(
        b.controller.importMaterialPack(invalid.path),
        throwsA(isA<MaterialPackException>()),
      );
      expect(b.controller.library.assets, isEmpty);
      expect(b.analysis.results, isEmpty);
    },
  );

  test(
    'a reused recorder file id cannot merge minutes into different audio content',
    () async {
      final a = await library('a');
      final path = await material(a);
      final exported = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: true,
      );
      final opened = await openMaterialPack(
        exported.path,
        workDirectory: Directory('${temp.path}/rewrap'),
      );
      final manifest = opened.pack.toJson();
      (manifest['material'] as Map)['deviceFileId'] = 1234;
      (manifest['material'] as Map)['source'] = 'device';
      final json = utf8.encode(jsonEncode(manifest));
      final incoming = File('${temp.path}/id-collision.koepack');
      await incoming.writeAsBytes([
        ...utf8.encode('KOEPACK1\n${json.length}\n'),
        ...json,
        ...await opened.audioFile!.readAsBytes(),
      ]);
      await opened.discard();
      final b = await library('b');
      final other = File('${temp.path}/other.wav');
      await other.writeAsBytes(
        wavBytes(List.generate(4000, (i) => (i + 9) % 251)),
      );
      final local = await b.controller.importLocalAudio(other.path);
      b.controller.localPathsByFileId[1234] = local.path;
      final result = await b.controller.importMaterialPack(incoming.path);
      expect(result.path, isNot(local.path));
      expect(b.analysis.results[b.slot(local.path)], isNull);
    },
  );

  test(
    'minutes-only pack without audio remains readable as snapshots and never fabricates a transcript on pairing',
    () async {
      final a = await library('a');
      final path = await material(a);
      final exported = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: false,
      );
      final opened = await openMaterialPack(
        exported.path,
        workDirectory: Directory('${temp.path}/inspect'),
      );
      final manifest = opened.pack.toJson()..remove('transcript');
      manifest['version'] = 2;
      manifest['minutes'] = {
        'current': _result('只有纪要').toJson()..['isDraft'] = false,
        'history': [],
      };
      final json = utf8.encode(jsonEncode(manifest));
      final pack = File('${temp.path}/minutes-only.koepack');
      await pack.writeAsBytes([
        ...utf8.encode('KOEPACK1\n${json.length}\n'),
        ...json,
      ]);
      final b = await library('b');
      final imported = await b.controller.importMaterialPack(pack.path);
      final doc = b.controller.minutesDocumentById(imported.minutesId!)!;
      expect(doc.bodyText, _source);
      expect(doc.timingReliable, isFalse);
      expect(doc.warning, contains('纪要原文快照'));
      expect(doc.restore!.containsKey('transcript'), isFalse);
      final paired = await b.controller.attachMinutesAudio(doc.id, path);
      expect(paired.ok, isTrue);
      final result = b.analysis.results[b.slot(paired.restoredPath!)]!;
      expect(
        result.staleFor(
          b.controller.recordingView(b.ref(paired.restoredPath!)).text,
        ),
        isTrue,
      );
    },
  );
  test(
    'full histories stay stable through three repeated conflicting imports and restart',
    () async {
      final a = await library('a');
      final path = await material(a);
      final exported = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: true,
      );
      final b = await library('b');
      final audio = await b.controller.importLocalAudio(path);
      final key = b.slot(audio.path);
      b.analysis.results[key] = _result('本机当前', revision: 50);
      b.analysis.versionHistory[key] = [
        for (var i = 1; i <= 30; i++) _result('本机历史$i', revision: i),
      ];
      await b.analysis.save();
      await b.controller.importMaterialPack(exported.path);
      List<String> titles(_Library lib) => lib.analysis
          .versionsFor(key)
          .map((v) => (jsonDecode(v.text) as Map)['title'] as String)
          .toList();
      final expected = titles(b);
      expect(expected, hasLength(30));
      expect(expected.last, '当前纪要');
      for (var i = 0; i < 3; i++) {
        await b.controller.importMaterialPack(exported.path);
        expect(titles(b), expected);
      }
      final restarted = await library('b');
      expect(titles(restarted), expected);

      final textPack = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: false,
      );
      final c = await library('c');
      final document = await c.controller.importMaterialPack(textPack.path);
      a.analysis.results[a.slot(path)] = _result('外来新当前', revision: 40);
      a.analysis.versionHistory[a.slot(path)] = [
        for (var i = 1; i <= 12; i++) _result('外来历史$i', revision: 40 + i),
      ];
      await a.analysis.save();
      final changed = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: false,
      );
      await c.controller.importMaterialPack(changed.path);
      String stored(_Library lib) => jsonEncode(
        lib.controller
            .minutesDocumentById(document.minutesId!)!
            .restore!['minutes'],
      );
      final retained = stored(c);
      expect((jsonDecode(retained) as Map)['history'], hasLength(10));
      for (var i = 0; i < 3; i++) {
        await c.controller.importMaterialPack(changed.path);
        expect(stored(c), retained);
      }
      final textRestart = await library('c');
      expect(stored(textRestart), retained);
    },
  );

  test(
    'pack audio restores a known asset whose original is missing without making another asset',
    () async {
      final a = await library('a');
      final path = await material(a);
      final exported = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: true,
      );
      final b = await library('b');
      final original = await b.controller.importLocalAudio(path);
      await File(original.path).delete();
      final restored = await b.controller.importMaterialPack(exported.path);
      expect(await File(original.path).exists(), isTrue);
      expect(restored.path, original.path);
      expect(b.controller.library.assets, hasLength(1));
      expect(
        await File(original.path).readAsBytes(),
        await File(path).readAsBytes(),
      );
    },
  );
  test(
    'a successful write in another slot cannot persist a failed tentative minutes result',
    () async {
      final file = File('${temp.path}/concurrent.json');
      final manager = _GatedAnalysis(file);
      addTearDown(manager.dispose);
      await manager.load();
      final a = _result('A原版'), b = _result('B原版');
      manager.results['a/minutes'] = a;
      manager.results['b/minutes'] = b;
      await manager.save();
      manager.blockNext = true;
      final failed = expectLater(
        manager.editResult('a/minutes', a, _body('A失败修改')),
        throwsA(isA<FileSystemException>()),
      );
      await manager.entered.future;
      final success = manager.editResult('b/minutes', b, _body('B成功修改'));
      manager.release.complete();
      await Future.wait([failed, success]);
      final restarted = RecordingAnalysis(file: file);
      addTearDown(restarted.dispose);
      await restarted.load();
      expect(jsonDecode(restarted.results['a/minutes']!.text)['title'], 'A原版');
      expect(
        jsonDecode(restarted.results['b/minutes']!.text)['title'],
        'B成功修改',
      );
    },
  );
  for (final includeMinutes in [false, true]) {
    test(
      'text-only pack reports changed transcript even when minutes are ${includeMinutes ? 'identical' : 'absent'}',
      () async {
        final a = await library('a');
        final path = await material(a);
        if (!includeMinutes) {
          a.analysis.results.clear();
          a.analysis.versionHistory.clear();
          await a.analysis.save();
        }
        final oldPack = await a.controller.exportMaterialPack(
          a.ref(path),
          includeAudio: false,
        );
        final b = await library('b');
        final imported = await b.controller.importMaterialPack(oldPack.path);
        final oldBody = b.controller
            .minutesDocumentById(imported.minutesId!)!
            .bodyText;
        await a.controller.saveManualTranscript(
          path,
          '外来改过的完整正文，不能声称已保存在旧纪要里。',
        );
        final changedPack = await a.controller.exportMaterialPack(
          a.ref(path),
          includeAudio: false,
        );
        final conflict = await b.controller.importMaterialPack(
          changedPack.path,
        );
        expect(conflict.conflict, isTrue);
        expect(conflict.duplicate, isFalse);
        expect(conflict.message, contains('外来正文未保存'));
        expect(
          b.controller.minutesDocumentById(imported.minutesId!)!.bodyText,
          oldBody,
        );
      },
    );
  }

  for (final whileQueued in [true, false]) {
    test(
      'changed source ${whileQueued ? 'while waiting for the store queue' : 'during save'} cannot publish an adoption after restart',
      () async {
        final file = File('${temp.path}/guarded.json');
        final manager = _DeferredSaveAnalysis(file);
        addTearDown(manager.dispose);
        await manager.load();
        final a = _result('A原版'), b = _result('B未采纳');
        manager.results['a/minutes'] = a;
        manager.results['b/minutes'] = b;
        await manager.save();
        manager.blockNext = true;
        var current = true;
        Future<void>? first;
        if (whileQueued) {
          first = manager.editResult('a/minutes', a, _body('A新稿'));
          await manager.entered.future;
        }
        final guarded = expectLater(
          manager.editResult(
            'b/minutes',
            b,
            _body('B已采纳'),
            isStillCurrent: () => current,
          ),
          throwsStateError,
        );
        if (!whileQueued) await manager.entered.future;
        current = false;
        manager.release.complete();
        await guarded;
        if (first != null) await first;
        expect(manager.results['b/minutes'], same(b));
        final restarted = RecordingAnalysis(file: file);
        addTearDown(restarted.dispose);
        await restarted.load();
        expect(
          jsonDecode(restarted.results['b/minutes']!.text)['title'],
          'B未采纳',
        );
        expect(restarted.versionsFor('b/minutes'), isEmpty);
      },
    );
  }

  test('cancelled mutation cannot release a new owner after resume', () async {
    final file = File('${temp.path}/revoked-claim.json');
    final manager = _DeferredSaveAnalysis(file);
    addTearDown(manager.dispose);
    await manager.load();
    const slot = 'recording/minutes';
    final original = _result('未采纳');
    manager.results[slot] = original;
    await manager.save();
    final oldClaim = manager.claimMutation(slot)!;
    manager.blockNext = true;
    final pending = expectLater(() async {
      try {
        await manager.editResult(
          slot,
          original,
          _body('不应采纳'),
          mutationClaim: oldClaim,
        );
      } finally {
        expect(manager.releaseMutation(slot, oldClaim), isFalse);
      }
    }(), throwsStateError);
    await manager.entered.future;
    manager.suspendRecording('recording');
    manager.resumeRecording('recording');
    final replacement = manager.claimMutation(slot)!;
    manager.release.complete();
    await pending;
    expect(manager.ownsMutation(slot, replacement), isTrue);
    expect(manager.busy(slot), isTrue);
    await manager.save();
    final restarted = RecordingAnalysis(file: file);
    addTearDown(restarted.dispose);
    await restarted.load();
    expect(jsonDecode(restarted.results[slot]!.text)['title'], '未采纳');
    expect(restarted.versionsFor(slot), isEmpty);
    expect(manager.releaseMutation(slot, replacement), isTrue);
  });
}
