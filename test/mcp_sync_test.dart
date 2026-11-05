import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

AnalysisResult _sampleMinutes(String text, {String? sourceHash}) =>
    AnalysisResult(
      text: jsonEncode({
        'schemaVersion': 2,
        'title': '明日待办与产品评审纪要',
        'overview': text,
        'topics': [
          {
            'text': '明日安排',
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
        'actions': [
          {
            'text': '明天上午十点确认闪记同步方案',
            'owner': '我',
            'due': '明天 10:00',
            'sources': ['S1'],
          },
        ],
        'questions': [],
        'terms': [],
      }),
      sourceHash: sourceHash ?? analysisFingerprint(text),
      model: 'qwen-plus',
      instruction: 'test minutes',
      sources: [text],
      createdAt: DateTime.utc(2026, 11, 5, 12, 0),
      templateId: 'minutes',
    );

Future<int> _freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<Map<String, dynamic>> _callRemoteMcpTool({
  required String baseUrl,
  required String token,
  required String name,
  Map<String, dynamic> arguments = const {},
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('$baseUrl/mcp'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.contentType = ContentType.json;
    req.add(
      utf8.encode(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': name, 'arguments': arguments},
        }),
      ),
    );
    final resp = await req.close();
    final raw = await utf8.decoder.bind(resp).join();
    expect(resp.statusCode, 200, reason: raw);
    final rpc = jsonDecode(raw) as Map<String, dynamic>;
    expect(rpc['error'], isNull, reason: raw);
    final result = rpc['result'] as Map<String, dynamic>;
    expect(result['isError'], isNot(true), reason: raw);
    return jsonDecode((result['content'] as List).single['text'] as String)
        as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'McpSyncConfig extracts KOEMCP1 ticket from natural-language Agent reply and generates VPS/LAN prompts',
    () {
      final controller = RecorderController(
        loadPersistedState: false,
        analysisController: RecordingAnalysis(inMemory: true),
      );
      addTearDown(controller.dispose);

      final vpsPrompt = controller.buildAgentMcpSetupPrompt(hasVps: true);
      final lanPrompt = controller.buildAgentMcpSetupPrompt(hasVps: false);
      expect(vpsPrompt, contains('--print-pairing'));
      expect(vpsPrompt, contains('KOEMCP1.'));
      expect(vpsPrompt, contains('/mcp'));
      expect(lanPrompt, contains('--mode lan'));
      expect(lanPrompt, contains('KOEMCP1.'));

      const original = McpSyncConfig(
        baseUrl: 'https://minutes.example.com',
        token: 'secret-token-0123456789abcdef0123456789',
        mode: McpSyncMode.vps,
      );
      final code = original.encodePairingCode();
      final prose = '''
我已经帮你把 Koe 的远程 MCP 服务部署到 VPS，并在 Magpie 中配置好了 `https://minutes.example.com/mcp`。
请复制下面这串连接码，回到 Koe App 点击「从剪贴板一键接入」：

$code

配置完成后手机录音生成的纪要会自动同步。
''';
      final parsed = McpSyncConfig.parseFromText(prose);
      expect(parsed.baseUrl, 'https://minutes.example.com');
      expect(parsed.token, original.token);
      expect(parsed.mode, McpSyncMode.vps);
      expect(parsed.redactedLabel, 'VPS 云端 · minutes.example.com');
      expect(parsed.redactedLabel, isNot(contains(original.token)));

      const settings = AppSettings(
        mcpSyncUrl: 'https://minutes.example.com',
        mcpSyncMode: 'vps',
        mcpSyncToken: 'secret-token-0123456789abcdef0123456789',
      );
      final settingsJson = jsonEncode(settings.toJson());
      expect(settingsJson, contains('https://minutes.example.com'));
      expect(
        settingsJson,
        isNot(contains('secret-token-0123456789abcdef0123456789')),
      );
    },
  );

  test(
    'iPhone recording and pure-text minutes auto-push to HTTP MCP server and auto-pull into Mac Koe',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      final root = await Directory.systemTemp.createTemp('koe-mcp-sync-e2e-');
      final serverStore = Directory('${root.path}/server-store')..createSync();
      final tokenFile = File('${root.path}/token');
      final port = await _freePort();
      final baseUrl = 'http://127.0.0.1:$port';

      final pairingResult = await Process.run('python3', [
        '-B',
        'tools/koe-mcp/server.py',
        '--directory',
        serverStore.path,
        '--token-file',
        tokenFile.path,
        '--public-url',
        '$baseUrl/mcp',
        '--mode',
        'vps',
        '--print-pairing',
      ]);
      expect(pairingResult.exitCode, 0, reason: '${pairingResult.stderr}');
      final pairingJson =
          jsonDecode('${pairingResult.stdout}') as Map<String, dynamic>;
      final pairingCode = pairingJson['pairingCode'] as String;
      final token = tokenFile.readAsStringSync().trim();

      final serverProcess = await Process.start('python3', [
        '-B',
        'tools/koe-mcp/server.py',
        '--directory',
        serverStore.path,
        '--http-listen',
        '127.0.0.1:$port',
        '--token-file',
        tokenFile.path,
      ]);

      final phoneController = RecorderController(
        loadPersistedState: false,
        libraryDirectory: Directory('${root.path}/phone-lib'),
        mcpDirectory: Directory('${root.path}/phone-mcp'),
        transcriptPersister: ({bool strict = false}) async {},
        analysisController: RecordingAnalysis(inMemory: true),
      );
      final macController = RecorderController(
        loadPersistedState: false,
        libraryDirectory: Directory('${root.path}/mac-lib'),
        mcpDirectory: Directory('${root.path}/mac-mcp'),
        transcriptPersister: ({bool strict = false}) async {},
        analysisController: RecordingAnalysis(inMemory: true),
      );

      addTearDown(() async {
        phoneController.dispose();
        macController.dispose();
        serverProcess.kill();
        await serverProcess.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () => -1,
        );
        await root.delete(recursive: true);
      });

      // Wait for HTTP server /healthz
      final httpClient = HttpClient();
      var ready = false;
      for (var i = 0; i < 40; i++) {
        try {
          final req = await httpClient.getUrl(Uri.parse('$baseUrl/healthz'));
          final resp = await req.close();
          await resp.drain<void>();
          if (resp.statusCode == 200) {
            ready = true;
            break;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      httpClient.close(force: true);
      expect(ready, isTrue, reason: 'HTTP MCP server did not start in time');

      // 1. Phone captures an audio recording + transcript + structured minutes
      final audioFile = File('${root.path}/phone-note.wav')
        ..writeAsBytesSync(wavBytes(List.filled(2000, 7)));
      final imported = await phoneController.importLocalAudio(audioFile.path);
      const transcriptText = '说话人 1：明天上午十点跟进闪记和 Cicada 的纪要同步方案。';
      phoneController.rememberTranscript(
        imported.path,
        transcriptText,
        segments: const [
          TranscriptSegment(
            text: '明天上午十点跟进闪记和 Cicada 的纪要同步方案。',
            start: Duration.zero,
            end: Duration(seconds: 3),
            speaker: '1',
          ),
        ],
      );
      final ref = RecordingReference(path: imported.path);
      final recKey = phoneController.analysisKey(ref);
      phoneController.analysis.results['$recKey/minutes'] = _sampleMinutes(
        transcriptText,
      );

      // 2. Phone also captures a pure-text note (no audio kept)
      await phoneController.minutes.upsert(
        MinutesDocument(
          id: 'text-note-1',
          title: '随手纯文字记事：买咖啡豆',
          sourceName: '纯文字记录',
          importedAt: DateTime.utc(2026, 11, 5, 12, 5),
          capturedAt: DateTime.utc(2026, 11, 5, 12, 5),
          segments: const [
            MinutesSegment(
              text: '下班路过买一包埃塞俄比亚手冲咖啡豆。',
              start: Duration.zero,
            ),
          ],
          timingReliable: false,
        ),
        strict: true,
      );

      // 3. Phone binds via Agent's natural-language reply containing KOEMCP1.
      await phoneController.bindMcpSyncFromText(
        '已配置好 VPS 与 MCP，配对码：$pairingCode，请粘贴到 Koe。',
      );
      expect(phoneController.mcpSyncState.phase, McpSyncPhase.idle);
      expect(phoneController.mcpSyncState.syncedCount, greaterThanOrEqualTo(2));

      // 4. Remote AI Agent queries HTTP MCP (POST /mcp) directly
      final listed = await _callRemoteMcpTool(
        baseUrl: baseUrl,
        token: token,
        name: 'list_recordings',
      );
      final recordings = (listed['recordings'] as List)
          .cast<Map<String, dynamic>>();
      expect(recordings.length, 2);

      final filtered = await _callRemoteMcpTool(
        baseUrl: baseUrl,
        token: token,
        name: 'list_recordings',
        arguments: const {'query': '闪记'},
      );
      final matching = (filtered['recordings'] as List)
          .cast<Map<String, dynamic>>();
      expect(matching.length, 1);
      final remoteRecId = matching.single['recording_id'] as String;

      final remoteMinutes = await _callRemoteMcpTool(
        baseUrl: baseUrl,
        token: token,
        name: 'get_minutes',
        arguments: {'recording_id': remoteRecId},
      );
      expect(remoteMinutes['hasMinutes'], isTrue);
      expect(
        (remoteMinutes['current'] as Map)['text'] as String,
        contains('明天上午十点确认闪记同步方案'),
      );

      // 5. Mac Koe binds to the same endpoint and automatically pulls both records
      await macController.bindMcpSyncFromText(pairingCode);
      expect(macController.mcpSyncState.phase, McpSyncPhase.idle);
      final macDocs = macController.minutes.documents;
      expect(macDocs.length, 2);
      final syncedMeeting = macDocs.firstWhere(
        (d) => d.bodyText.contains('闪记和 Cicada'),
      );
      expect(syncedMeeting.restore, isNotNull);
      expect(syncedMeeting.restore!['minutes'], isNotNull);
      final syncedTextOnly = macDocs.firstWhere(
        (d) => d.title.contains('买咖啡豆'),
      );
      expect(syncedTextOnly.bodyText, contains('埃塞俄比亚手冲咖啡豆'));
    },
  );

  testWidgets(
    'SettingsScreen external-ai-entry opens zero-config Agent setup sheet and binds from clipboard',
    (tester) async {
      const pairingCode = McpSyncConfig(
        baseUrl: 'https://koe-vps.example.com',
        token: 'token-abcdefghijklmnopqrstuvwxyz012345',
        mode: McpSyncMode.vps,
      );
      String clipboardText =
          'Agent 回复：已部署完成，连接码 ${pairingCode.encodePairingCode()}';

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return <String, dynamic>{'text': clipboardText};
            }
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map;
              clipboardText = '${args['text']}';
              return null;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final controller = RecorderController(
        loadPersistedState: false,
        analysisController: RecordingAnalysis(inMemory: true),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final entry = find.byKey(const ValueKey('external-ai-entry'));
      await tester.scrollUntilVisible(
        entry,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mcp-copy-vps-prompt')), findsOneWidget);
      expect(find.byKey(const ValueKey('mcp-copy-lan-prompt')), findsOneWidget);
      expect(find.byKey(const ValueKey('mcp-bind-clipboard')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mcp-bind-clipboard')));
      await tester.pumpAndSettle();

      expect(controller.mcpSyncConfig, isNotNull);
      expect(controller.mcpSyncConfig!.baseUrl, 'https://koe-vps.example.com');
      expect(
        find.textContaining('VPS 云端 · koe-vps.example.com'),
        findsWidgets,
      );
    },
  );
}
