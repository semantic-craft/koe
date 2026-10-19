import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/screens/todos_screen.dart';
import 'package:provider/provider.dart';

/// Answers commitment prompts with canned JSON chosen by the transcript.
class _Assistant implements AnalysisService {
  _Assistant(this.answer);

  final String Function(String source) answer;

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async => answer(source);

  @override
  void dispose() {}
}

/// An in-memory Reminders/Calendar.
class _System implements SystemTasks {
  bool granted = true;
  bool offline = false;
  final Map<String, SystemSnapshot> items = {};
  var _next = 0;

  @override
  Future<bool> requestAccess(SystemTaskTarget target) async => granted;

  @override
  Future<String> save(
    SystemTaskTarget target, {
    String? existingId,
    required String title,
    DateTime? start,
    DateTime? end,
    bool hasTime = true,
    bool done = false,
    String? notes,
  }) async {
    if (offline) throw const SystemTasksUnavailable('offline');
    if (existingId != null && !items.containsKey(existingId)) {
      throw const SystemTasksUnavailable('missing');
    }
    final id = existingId ?? 'ext${_next++}';
    items[id] = SystemSnapshot(
      title: title,
      start: start,
      end: end,
      done: done,
    );
    return id;
  }

  @override
  Future<SystemSnapshot?> fetch(SystemTaskTarget target, String id) async {
    if (offline) throw const SystemTasksUnavailable('offline');
    return items[id];
  }
}

const _firstTalk = [
  TranscriptSegment(text: '我回去买牛奶。', start: Duration.zero),
  TranscriptSegment(text: '孩子想要一台相机。', start: Duration(seconds: 5)),
  TranscriptSegment(text: '小王说周五把资料发我。', start: Duration(seconds: 10)),
];
const _laterTalk = [
  TranscriptSegment(text: '牛奶已经买好了。', start: Duration.zero),
  TranscriptSegment(text: '那件事改到下周吧。', start: Duration(seconds: 4)),
];

