import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'support/wav_fixture.dart';

class _Client {
  _Client(this.process) {
    output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final reply = jsonDecode(line) as Map<String, dynamic>;
          pending.remove(reply['id'])?.complete(reply);
        });
    errors = process.stderr.listen((_) {});
  }
  final Process process;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  late StreamSubscription<String> output;
  late StreamSubscription<List<int>> errors;
  int serial = 0;
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = ++serial;
    final answer = Completer<Map<String, dynamic>>();
    pending[id] = answer;
    process.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    await process.stdin.flush();
    final response = await answer.future.timeout(const Duration(seconds: 5));
    expect(response.containsKey('error'), isFalse, reason: '$response');
    return response['result'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> tool(
    String name, [
    Map<String, dynamic> args = const {},
  ]) async {
    final response = await call('tools/call', {
      'name': name,
      'arguments': args,
    });
    return jsonDecode((response['content'] as List).single['text'] as String)
        as Map<String, dynamic>;
  }

  Future<void> initialize() async {
    await call('initialize', {
      'protocolVersion': '2025-11-25',
      'capabilities': {},
      'clientInfo': {'name': 'koe-controller-acceptance', 'version': '1'},
    });
    process.stdin.writeln(
      jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
    );
    await process.stdin.flush();
  }

  Future<void> close() async {
    await process.stdin.close();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    await output.cancel();
    await errors.cancel();
  }
}

