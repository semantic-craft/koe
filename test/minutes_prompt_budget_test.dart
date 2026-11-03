import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/recording_analysis.dart';

class _MinutesService implements AnalysisService {
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async => '''{"schemaVersion":2,"title":"确认任务","overview":"李明承诺发送清单。",
"topics":[],"terms":[],"decisions":[],"questions":[],
"actions":[{"text":"发送清单","owner":"李明","due":"未提及","sources":["S1"]}]}''';

  @override
  void dispose() {}
}

void main() {
  for (final template in builtInMeetingTemplates.where(
    (template) => template.customSectionTitlesEn.isNotEmpty,
  )) {
    test(
      '${template.id} in English reaches generation and saves minutes',
      () async {
        final manager = RecordingAnalysis(
          inMemory: true,
          service: _MinutesService(),
        );
        addTearDown(manager.dispose);
        const source = '李明：我来发送清单。';
        await manager.run(
          recording: 'meeting',
          source: source,
          apiKey: 'test',
          custom: true,
          templateId: template.id,
          resultSlot: 'minutes',
          instruction: buildMeetingMinutesPrompt(
            templateId: template.id,
            language: 'en',
          ),
          validateResult: validateMinutes,
          currentSource: () => source,
        );
        expect(manager.errors, isEmpty);
        final result = manager.results['meeting/minutes']!;
        expect(
          MeetingMinutes.parse(
            result.text,
            result.sources.length,
          ).actions.single.owner,
          '李明',
        );
      },
    );
  }
}
