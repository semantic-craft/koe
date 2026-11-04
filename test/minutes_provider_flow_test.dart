import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/recording_analysis.dart';

String _normalized(String text) => text.replaceAll(RegExp(r'\s+'), '');

bool _containsAlternative(String text, Object? expected) {
  final alternatives = expected is String
      ? [expected]
      : (expected as List).cast<String>();
  return alternatives.any(
    (value) => _normalized(text).contains(_normalized(value)),
  );
}

Iterable<MinuteItem> _items(MeetingMinutes minutes) sync* {
  for (final (_, items) in minutes.sections) {
    for (final item in items) {
      yield item;
      if (item is MinuteTopic) {
        yield* item.points;
        yield* item.fishbone?.branches ?? const <MinuteCause>[];
      }
    }
  }
}

String _itemText(MinuteItem item) => switch (item) {
  MinuteTopic topic => '${topic.text}\n${topic.summary}',
  MinuteCause cause => '${cause.text}\n${cause.detail}',
  _ => item.text,
};

class _ProviderBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  final enabled = Platform.environment['KOE_VERIFY_PROVIDER'] == '1';
  if (enabled) _ProviderBinding();
  test(
    'authorized audio uses real ASR and LLM with persisted sourced minutes',
    () async {
      final environment = Platform.environment;
      final audio = environment['KOE_MINUTES_AUDIO']!;
      final key = environment['DASHSCOPE_API_KEY']!;
      final manifest =
          jsonDecode(
                await File(
                  environment['KOE_MINUTES_EXPECTATIONS']!,
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final directory = Directory(environment['KOE_MINUTES_PROOF_DIR']!);
      final state = File('${directory.path}/provider-state.json');
      Future<void> checkpoint(String status) => state.writeAsString(
        jsonEncode({
          'stage': status,
          'at': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      final oldDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {};
      addTearDown(() => debugPrint = oldDebugPrint);
      final asr = QwenSttService(taskTimeout: const Duration(minutes: 12));
      addTearDown(asr.dispose);
      asr.onSending = () => checkpoint('asr-submitting-result-unknown');
      await checkpoint('asr-preparing-upload');
      final transcript = await asr.transcribePath(
        audio,
        apiKey: key,
        baseUrl: environment['DASHSCOPE_HTTP_BASE_URL'],
        model: environment['KOE_MINUTES_ASR_MODEL'],
        language: 'zh',
      );
      await File(
        '${directory.path}/provider-transcript.txt',
      ).writeAsString(transcript.text, flush: true);
      await checkpoint('asr-completed');
      final facts = (manifest['source_facts'] as List).cast<Map>();
      for (var index = 0; index < facts.length; index++) {
        expect(
          _containsAlternative(transcript.text, facts[index]['source']),
          isTrue,
          reason: 'ASR did not preserve source fact $index',
        );
      }
      final file = File('${directory.path}/provider-analysis.json');
      final analysis = RecordingAnalysis(
        file: file,
        service: QwenAnalysisService(
          origin: () =>
              environment['DASHSCOPE_HTTP_BASE_URL'] ??
              QwenSttService.defaultBaseUrl,
        ),
      );
      addTearDown(analysis.dispose);
      await checkpoint('llm-requesting-result-unknown');
      await analysis.run(
        recording: 'authorized-provider-sample',
        source: transcript.text,
        apiKey: key,
        custom: true,
        templateId: minutesTemplateId,
        resultSlot: 'minutes',
        instruction: buildMeetingMinutesPrompt(),
        modelOverride: environment['KOE_MINUTES_LLM_MODEL'],
        validateResult: validateMinutes,
        avoidDuplicateCharges: true,
        currentSource: () => transcript.text,
      );
      const slot = 'authorized-provider-sample/minutes';
      expect(
        analysis.results.containsKey(slot),
        isTrue,
        reason: 'Actual LLM did not produce a valid persisted minutes result',
      );
      final result = analysis.results[slot]!;
      expect(result.isDraft, isFalse);
      final restored = RecordingAnalysis(file: file);
      addTearDown(restored.dispose);
      await restored.load();
      expect(
        restored.results[slot]?.fingerprint == result.fingerprint,
        isTrue,
        reason: 'Persisted result revision was not read back',
      );
      expect(
        restored.results[slot]?.text == result.text,
        isTrue,
        reason: 'Persisted result content was not read back',
      );
      final minutes = MeetingMinutes.parse(
        result.text,
        result.sources.length,
        sourceTexts: result.sources,
      );
      expect(minutes.schemaVersion, 2);
      expect(
        minutes.topics.whereType<MinuteTopic>().isNotEmpty,
        isTrue,
        reason: 'No chapter with layered content was generated',
      );
      final items = _items(minutes).toList();
      for (var index = 0; index < facts.length; index++) {
        final fact = facts[index];
        final supported = items.any((item) {
          if (!_containsAlternative(_itemText(item), fact['minutes'])) {
            return false;
          }
          return item.sources.any(
            (id) => _containsAlternative(
              result.sources[int.parse(id.substring(1)) - 1],
              fact['source'],
            ),
          );
        });
        expect(
          supported,
          isTrue,
          reason: 'Minutes fact $index lacks the expected content and source',
        );
      }
      final generated = _normalized(minutes.encode());
      for (
        var index = 0;
        index < (manifest['forbidden_minutes'] as List).length;
        index++
      ) {
        final forbidden =
            (manifest['forbidden_minutes'] as List)[index] as String;
        expect(
          generated.contains(_normalized(forbidden)),
          isFalse,
          reason: 'Minutes contain forbidden assertion $index',
        );
      }
      await checkpoint('verified-and-persisted');
      await File('${directory.path}/provider-proof.json').writeAsString(
        jsonEncode({
          'real_asr': true,
          'real_llm': true,
          'persisted_readback': true,
          'facts_and_sources_checked': true,
          'fact_count': facts.length,
          'chapter_count': minutes.topics.length,
          'revision': result.fingerprint,
          'asr_model':
              environment['KOE_MINUTES_ASR_MODEL'] ??
              QwenSttService.defaultModel,
          'llm_model': result.model,
        }),
        flush: true,
      );
    },
    skip: enabled
        ? false
        : 'Only scripts/verify-minutes-flow provider may invoke paid services',
    timeout: const Timeout(Duration(minutes: 18)),
  );
}
