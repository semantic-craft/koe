import 'dart:async';
import 'dart:convert';
import 'package:koe/state/recording_analysis.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'translation uses a dedicated system prompt for both text providers',
    () async {
      for (final compatible in [false, true]) {
        final client = MockClient((request) async {
          final messages =
              (jsonDecode(request.body) as Map)['messages'] as List;
          expect((messages.first as Map)['content'], translationSystemPrompt);
          expect((messages.first as Map)['content'], isNot(contains('用中文')));
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {'content': 'Hello'},
                },
              ],
            }),
            200,
          );
        });
        final analysis = RecordingAnalysis(
          inMemory: true,
          service: compatible
              ? OpenAiCompatibleAnalysisService(
                  client: client,
                  baseUrl: () => 'https://example.test/v1',
                )
              : QwenAnalysisService(client: client),
        );
        expect(
          await analysis.runTranslation(
            source: '你好',
            instruction: '翻译为英语',
            selectedModel: 'test',
            apiKey: 'test',
            abort: Completer<void>().future,
            isCurrent: () => true,
          ),
          'Hello',
        );
        analysis.dispose();
      }
    },
  );

  test(
    'Qwen analysis preserves workspace endpoint and rejects truncated output',
    () async {
      var truncated = false;
      final service = QwenAnalysisService(
        origin: () => 'https://test.cn-beijing.maas.aliyuncs.com',
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://test.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions',
          );
          final body = jsonDecode(request.body) as Map;
          expect(body['model'], 'qwen3.8-flash');
          expect(body['enable_thinking'], false);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': truncated ? 'length' : 'stop',
                  'message': {'content': '摘要 [S1]'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(service.dispose);
      Future<String> run() => service.generate(
        model: 'qwen3.8-flash',
        apiKey: 'test',
        source: '[S1] source',
        instruction: '总结',
        abort: Completer<void>().future,
      );
      expect(await run(), '摘要 [S1]');
      truncated = true;
      await expectLater(run(), throwsStateError);
    },
  );
}
