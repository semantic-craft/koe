import 'dart:async';
import 'dart:convert';
import 'package:anker_recorder/state/recording_analysis.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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
