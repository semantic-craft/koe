import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

Future<void> _settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 100),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 5),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-projects-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  int secondsAt(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

  Future<String> addRecording(RecorderController c, int id) async {
    final path = '${directory.path}/$id.wav';
    await File(path).writeAsBytes([1, 2, 3, 4]);
    c.exportedPaths.add(path);
    return path;
  }

  testWidgets('a new project collects discussions from different days', (
    tester,
  ) async {
    final now = DateTime.now();
    final today = secondsAt(DateTime(now.year, now.month, now.day, 10));
    final yesterday = secondsAt(DateTime(now.year, now.month, now.day - 1, 16));
    late RecorderController c;
    await tester.runAsync(() async {
      c = RecorderController(
        loadPersistedState: false,
        analysisController: RecordingAnalysis(inMemory: true),
        libraryDirectory: Directory('${directory.path}/imports'),
      );
      await addRecording(c, today);
      await addRecording(c, yesterday);
      await c.contextItems.load();
      await c.projects.load();
    });
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(KoeApp(controller: c));
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('nav-projects')));
    await _settle(tester);
    expect(find.text('项目尚未开放'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('create-project-empty')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('project-title')), '搬家');
    await tester.enterText(
      find.byKey(const ValueKey('project-goal')),
      '月底前搬进新家',
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('project-save')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await _settle(tester);
    expect(find.text('尚未形成明确下一步'), findsOneWidget);
    expect(find.byKey(const ValueKey('project-no-items')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('project-link-items')));
    await _settle(tester);
    await tester.tap(find.byKey(ValueKey('pick-recording:file:$today')));
    await tester.tap(find.byKey(ValueKey('pick-recording:file:$yesterday')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('project-link-save')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await _settle(tester);

    final project = c.projects.active.single;
    expect(c.contextItemsForProject(project.id).map((item) => item.id), [
      'recording:file:$yesterday',
      'recording:file:$today',
    ]);
    expect(
      find.byKey(ValueKey('timeline-item-recording:file:$today')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('timeline-item-recording:file:$yesterday')),
      findsOneWidget,
    );
    expect(find.text('${now.month}月${now.day}日'), findsOneWidget);
  });

  test('one item in two projects; deleting a project keeps recordings and '
      'todos and survives a restart', () async {
    final projectsFile = File('${directory.path}/projects.json');
    final todos = TodoStore(inMemory: true);
    final c = RecorderController(
      loadPersistedState: false,
      analysisController: RecordingAnalysis(inMemory: true),
      projectStore: ProjectStore(file: projectsFile),
      todoStore: todos,
      libraryDirectory: Directory('${directory.path}/imports'),
    );
    addTearDown(c.dispose);
    const id = 1760850000;
    final path = await addRecording(c, id);
    await c.contextItems.load();
    await c.projects.load();
    final move = await c.createProject('搬家');
    final budget = await c.createProject('预算');
    final item = c
        .contextItemsForDay(DateTime.fromMillisecondsSinceEpoch(id * 1000))
        .single;
    await c.setContextItemProjects(item.id, [move.id, budget.id]);
    final now = DateTime.now();
    await todos.put(
      Todo(
        id: 't1',
        kind: TodoKind.mine,
        title: '订搬家公司',
        source: ContextSource(recordingKey: 'file:$id', path: path),
        quote: '我来订搬家公司。',
        projectIds: [move.id],
        createdAt: now,
        updatedAt: now,
      ),
    );

    expect(c.contextItemsForProject(move.id).single.id, item.id);
    expect(c.contextItemsForProject(budget.id).single.id, item.id);
    expect(c.exportedPaths, [path]);
    expect(c.projectProgress(move.id).next?.title, '订搬家公司');
    expect(c.projectProgress(budget.id).next, isNull);

    await c.deleteProject(move.id);
    expect(c.contextItemsForProject(budget.id).single.id, item.id);
    expect(c.contextItemsForProject(move.id), isEmpty);
    expect(todos.todoById('t1')?.projectIds, isEmpty);
    expect(File(path).existsSync(), isTrue);

    final reopened = ProjectStore(file: projectsFile);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.projects.map((p) => p.title), ['预算']);
  });
}