AnalysisResult _minutes(String text, {String? sourceHash}) => AnalysisResult(
  text: jsonEncode({
    'schemaVersion': 2,
    'title': '合成纪要',
    'overview': text,
    'topics': [
      {
        'text': '记录',
        'sources': ['S1'],
        'summary': text,
        'points': [
          {
            'text': text,
            'sources': ['S1'],
          },
        ],
      },
    ],
    'decisions': [],
    'actions': [],
    'questions': [],
    'terms': [],
  }),
  sourceHash: sourceHash ?? analysisFingerprint(text),
  model: 'synthetic-no-provider',
  instruction: 'synthetic acceptance',
  sources: [text],
  createdAt: DateTime.now(),
  templateId: 'minutes',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'explicit recording grant automatically updates and revokes published text',
    () async {
      final root = await Directory.systemTemp.createTemp('koe-mcp-live-');
      final c = RecorderController(
        loadPersistedState: false,
        libraryDirectory: Directory('${root.path}/library'),
        mcpDirectory: Directory('${root.path}/mcp'),
        transcriptPersister: ({bool strict = false}) async {},
        analysisController: RecordingAnalysis(inMemory: true),
      );
      var disposed = false;
      addTearDown(() async {
        if (!disposed) c.dispose();
        await c.flushMcpPublication();
        await root.delete(recursive: true);
      });
      final source = File('${root.path}/speech.wav')
        ..writeAsBytesSync(wavBytes(List.filled(2000, 0)));
      final imported = await c.importLocalAudio(source.path);
      final privateAudio = File('${root.path}/ungranted.wav')
        ..writeAsBytesSync(wavBytes(List.filled(2000, 12)));
      final ungranted = await c.importLocalAudio(privateAudio.path);
      c.rememberTranscript(ungranted.path, '未授权的第二条录音内容');
      final ungrantedId = analysisFingerprint(
        c.analysisKey(RecordingReference(path: ungranted.path)),
      );
      const original = '说话人 1：先核对预算。';
      c.rememberTranscript(
        imported.path,
        original,
        segments: const [
          TranscriptSegment(text: '先核对预算。', start: Duration.zero, speaker: '1'),
        ],
      );
      final ref = RecordingReference(path: imported.path);
      expect(await Directory('${root.path}/mcp').exists(), isFalse);
      await c.grantMcpAccess(ref);
      final directory = await c.mcpPublicationDirectory;
      final client = _Client(
        await Process.start('python3', [
          '-B',
          'tools/koe-mcp/server.py',
          '--live-directory',
          directory.path,
        ]),
      );
      addTearDown(client.close);
      await client.initialize();
      final listed = await client.tool('list_recordings');
      final first = (listed['recordings'] as List).single as Map;
      final id = first['recording_id'] as String;
      final materialHash = c.library.assetForPath(imported.path)!.contentHash;
      expect(first['materialContentHash'], materialHash);
      final initialRevision = listed['snapshotRevision'];
      final read = await client.tool('get_transcript', {
        'recording_id': id,
        'expected_revision': initialRevision,
      });
      expect(read['text'], original);
      expect(read['snapshotRevision'], initialRevision);
      expect(
        DateTime.parse(read['exportedAt'] as String).year,
        DateTime.now().year,
      );
      expect(
        await client.tool('get_transcript', {'recording_id': ungrantedId}),
        containsPair('error', 'recording_unavailable'),
      );
      final serialized = await File(
        '${directory.path}/live.json',
      ).readAsString();
      expect(serialized, isNot(contains(imported.path)));
      expect(serialized, isNot(contains('未授权的第二条录音内容')));
      final pack =
          ((jsonDecode(serialized) as Map)['records'] as Map).values.single
              as Map;
      expect(pack['audio']['included'], isFalse);
      expect(
        pack['material']['contentHash'],
        c.library.assetForPath(imported.path)!.contentHash,
      );
      expect(pack.containsKey('bookmarks'), isFalse);
      expect((pack['material'] as Map).containsKey('place'), isFalse);
      expect(pack.containsKey('topic'), isFalse);

      const continued = '说话人 1：先核对预算。再确认时间。';
      c.rememberTranscript(
        imported.path,
        continued,
        segments: const [
          TranscriptSegment(
            text: '先核对预算。再确认时间。',
            start: Duration.zero,
            speaker: '1',
          ),
        ],
      );
      await c.flushMcpPublication();
      expect(
        (await client.tool('get_transcript', {'recording_id': id}))['text'],
        continued,
      );
      expect(
        await client.tool('get_transcript', {
          'recording_id': id,
          'expected_revision': initialRevision,
        }),
        containsPair('error', 'snapshot_changed'),
      );
      await c.renameTranscriptSpeaker(imported.path, '1', '小林');
      await c.flushMcpPublication();
      final aliased = await client.tool('get_transcript', {'recording_id': id});
      expect(aliased['text'], contains('小林'));
      expect(aliased['materialContentHash'], materialHash);
      expect((aliased['sources'] as List).single['speaker'], '小林');

      const corrected = '预算尚未确认，先完成核对。';
      await c.saveManualTranscript(imported.path, corrected);
      await c.flushMcpPublication();
      final edit = await client.tool('get_transcript', {'recording_id': id});
      expect(edit['text'], corrected);
      expect(edit['manuallyEdited'], isTrue);
      expect(edit['timingReliable'], isFalse);
      final key = '${c.analysisKey(ref)}/minutes';
      await c.analysis.mergeImportedMinutes(key, _minutes(corrected), const []);
      await c.flushMcpPublication();
      final withMinutes = await client.tool('get_minutes', {
        'recording_id': id,
      });
      expect(withMinutes['hasMinutes'], isTrue);
      expect(withMinutes['current']['text'], contains(corrected));
      expect(withMinutes['freshness'], 'current');
      await c.analysis.editResult(
        key,
        c.analysis.results[key]!,
        _minutes('保留校订后的关键点').text,
      );
      await c.flushMcpPublication();
      final updated = await client.tool('get_minutes', {'recording_id': id});
      expect(updated['current']['text'], contains('保留校订后的关键点'));
      expect(
        updated['snapshotRevision'],
        isNot(withMinutes['snapshotRevision']),
      );
      expect(
        (await client.tool('list_recordings'))['recordings'],
        hasLength(1),
      );
      await c.saveManualTranscript(imported.path, '$corrected 再核对范围。');
      await c.flushMcpPublication();
      expect(
        (await client.tool('get_minutes', {'recording_id': id}))['freshness'],
        'stale',
      );
      final pendingEdit = c.saveManualTranscript(
        imported.path,
        '$corrected 撤销期间的新版本。',
      );
      final pendingRevoke = c.revokeMcpAccess(ref);
      await Future.wait([pendingEdit, pendingRevoke]);
      await c.flushMcpPublication();
      expect((await client.tool('list_recordings'))['recordings'], isEmpty);
      expect(
        await client.tool('get_minutes', {'recording_id': id}),
        containsPair('error', 'recording_unavailable'),
      );
      await c.grantMcpAccess(ref);
      await c.trashLocalExports([imported.path]);
      await c.flushMcpPublication();
      expect((await client.tool('list_recordings'))['recordings'], isEmpty);
      expect(c.mcpAccessGranted(ref), isFalse);
      await c.grantMcpAccess(RecordingReference(path: ungranted.path));
      expect(
        (await client.tool('list_recordings'))['recordings'],
        hasLength(1),
      );
      final replacement = c.library.assetForPath(ungranted.path)!;
      await c.library.upsert(replacement.copyWith(contentHash: 'a' * 64));
      c.rememberTranscript(ungranted.path, '同路径的另一条录音');
      await c.flushMcpPublication();
      expect((await client.tool('list_recordings'))['recordings'], isEmpty);
      expect(
        c.mcpAccessGranted(RecordingReference(path: ungranted.path)),
        isFalse,
      );
      await c.grantMcpAccess(RecordingReference(path: ungranted.path));
      await c.analysis.mergeImportedMinutes(
        '${c.analysisKey(RecordingReference(path: ungranted.path))}/minutes',
        _minutes('损坏的旧纪要', sourceHash: 'invalid'),
        const [],
      );
      await c.flushMcpPublication();
      expect(c.mcpPublicationError, isNotNull);
      expect((await client.tool('list_recordings'))['recordings'], isEmpty);
      await c.revokeMcpAccess(RecordingReference(path: ungranted.path));
      expect(c.mcpPublicationError, isNull);
      final replacementMinutesKey =
          '${c.analysisKey(RecordingReference(path: ungranted.path))}/minutes';
      final recoveredMinutes = _minutes('恢复有效纪要');
      await c.analysis.mergeImportedMinutes(
        replacementMinutesKey,
        recoveredMinutes,
        const [],
      );
      // Import preserves local current; explicitly restore the imported version.
      await c.analysis.restoreVersion(
        replacementMinutesKey,
        c.analysis
            .versionsFor(replacementMinutesKey)
            .indexWhere(
              (version) =>
                  version.portableIdentity == recoveredMinutes.portableIdentity,
            ),
      );
      expect(
        c.analysis.results[replacementMinutesKey]!.sourceHash,
        recoveredMinutes.sourceHash,
      );
      await c.grantMcpAccess(RecordingReference(path: ungranted.path));
      expect(
        (await client.tool('list_recordings'))['recordings'],
        hasLength(1),
      );
      c.dispose();
      disposed = true;
      await c.flushMcpPublication();
      expect((await client.tool('list_recordings'))['recordings'], isEmpty);
      final evidence = Platform.environment['KOE_MINUTES_PROOF_DIR'];
      if (evidence != null) {
        await File('$evidence/mcp-proof.json').writeAsString(
          jsonEncode({
            'automatic_publication': true,
            'persistent_client': true,
            'continued_transcript': true,
            'corrected_transcript': true,
            'minutes_updated': true,
            'revision_guard': true,
            'revoked': true,
            'ungranted_denied': true,
            'input_sha256': analysisFingerprint(original),
            'evidence':
                'controller + real stdio client/server; synthetic content',
          }),
        );
      }
    },
  );
  test('disposing while grant waits does not revive access', () async {
    final root = await Directory.systemTemp.createTemp('koe-mcp-close-');
    final c = RecorderController(
      loadPersistedState: false,
      libraryDirectory: Directory('${root.path}/library'),
      mcpDirectory: Directory('${root.path}/mcp'),
      transcriptPersister: ({bool strict = false}) async {},
      analysisController: RecordingAnalysis(inMemory: true),
    );
    final source = File('${root.path}/speech.wav')
      ..writeAsBytesSync(wavBytes(List.filled(2000, 0)));
    final imported = await c.importLocalAudio(source.path);
    final ref = RecordingReference(path: imported.path);
    c.rememberTranscript(imported.path, '关闭时不重新授权');
    final pending = c.grantMcpAccess(ref);
    c.dispose();
    await expectLater(
      pending,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('closed'),
        ),
      ),
    );
    expect(c.mcpAccessGranted(ref), isFalse);
    await c.flushMcpPublication();
    await root.delete(recursive: true);
  });
  testWidgets(
    'Mac detail menu grants and revokes only the displayed recording',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      late Directory root;
      late RecorderController c;
      late RecordingReference ref;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('koe-mcp-menu-');
        c = RecorderController(
          loadPersistedState: false,
          libraryDirectory: Directory('${root.path}/library'),
          mcpDirectory: Directory('${root.path}/mcp'),
          transcriptPersister: ({bool strict = false}) async {},
          analysisController: RecordingAnalysis(inMemory: true),
        );
        final source = File('${root.path}/speech.wav')
          ..writeAsBytesSync(wavBytes(List.filled(2000, 0)));
        final imported = await c.importLocalAudio(source.path);
        c.rememberTranscript(imported.path, '界面授权的合成文字');
        ref = RecordingReference(path: imported.path);
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: c,
          child: MaterialApp(home: RecordingDetailScreen(reference: ref)),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许本机 AI 读取文字和纪要'));
      await tester.pumpAndSettle();
      expect(find.text('允许本机 AI 读取这条录音？'), findsOneWidget);
      expect(c.mcpAccessGranted(ref), isFalse);
      await tester.tap(find.text('允许读取'));
      await tester.pump();
      Future<void> waitForRecords(int count) async {
        final deadline = Stopwatch()..start();
        while (deadline.elapsed < const Duration(seconds: 5)) {
          final observed = await tester.runAsync(() async {
            final file = File('${root.path}/mcp/live.json');
            if (!await file.exists()) return -1;
            return ((jsonDecode(await file.readAsString()) as Map)['records']
                    as Map)
                .length;
          });
          if (observed == count) return;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        fail('MCP publication did not reach $count records');
      }

      await waitForRecords(1);
      final dialogDeadline = Stopwatch()..start();
      while (find.text('本次 MCP 读取已开启').evaluate().isEmpty &&
          dialogDeadline.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('本次 MCP 读取已开启'), findsOneWidget);
      expect(c.mcpAccessGranted(ref), isTrue);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销 MCP 读取'));
      await tester.pump();
      await waitForRecords(0);
      await tester.pumpAndSettle();
      expect(c.mcpAccessGranted(ref), isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        c.dispose();
      });
      var flushed = false;
      unawaited(c.flushMcpPublication().then((_) => flushed = true));
      final cleanupDeadline = Stopwatch()..start();
      while (!flushed && cleanupDeadline.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(flushed, isTrue);
      await tester.runAsync(() => root.delete(recursive: true));
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
