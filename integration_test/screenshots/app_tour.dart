// Screenshot tour of the main phone pages with sample data, for before/after
// comparisons of visual changes. It asserts nothing and is not part of
// `check`. Run on a booted iOS simulator:
//
//   flutter drive -d <simulator-id> \
//     --driver=test_driver/screenshot_driver.dart \
//     --target=integration_test/screenshots/app_tour.dart
//
// PNGs land in build/screenshots/ (override with KOE_SCREENSHOT_DIR).
// Everything lives in a temporary folder and in-memory stores; no BLE device,
// credential or personal data is touched.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/main.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/screens/ask_koe_screen.dart';
import 'package:koe/ui/screens/new_recording_sheet.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:koe/ui/screens/todos_screen.dart';
import 'package:koe/ui/widgets/scan_sheet.dart';

class _Assistant implements AnalysisService {
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    final label = RegExp(r'\[(S\d+)\][^\n]*开工').firstMatch(source)?.group(1);
    return label == null ? '没有找到相关的话。' : '师傅说下周一开工 [$label]。';
  }

  @override
  void dispose() {}
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone page tour', (tester) async {
    final directory = await Directory.systemTemp.createTemp('koe-tour-');
    final topics = TopicStore(inMemory: true);
    final c = RecorderController(
      loadPersistedState: false,
      topicsEnabled: true,
      topicStore: topics,
      analysisController: RecordingAnalysis(inMemory: true),
      qwenSpeech: QwenSttService()..apiKeyOverride = 'tour-key',
      contextAnalysisService: _Assistant(),
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${directory.path}/imports'),
    );

    final now = DateTime.now();
    Future<String> add(DateTime at, String? text, {String? name}) async {
      final id = at.millisecondsSinceEpoch ~/ 1000;
      final path = '${directory.path}/${name ?? id}.wav';
      await File(path).writeAsBytes([1, 2, 3, 4]);
      c.exportedPaths.add(path);
      if (text != null) {
        c.rememberTranscript(
          path,
          text,
          segments: [TranscriptSegment(text: text, start: Duration.zero)],
        );
      }
      return path;
    }

    final morning = now.subtract(const Duration(hours: 3));
    final a = await add(morning, '装修师傅说下周一开工。预算控制在二十万以内。');
    await add(now.subtract(const Duration(hours: 1)), '晚上和朋友吃饭，聊到搬家。');
    await add(now.subtract(const Duration(minutes: 20)), null, name: '散步');
    await c.contextItems.load();
    final move = await c.createProject('搬家', goal: '月底前搬完');
    final renovation = await topics.createTopic(
      kind: TopicKind.general,
      title: '装修',
    );
    final fileKey = 'file:${morning.millisecondsSinceEpoch ~/ 1000}';
    await topics.moveRecording(fileKey, renovation.id);
    c.contextItemsForDay(now);
    await c.setContextItemProjects('recording:$fileKey', [move.id]);
    await c.setContextItemTopics('recording:$fileKey', [renovation.id]);
    for (final (id, title, kind) in [
      ('t1', '周五量房', TodoKind.mine),
      ('t2', '确认开工日期', TodoKind.others),
    ]) {
      await c.todos.put(
        Todo(
          id: id,
          kind: kind,
          title: title,
          owner: kind == TodoKind.others ? '装修师傅' : null,
          source: ContextSource(recordingKey: fileKey),
          quote: '装修师傅说下周一开工。',
          projectIds: [move.id],
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    final session = await c.newAskSession();
    await c.ask(session.id, '装修什么时候开工？');

    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // Flutter on iOS renders into a platform view; switch to an image
    // surface once so takeScreenshot can read pixels.
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();

    Future<void> shot(String name) async {
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await binding.takeScreenshot(name);
    }

    BuildContext shell() => tester.element(find.byType(Scaffold).first);
    Future<void> pushAndShot(String name, Widget page) async {
      Navigator.of(shell()).push(MaterialPageRoute<void>(builder: (_) => page));
      await shot(name);
      Navigator.of(shell()).pop();
      await tester.pumpAndSettle();
    }

    await shot('01-today');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await shot('02-today-scrolled');
    await tester.tap(find.byKey(const ValueKey('nav-projects')));
    await shot('03-projects');
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await shot('04-library');
    await tester.tap(find.byKey(ValueKey('recording-row-$a')));
    await shot('05-recording-detail');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-today')));
    await tester.pumpAndSettle();

    await pushAndShot('06-settings', const SettingsScreen(showBack: true));
    await pushAndShot('07-ask-koe', const AskKoeScreen());
    await pushAndShot('08-todos', const TodosScreen());

    c.devices = [
      ScannedDevice(
        id: 'tour-d3200',
        name: 'soundcore Work',
        rssi: -52,
        isD3200: true,
      ),
      ScannedDevice(id: 'tour-other', name: 'Other BLE', rssi: -80),
    ];
    showScanDevicesSheet(shell());
    await shot('09-scan-devices');
    Navigator.of(shell()).pop();
    await tester.pumpAndSettle();

    showNewRecordingSheet(shell());
    await shot('10-new-record');
    Navigator.of(shell()).pop();
    await tester.pumpAndSettle();

    c.dispose();
    topics.dispose();
    await directory.delete(recursive: true);
  });
}