String _answer(String source) {
  if (source.contains('牛奶已经')) {
    final milk = RegExp(r'\[(T\d+)\] 买牛奶').firstMatch(source)!.group(1);
    return '{"items":[],"updates":['
        '{"todo":"$milk","action":"done","segment":1},'
        '{"todo":null,"action":"reschedule","due":"2026-10-27","segment":2}]}';
  }
  return '```json\n{"items":['
      '{"type":"mine","title":"买牛奶","due":null,"segment":1},'
      '{"type":"wish","title":"相机","due":null,"segment":2},'
      '{"type":"others","title":"发资料","owner":"小王","due":"2026-10-23","segment":3}'
      '],"updates":[]}\n```';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-todos-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  RecorderController controller({
    TodoStore? store,
    SystemTasks? system,
    AnalysisService? assistant,
  }) => RecorderController(
    loadPersistedState: false,
    analysisController: RecordingAnalysis(inMemory: true),
    qwenSpeech: QwenSttService()..apiKeyOverride = 'test-key',
    todoStore: store,
    systemTasks: system,
    contextAnalysisService: assistant ?? _Assistant(_answer),
    libraryDirectory: Directory('${directory.path}/imports'),
  );

  Future<String> recording(
    RecorderController c,
    int id,
    List<TranscriptSegment> segments,
  ) async {
    final path = '${directory.path}/$id.wav';
    await File(path).writeAsBytes([1, 2, 3, 4]);
    c.exportedPaths.add(path);
    c.rememberTranscript(
      path,
      segments.map((s) => s.text).join(),
      segments: segments,
    );
    return path;
  }

  test('commitments become separate kinds, later words update the same '
      'todo, and unclear ones wait for the user', () async {
    final file = File('${directory.path}/todos.json');
    final store = TodoStore(file: file);
    final c = controller(store: store);
    addTearDown(c.dispose);
    final first = await recording(c, 1760850000, _firstTalk);
    final later = await recording(c, 1760936400, _laterTalk);

    expect(await c.extractTodos(RecordingReference(path: first)), 3);
    final byKind = {for (final todo in store.todos) todo.kind: todo};
    expect(byKind[TodoKind.mine]?.title, '买牛奶');
    expect(byKind[TodoKind.mine]?.quote, '我回去买牛奶。');
    expect(byKind[TodoKind.mine]?.source.start, Duration.zero);
    expect(byKind[TodoKind.mine]?.due, isNull);
    expect(byKind[TodoKind.others]?.owner, '小王');
    expect(byKind[TodoKind.others]?.source.start, const Duration(seconds: 10));
    expect(store.openMine.map((todo) => todo.title), ['买牛奶']);

    // Same words again: nothing new, no duplicate.
    expect(await c.extractTodos(RecordingReference(path: first)), 0);
    expect(store.todos, hasLength(3));

    expect(await c.extractTodos(RecordingReference(path: later)), 0);
    expect(byKind.length, 3);
    final milk = store.todoById(byKind[TodoKind.mine]!.id)!;
    expect(milk.status, TodoStatus.done);
    expect(store.clarifications.single.quote, '那件事改到下周吧。');
    expect(store.openMine, isEmpty);

    await store.idle;
    final reopened = TodoStore(file: file);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.todoById(milk.id)?.status, TodoStatus.done);
    expect(reopened.clarifications, hasLength(1));
  });

  test('a reminder is created once and stays in step with Reminders', () async {
    final system = _System();
    final store = TodoStore(inMemory: true);
    final c = controller(store: store, system: system);
    addTearDown(c.dispose);
    final path = await recording(c, 1760850000, _firstTalk);
    await c.extractTodos(RecordingReference(path: path));
    final milk = store.openMine.single;

    system.granted = false;
    await expectLater(
      c.exportTodoToReminders(milk.id),
      throwsA(isA<SystemTasksUnavailable>()),
    );
    expect(system.items, isEmpty);

    system.granted = true;
    await c.exportTodoToReminders(milk.id);
    await c.exportTodoToReminders(milk.id);
    expect(system.items, hasLength(1));
    final id = store.todoById(milk.id)!.reminder!.externalId;

    // Completed in Reminders → completed in Koe.
    system.items[id] = SystemSnapshot(title: '买牛奶', done: true);
    await c.syncSystemLinks();
    expect(store.todoById(milk.id)?.status, TodoStatus.done);

    // Renamed in Koe while offline and differently in Reminders → a
    // visible conflict, nothing silently overwritten.
    system.offline = true;
    await c.editTodo(milk.id, title: '买两盒牛奶');
    await pumpEventQueue();
    expect(store.todoById(milk.id)?.reminder?.unsynced, isTrue);
    system.items[id] = SystemSnapshot(title: '买豆浆', done: true);
    system.offline = false;
    await c.syncSystemLinks();
    expect(store.todoById(milk.id)?.reminder?.conflict?.title, '买豆浆');
    expect(store.todoById(milk.id)?.title, '买两盒牛奶');
    await c.resolveSystemConflict(
      milk.id,
      SystemTaskTarget.reminder,
      keepKoe: true,
    );
    expect(system.items[id]?.title, '买两盒牛奶');

    // Deleted in Reminders → only the link goes.
    system.items.remove(id);
    await c.syncSystemLinks();
    expect(store.todoById(milk.id)?.reminder, isNull);
    expect(store.todoById(milk.id)?.title, '买两盒牛奶');
  });

  testWidgets('nothing is written to Reminders until the user confirms', (
    tester,
  ) async {
    final system = _System();
    late RecorderController c;
    late Todo milk;
    await tester.runAsync(() async {
      c = controller(store: TodoStore(inMemory: true), system: system);
      final path = await recording(c, 1760850000, _firstTalk);
      await c.extractTodos(RecordingReference(path: path));
      milk = c.todos.openMine.single;
    });
    addTearDown(c.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: MaterialApp(home: TodoDetailScreen(todoId: milk.id)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('「我回去买牛奶。」'), findsNothing);
    expect(find.text('我回去买牛奶。'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('export-reminder')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('取消')),
    );
    await tester.pumpAndSettle();
    expect(system.items, isEmpty);

    await tester.tap(find.byKey(const ValueKey('export-reminder')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('confirm-export')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(system.items, hasLength(1));
    expect(find.text('提醒事项 · 已关联'), findsOneWidget);
  });
}
