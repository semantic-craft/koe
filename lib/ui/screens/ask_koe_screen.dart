import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../platform/answer_speaker.dart';
import '../../platform/device_kind.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/cited_text.dart';
import '../widgets/hold_to_talk.dart';
import '../widgets/status_indicators.dart';
import '../widgets/koe_icon_button.dart';

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
///
/// Hold-to-talk here always means a question (#142, #112): the recognized
/// text is sent to the same flow as typed text. Answers can be read aloud
/// with a synthetic voice, off by default and labeled as such.
class AskKoeScreen extends StatefulWidget {
  const AskKoeScreen({super.key});

  @override
  State<AskKoeScreen> createState() => _AskKoeScreenState();
}

class _AskKoeScreenState extends State<AskKoeScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  String? _sessionId;
  bool _voiceMode = false;

  /// The newest answer already on screen; only later ones are read aloud.
  String? _heardAnswerId;
  String? _speakingId;
  late final AnswerSpeaker _speaker;

  /// Completes once a session is open; a send before that waits for it
  /// instead of dropping the question.
  late Future<void> _ready;

  @override
  void initState() {
    super.initState();
    _speaker = context.read<RecorderController>().answerSpeaker;
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
    _select(session);
  }

  void _select(AskSession session) {
    setState(() {
      _sessionId = session.id;
      _heardAnswerId = _lastAnswerId(session);
    });
    _input.text = session.draft;
  }

  String? _lastAnswerId(AskSession? session) => session?.messages
      .where((m) => m.role == AskRole.koe && m.status == AskStatus.done)
      .lastOrNull
      ?.id;

  Future<void> _speak(AskMessage message) async {
    setState(() => _speakingId = message.id);
    try {
      await _speaker.speak(speakableAnswer(message.text));
    } catch (_) {}
    if (mounted && _speakingId == message.id) {
      setState(() => _speakingId = null);
    }
  }

  Future<void> _stopSpeaking() async {
    setState(() => _speakingId = null);
    await _speaker.stop();
  }

  /// Reads a newly finished answer aloud when the user turned that on.
  void _readNewAnswer(RecorderController c, AskSession? session) {
    final id = _lastAnswerId(session);
    if (id == null || id == _heardAnswerId) return;
    _heardAnswerId = id;
    if (!c.asks.readAloud || !_speaker.available) return;
    final message = session!.messages.firstWhere((m) => m.id == id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_speak(message));
    });
  }

  Future<void> _toggleReadAloud() async {
    final c = context.read<RecorderController>();
    final on = !c.asks.readAloud;
    await c.asks.setReadAloud(on);
    if (!on && _speakingId != null) await _stopSpeaking();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(on ? '新回答会用合成语音朗读，不是录音原声' : '已关闭朗读')),
    );
  }

  Future<bool> _startVoice() async {
    await _ready;
    final id = _sessionId;
    if (id == null || !mounted) return false;
    return context.read<RecorderController>().startVoiceHold(
      VoiceTarget.ask,
      sessionId: id,
    );
  }

  @override
  void dispose() {
    if (_speakingId != null) unawaited(_speaker.stop());
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
                  _select(session);
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
    // While the finger is down the clip is still being recorded, not waiting.
    final holding = c.voiceHoldTarget == VoiceTarget.ask;
    final voice = holding ? null : session?.voice;
    final recognizing = _sessionId != null && c.voiceRecognizing(_sessionId!);
    final voiceError = c.voiceInputErrors[VoiceTarget.ask];
    final readAloud = c.asks.readAloud && _speaker.available;
    _readNewAnswer(c, session);
    return Scaffold(
      appBar: AppBar(
        title: const Text('问 Koe'),
        actions: [
          if (_speaker.available)
            KoeIconButton(
              key: const ValueKey('ask-read-aloud'),
              tooltip: readAloud ? '朗读回答：开（合成语音）' : '朗读回答：关',
              onPressed: _toggleReadAloud,
              icon: Icon(
                readAloud
                    ? Icons.record_voice_over_rounded
                    : Icons.voice_over_off_outlined,
              ),
            ),
          KoeIconButton(
            tooltip: '历史会话',
            onPressed: _history,
            icon: const Icon(Icons.history_rounded),
          ),
          KoeIconButton(
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
                            onSpeak: readAloud && !message.notice
                                ? () => _speak(message)
                                : null,
                          ),
                      ],
                    ),
            ),
            if (_speakingId != null) _SpeakingBar(onStop: _stopSpeaking),
            if (voice != null || recognizing)
              _VoiceClipCard(
                clip: voice,
                recognizing: recognizing,
                onRetry: () => c.retryVoiceQuestion(_sessionId!),
                onDiscard: () => c.discardVoiceQuestion(_sessionId!),
              )
            else if (voiceError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Text(
                  voiceError,
                  key: const ValueKey('ask-voice-error'),
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  KoeIconButton(
                    key: const ValueKey('ask-voice-toggle'),
                    tooltip: _voiceMode ? '改用文字输入' : '按住说话提问',
                    onPressed: () => setState(() => _voiceMode = !_voiceMode),
                    icon: Icon(
                      _voiceMode
                          ? Icons.keyboard_alt_outlined
                          : Icons.mic_none_rounded,
                    ),
                  ),
                  if (_voiceMode)
                    Expanded(
                      child: HoldToTalkButton(
                        key: const ValueKey('ask-hold-to-talk'),
                        label: c.phoneRecordingEnabled
                            ? '按住说话提问'
                            : (runsOnMac
                                  ? '按住说话当前不可用'
                                  : '按住说话仅在 iPhone 上提供'),
                        enabled:
                            c.phoneRecordingEnabled &&
                            !busy &&
                            voice == null &&
                            !recognizing,
                        onStart: _startVoice,
                        onSend: c.finishVoiceQuestion,
                        onCancel: c.cancelVoiceHold,
                      ),
                    )
                  else ...[
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The spoken question between release and sending: being recognized, or
/// kept with its reason after a failure or a restart.
class _VoiceClipCard extends StatelessWidget {
  const _VoiceClipCard({
    required this.clip,
    required this.recognizing,
    required this.onRetry,
    required this.onDiscard,
  });

  final AskVoiceClip? clip;
  final bool recognizing;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (recognizing) {
      body = const Row(
        children: [
          ThinkingDots(),
          SizedBox(width: 8),
          Expanded(child: Text('正在识别你说的问题…')),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            clip?.error ?? '上次说的问题还没识别完，录音已保留',
            key: const ValueKey('ask-voice-clip-message'),
          ),
          Row(
            children: [
              TextButton(
                key: const ValueKey('ask-voice-retry'),
                onPressed: onRetry,
                child: const Text('重新识别'),
              ),
              TextButton(
                key: const ValueKey('ask-voice-discard'),
                onPressed: onDiscard,
                child: const Text('丢弃这句'),
              ),
            ],
          ),
        ],
      );
    }
    return Container(
      key: const ValueKey('ask-voice-clip'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      decoration: BoxDecoration(
        color: AppColors.bgPanel,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 13),
        child: body,
      ),
    );
  }
}

/// Shown while an answer is read aloud, so the synthetic voice is never
/// taken for the recording and can always be stopped.
class _SpeakingBar extends StatelessWidget {
  const _SpeakingBar({required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
      child: Row(
        children: [
          const Icon(
            Icons.record_voice_over_rounded,
            size: 16,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '合成语音朗读中，不是录音原声',
              key: ValueKey('ask-speaking'),
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            key: const ValueKey('ask-stop-speaking'),
            onPressed: onStop,
            child: const Text('停止'),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.onRetry,
    required this.live,
    this.onSpeak,
  });

  final AskMessage message;
  final VoidCallback? onRetry;
  final bool live;
  final VoidCallback? onSpeak;

  @override
  Widget build(BuildContext context) {
    final mine = message.role == AskRole.user;
    final Widget body;
    if (mine) {
      body = message.viaVoice
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(message.text),
                const SizedBox(height: 2),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.mic_none_rounded,
                      size: 12,
                      color: AppColors.textSecondary,
                    ),
                    SizedBox(width: 2),
                    Text(
                      '语音识别 · 已发送',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            )
          : Text(message.text);
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
          if (message.notice || !message.grounded)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                message.notice ? '未执行' : '无依据',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                ),
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
          if (onSpeak != null)
            TextButton.icon(
              key: ValueKey('ask-speak-${message.id}'),
              onPressed: onSpeak,
              icon: const Icon(Icons.record_voice_over_rounded, size: 16),
              label: const Text('合成朗读'),
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
