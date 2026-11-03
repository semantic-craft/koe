import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:koe/ui/widgets/live_meeting_panel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/live_minutes_store.dart';
import 'package:koe/state/live_minutes.dart';
import 'package:koe/ai/stt_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('discarded minutes never publish when a later session starts', () async {
    final store = LiveMinutesStore(inMemory: true);
    final c = RecorderController(
      loadPersistedState: false,
      liveMeetingStore: store,
    );
    c.beginLiveMeeting('discard', recordingKey: 'audio:/discard.wav');
    c.liveMinutes =
        LiveMinutes(
            sessionId: 'discard',
            store: store,
            request: (_) async => 'unused',
          )
          ..active =
              '{"title":"discarded","overview":"old","topics":[],"decisions":[],"actions":[],"questions":[]}';
    await c.discardLiveMeeting('discard');
    await c.finishLiveMeeting('discard');
    expect(c.analysis.results, isEmpty);
    expect(await store.read('discard'), isNull);
    c.dispose();
  });
  testWidgets('live controls fit a phone and are off until explicitly chosen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = RecorderController(loadPersistedState: false);
    c.beginLiveMeeting('ui');
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: c,
        child: const MaterialApp(home: Scaffold(body: LiveMeetingPanel())),
      ),
    );
    expect(find.text('实时纪要与双语字幕'), findsOneWidget);
    await tester.tap(find.text('实时纪要与双语字幕'));
    await tester.pumpAndSettle();
    expect(find.text('实时整理'), findsOneWidget);
    expect(c.liveMinutesEnabled, isFalse);
    expect(tester.takeException(), isNull);
    c.dispose();
  });
  test(
    'explicit enable owns one session and persists caption-only source on stop',
    () async {
      final store = LiveMinutesStore(inMemory: true);
      final c = RecorderController(
        loadPersistedState: false,
        liveMeetingStore: store,
      );
      c.beginLiveMeeting('one', recordingKey: 'document:one');
      await c.setLiveCaptionsEnabled(true);
      c.acceptLiveSpeech(
        'one',
        'connection',
        const SttStreamEvent(
          type: 'partial',
          text: '你好',
          speechFinal: true,
          translationTurns: [
            SttTranslationTurn(
              targetLanguage: 'zh',
              sourceLanguage: 'en',
              text: '你好',
              sourceText: '你好',
              isFinal: true,
            ),
          ],
        ),
      );
      await c.finishLiveMeeting('one');
      final saved = await store.read('one/captions');
      expect((saved!['entries'] as List).single['text'], '你好');
      c.beginLiveMeeting('two', recordingKey: 'document:two');
      c.acceptLiveSpeech(
        'one',
        'old',
        const SttStreamEvent(type: 'done', text: '不能进入下一场'),
      );
      expect(c.liveMeetingSegments, isEmpty);
      expect(c.liveCaptionsEnabled, isFalse);
      c.dispose();
    },
  );
}
