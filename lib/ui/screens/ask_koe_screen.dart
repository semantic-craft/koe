import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/cited_text.dart';
import '../widgets/status_indicators.dart';

void openAskKoe(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'ask-koe'),
      builder: (_) => const AskKoeScreen(),
    ),
  );
}

/// Ask Koe (#141): questions and follow-ups over the user's own recordings.
/// Answers say when nothing was found, and every cited sentence replays the
/// original audio. Leaving to read a source keeps the conversation and the
/// unsent draft.
class AskKoeScreen extends StatefulWidget {
  const AskKoeScreen({super.key});

  @override
  State<AskKoeScreen> createState() => _AskKoeScreenState();
}

class _AskKoeScreenState extends State<AskKoeScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  String? _sessionId;

  /// Completes once a session is open; a send before that waits for it
  /// instead of dropping the question.
  late Future<void> _ready;

  @override
  void initState() {
    super.initState();
    _ready = _open();
    _input.addListener(() {
      final id = _sessionId;
      if (id != null) {
        context.read<RecorderController>().asks.saveDraft(id, _input.text);
      }
    });
  }

  Future<void> _open({bool fresh = false}) async {
    final c = context.read<RecorderController>();
    await c.asks.load();
    var session = fresh ? null : c.asks.sessions.firstOrNull;
    session ??= await c.newAskSession();
    if (!mounted) return;
    setState(() => _sessionId = session!.id);
    _input.text = session.draft;
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    await _ready;
    final id = _sessionId;
    if (id == null || !mounted) return;
    final c = context.read<RecorderController>();
    if (c.askBusy(id)) return;
    _input.clear();
    try {
      await c.ask(id, text);
    } catch (error) {
      if (!mounted) return;
      _input.text = text;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is StateError ? error.message.toString() : '发送失败，问题已保留',
          ),
        ),
      );
    }
  }

  Future<void> _retry(AskMessage message) async {
    final c = context.read<RecorderController>();
    if (message.status == AskStatus.pending) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('上次回答结果未知'),
          content: const Text('请求发出后没有收到结果，可能已经计费。确认重新提问？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('先不'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('重新提问'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await c.retryAsk(_sessionId!);
  }

  void _history() {
    final c = context.read<RecorderController>();
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: AppMotion.sheetStyle(context),
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final session in c.asks.sessions)
              ListTile(
                title: Text(
                  session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${session.messages.length} 条消息'),
                selected: session.id == _sessionId,
                onTap: () {
                  Navigator.pop(sheetContext);
                  setState(() => _sessionId = session.id);
                  _input.text = session.draft;
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final session = c.asks.sessionById(_sessionId);
    final busy = _sessionId != null && c.askBusy(_sessionId!);
    final scope = c.askScope();
    final messages = session?.messages ?? const <AskMessage>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('问 Koe'),
        actions: [
          IconButton(
            tooltip: '历史会话',
            onPressed: _history,
            icon: const Icon(Icons.history_rounded),
          ),
          IconButton(
            key: const ValueKey('ask-new-session'),
            tooltip: '新会话',
            onPressed: busy ? null : () => _ready = _open(fresh: true),
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                [
                  '范围：${scope.withText} 条已转写的录音',
                  if (scope.processing > 0) '${scope.processing} 条处理中',
                  if (scope.withoutText - scope.processing > 0)
                    '${scope.withoutText - scope.processing} 条还没有文字',
                ].join(' · '),
                key: const ValueKey('ask-scope'),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            Expanded(
              child: messages.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          '问问你自己的录音，比如「上周和装修师傅定了什么」。'
                          '回答只依据你的资料，每句都能点回原声。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      ),
                    )
                  : ListView(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      children: [
                        for (final message in messages.reversed)
                          _Bubble(
                            message: message,
                            onRetry: busy ? null : () => _retry(message),
                            live: busy && message == messages.last,
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('ask-input'),
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: '输入问题',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  ValueListenableBuilder(
                    valueListenable: _input,
                    builder: (context, value, _) => IconButton.filled(
                      key: const ValueKey('ask-send'),
                      tooltip: '发送',
                      onPressed: busy || value.text.trim().isEmpty
                          ? null
                          : _send,
                      icon: const Icon(Icons.arrow_upward_rounded),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.onRetry,
    required this.live,
  });

  final AskMessage message;
  final VoidCallback? onRetry;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final mine = message.role == AskRole.user;
    final Widget body;
    if (mine) {
      body = Text(message.text);
    } else if (message.status == AskStatus.pending) {
      body = live
          ? const Row(
              mainAxisSize: MainAxisSize.min,
              children: [ThinkingDots(), SizedBox(width: 8), Text('正在查你的资料…')],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('这次回答没有收到结果。'),
                TextButton(onPressed: onRetry, child: const Text('确认后重试')),
              ],
            );
    } else if (message.status == AskStatus.failed) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message.text),
          TextButton(
            key: const ValueKey('ask-retry'),
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!message.grounded)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                '无依据',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ),
          CitedText(text: message.text, sources: message.sources),
          if (message.sources.isNotEmpty)
            Material(
              type: MaterialType.transparency,
              child: ExpansionTile(
                key: ValueKey('ask-sources-${message.id}'),
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '出处 ${message.sources.length}',
                  style: const TextStyle(fontSize: 12),
                ),
                children: [SourceList(sources: message.sources)],
              ),
            ),
        ],
      );
    }
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: mine
              ? AppColors.accentSoft
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: body,
      ),
    );
  }
}
