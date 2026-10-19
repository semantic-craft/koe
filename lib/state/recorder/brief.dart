part of '../recorder_controller.dart';

/// Today's morning brief: what is open, what others promised that is due,
/// and — only when asked — yesterday's key points.
class MorningBrief {
  const MorningBrief({
    required this.day,
    required this.openMine,
    required this.followUps,
    required this.yesterday,
    required this.keyPoints,
  });

  final DateTime day;

  /// My open todos; overdue and due-today first.
  final List<Todo> openMine;

  /// Others' open commitments due today or earlier: worth checking on.
  final List<Todo> followUps;
  final DiaryMaterial yesterday;

  /// Generated key points, or null until the user asks for them.
  final DiaryEntry? keyPoints;

  String get key => briefKey(day);

  static String briefKey(DateTime day) {
    String two(int value) => value.toString().padLeft(2, '0');
    return 'brief:${day.year}-${two(day.month)}-${two(day.day)}';
  }
}

/// The morning brief on Today. The lists are read locally; yesterday's key
/// points cost a Qwen request and are only generated on the user's tap.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderBrief on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract final DiaryStore diary;
  DiaryMaterial diaryMaterial(DiaryPeriod period);
  bool diaryKeyBusy(String key);
  abstract final TodoStore todos;
  Future<void> _generateCited({
    required String key,
    required DiaryMaterial material,
    required String fingerprint,
    required String instruction,
    required bool confirmRetry,
  });
  // END DEPS

  MorningBrief morningBrief(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    final endOfDay = day.add(const Duration(days: 1));
    bool due(Todo todo) => todo.due != null && todo.due!.isBefore(endOfDay);
    final mine = todos.openMine.toList()
      ..sort((a, b) {
        if (due(a) != due(b)) return due(a) ? -1 : 1;
        return 0;
      });
    return MorningBrief(
      day: day,
      openMine: mine,
      followUps: [
        for (final todo in todos.todos)
          if (todo.open && todo.kind == TodoKind.others && due(todo)) todo,
      ],
      yesterday: diaryMaterial(
        DiaryPeriod.day(day.subtract(const Duration(days: 1))),
      ),
      keyPoints: diary.entryFor(MorningBrief.briefKey(day)),
    );
  }

  bool briefGenerating(DateTime now) =>
      diaryKeyBusy(MorningBrief.briefKey(now));

  /// Generates yesterday's key points for today's brief, on demand only.
  Future<void> generateBriefKeyPoints(
    DateTime now, {
    bool confirmRetry = false,
  }) {
    final brief = morningBrief(now);
    if (brief.yesterday.sources.isEmpty) {
      throw StateError('昨天没有已转写的资料');
    }
    return _generateCited(
      key: brief.key,
      material: brief.yesterday,
      fingerprint: analysisFingerprint(
        'brief\n${renderSourceLines(brief.yesterday.sources)}',
      ),
      instruction:
          '列出昨天最重要的 3–5 个要点，每行以【整理】开头、至少引用一个出处如 [S2]；'
          '只写资料里有的事，不推测情绪动机，不要 Markdown 标题或列表符号。',
      confirmRetry: confirmRetry,
    );
  }
}
