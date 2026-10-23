import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../audio/input_level_watch.dart';
import '../../platform/device_kind.dart';
import '../../platform/phone_recorder.dart' show MicInput;
import '../../state/recorder_controller.dart';
import '../../state/recording_bookmarks.dart';
import '../../theme/app_theme.dart';
import '../import_audio.dart';
import '../import_pack.dart';
import '../recording_navigation.dart';
import '../widgets/hold_to_talk.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/status_indicators.dart';
import 'text_capture_sheet.dart';

const macMicrophonePrivacyUrl =
    'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone';

Future<void> openMicrophonePrivacySettings() async {
  if (runsOnMac) {
    await launchUrl(
      Uri.parse(macMicrophonePrivacyUrl),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    return;
  }
  await openAppSettings();
}

enum NewRecordingAction {
  phone,
  textCapture,
  importAudio,
  importPack,
  retrieveDevice,
}

Future<void> handleNewRecordingAction(
  BuildContext context,
  NewRecordingAction action,
) async {
  switch (action) {
    case NewRecordingAction.importAudio:
      await pickAndImportLocalAudio(context);
      break;
    case NewRecordingAction.importPack:
      await pickAndImportMaterialPack(context);
      break;
    case NewRecordingAction.retrieveDevice:
      final controller = context.read<RecorderController>();
      if (!controller.connected) {
        await showScanDevicesSheet(context);
        return;
      }
      RecordingNavigation.of(context)?.onSelectTab?.call(2);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('在「设备端」标签选择要取回的录音')));
      break;
    case NewRecordingAction.phone:
      if (context.read<RecorderController>().allDayListening) {
        await showTextCaptureSheet(context, allDay: true);
      } else {
        await showPhoneRecordingSheet(context);
      }
      break;
    case NewRecordingAction.textCapture:
      await showTextCaptureSheet(context);
      break;
  }
}

/// Records from the phone microphone until the user saves or discards.
///
/// The sheet cannot be swiped away mid-take, so a running recording always
/// has visible controls.
Future<void> showPhoneRecordingSheet(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final saved = await showModalBottomSheet<String>(
    context: context,
    sheetAnimationStyle: AppMotion.sheetStyle(context),
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => const PhoneRecordingPanel(),
  );
  if (saved != null) {
    messenger.showSnackBar(
      SnackBar(content: Text(runsOnMac ? '麦克风录音已保存为原件' : '手机录音已保存为原件')),
    );
  }
}

class PhoneRecordingPanel extends StatefulWidget {
  const PhoneRecordingPanel({super.key});

  @override
  State<PhoneRecordingPanel> createState() => _PhoneRecordingPanelState();
}

class _PhoneRecordingPanelState extends State<PhoneRecordingPanel> {
  bool _stopping = false;
  final _notes = TextEditingController();

  /// The notes as last kept, without text an input method is composing.
  String _keptNotes = '';

  @override
  void initState() {
    super.initState();
    _keptNotes = context.read<RecorderController>().phoneRecordingNotes;
    _notes.text = _keptNotes;
    _notes.addListener(_onNotesEdited);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = context.read<RecorderController>();
      if (!controller.phoneRecordingActive) {
        unawaited(controller.startPhoneRecording());
      }
    });
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  /// Puts the recording time in front of each line the user begins (#400),
  /// then keeps the notes.
  void _onNotesEdited() {
    final value = _notes.value;
    if (value.composing.isValid || value.text == _keptNotes) return;
    final controller = context.read<RecorderController>();
    final stamped = stampNewNoteLine(
      _keptNotes,
      value.text,
      controller.phoneRecordingElapsed,
    );
    _keptNotes = stamped ?? value.text;
    if (stamped != null) {
      _notes.value = TextEditingValue(
        text: stamped,
        selection: TextSelection.collapsed(offset: stamped.length),
      );
    }
    controller.setPhoneRecordingNotes(_keptNotes);
  }

  void _markHighlight() {
    if (_stopping) return;
    final at = context.read<RecorderController>().markPhoneRecordingHighlight();
    if (at != null) unawaited(HapticFeedback.selectionClick());
  }

  Future<void> _stop() async {
    setState(() => _stopping = true);
    final path = await context.read<RecorderController>().stopPhoneRecording();
    if (!mounted) return;
    setState(() => _stopping = false);
    if (path != null) Navigator.of(context).pop(path);
  }

  Future<void> _discard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('放弃这段录音？'),
        content: const Text('录音文件会被删除，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('继续录音'),
          ),
          TextButton(
            key: const ValueKey('confirm-discard-phone-recording'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<RecorderController>().discardPhoneRecording();
    if (mounted) Navigator.of(context).pop();
  }

  /// System back mid-take: leaving ends the take, so confirm first and
  /// save on yes; the take is never dropped silently.
  Future<void> _confirmLeave() async {
    if (_stopping) return;
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('正在录音'),
        content: const Text('返回会结束并保存这段录音。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('继续录音'),
          ),
          TextButton(
            key: const ValueKey('confirm-leave-phone-recording'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('结束并保存'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) await _stop();
  }

  @override
  Widget build(BuildContext context) {
    // Only what the panel shows; the clock and the level meter redraw on
    // their own, so a 71-minute take never redraws the whole panel (R25).
    final (
      active,
      paused,
      error,
      permissionDenied,
      highlights,
      levelHint,
      mic,
      micNotice,
    ) = context.select(
      (RecorderController c) => (
        c.phoneRecordingActive,
        c.phoneRecordingPaused,
        c.phoneRecordingError,
        c.phoneRecordingPermissionDenied,
        c.phoneRecordingHighlights,
        c.phoneRecordingLevelHint,
        c.phoneRecordingMic,
        c.phoneRecordingMicNotice,
      ),
    );
    final controller = context.read<RecorderController>();
    final markButton = OutlinedButton.icon(
      key: const ValueKey('mark-phone-recording-highlight'),
      onPressed: _stopping ? null : _markHighlight,
      icon: const Icon(Icons.star_border_rounded),
      label: const Text('标重点'),
    );
    return PopScope(
      canPop: !active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: CallbackShortcuts(
        bindings: {
          SingleActivator(
            LogicalKeyboardKey.keyB,
            meta: runsOnApple,
            control: !runsOnApple,
          ): _markHighlight,
        },
        child: Focus(
          autofocus: true,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                24,
                20,
                20 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (active && !paused) ...[
                        const BreathingDot(),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        active
                            ? (paused
                                  ? '已暂停'
                                  : (runsOnMac ? '麦克风录音中' : '手机录音中'))
                            : (runsOnMac ? '麦克风录音' : '手机录音'),
                        key: const ValueKey('phone-recording-title'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const _RecordingClock(),
                  if (active) ...[
                    const SizedBox(height: 8),
                    Center(
                      child: _LevelMeter(level: controller.phoneRecordingLevel),
                    ),
                  ],
                  if (active && runsOnMac) ...[
                    const SizedBox(height: 6),
                    Text(
                      mic?.label ?? '系统默认麦克风',
                      key: const ValueKey('phone-recording-mic'),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                  if (active && micNotice != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      micNotice,
                      key: const ValueKey('phone-recording-mic-notice'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.amber,
                      ),
                    ),
                  ],
                  if (active && levelHint != null) ...[
                    const SizedBox(height: 12),
                    _LevelHintNotice(
                      hint: levelHint,
                      onDismiss: controller.dismissPhoneRecordingLevelHint,
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error,
                      key: const ValueKey('phone-recording-error'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                    if (permissionDenied) ...[
                      const SizedBox(height: 8),
                      Center(
                        child: OutlinedButton(
                          key: const ValueKey('open-microphone-settings'),
                          onPressed: openMicrophonePrivacySettings,
                          child: const Text('去系统设置'),
                        ),
                      ),
                    ],
                  ],
                  if (active) ...[
                    const SizedBox(height: 16),
                    TextField(
                      key: const ValueKey('phone-recording-notes'),
                      controller: _notes,
                      minLines: 3,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                        labelText: '我的笔记',
                        hintText: '边听边记，每行会记下当时的录音时间',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        runsOnMac
                            ? Tooltip(message: '标重点（⌘B）', child: markButton)
                            : markButton,
                        const SizedBox(width: 12),
                        if (highlights.isNotEmpty)
                          Expanded(
                            child: Text(
                              '已标 ${highlights.length} 处 · 最近 '
                              '${recordingTimeLabel(highlights.last)}',
                              key: const ValueKey('phone-recording-highlights'),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (active) ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            key: ValueKey(
                              paused
                                  ? 'resume-phone-recording'
                                  : 'pause-phone-recording',
                            ),
                            onPressed: _stopping
                                ? null
                                : paused
                                ? controller.resumePhoneRecording
                                : controller.pausePhoneRecording,
                            icon: Icon(
                              paused
                                  ? Icons.fiber_manual_record_rounded
                                  : Icons.pause_rounded,
                            ),
                            label: Text(paused ? '继续' : '暂停'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            key: const ValueKey('stop-phone-recording'),
                            onPressed: _stopping ? null : _stop,
                            icon: const Icon(Icons.stop_rounded),
                            label: const Text('结束并保存'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      key: const ValueKey('discard-phone-recording'),
                      onPressed: _stopping ? null : _discard,
                      child: const Text('放弃这段录音'),
                    ),
                  ] else
                    TextButton(
                      key: const ValueKey('close-phone-recording'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The take's recording time. It ticks on its own, so the rest of the panel
/// is not redrawn every half second.
class _RecordingClock extends StatefulWidget {
  const _RecordingClock();

  @override
  State<_RecordingClock> createState() => _RecordingClockState();
}

class _RecordingClockState extends State<_RecordingClock> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _clock(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final hours = d.inHours;
    final rest =
        '${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
    return hours > 0 ? '$hours:$rest' : rest;
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _clock(context.read<RecorderController>().phoneRecordingElapsed),
      key: const ValueKey('phone-recording-elapsed'),
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 40,
        fontWeight: FontWeight.w300,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// The microphone level of the take, redrawn on its own with each reading.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level});

  final ValueListenable<double> level;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '麦克风音量',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.xs),
        child: SizedBox(
          width: 200,
          height: 4,
          child: ColoredBox(
            color: AppColors.bgMuted,
            child: ValueListenableBuilder(
              valueListenable: level,
              builder: (context, value, _) => FractionallySizedBox(
                key: const ValueKey('phone-recording-level'),
                alignment: Alignment.centerLeft,
                widthFactor: value,
                child: const ColoredBox(color: AppColors.accent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shiyin's hints about the microphone (`Views/RecordingView.swift`), each
/// dismissable for the rest of the take.
class _LevelHintNotice extends StatelessWidget {
  const _LevelHintNotice({required this.hint, required this.onDismiss});

  final InputLevelHint hint;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final text = switch (hint) {
      InputLevelHint.silent => '麦克风没有收到声音：可能被静音、被其他应用占用，或选错了麦克风。',
      InputLevelHint.quiet => '声音有点小：把麦克风放近说话的人一点。',
      InputLevelHint.noisy => '背景有点吵，转写和区分发言人可能不准。',
    };
    return DecoratedBox(
      key: const ValueKey('phone-recording-level-hint'),
      decoration: BoxDecoration(
        color: AppColors.amberSoft,
        border: Border.all(color: AppColors.amberBorder),
        borderRadius: BorderRadius.circular(AppRadii.panel),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Icon(
              hint == InputLevelHint.silent
                  ? Icons.mic_off_rounded
                  : Icons.graphic_eq_rounded,
              size: 18,
              color: AppColors.amber,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Tooltip(
              message: '这次录音不再提示这件事',
              child: TextButton(
                key: const ValueKey('dismiss-phone-recording-level-hint'),
                onPressed: onDismiss,
                child: const Text('知道了'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Entry sheet for a new material (#131).
///
/// Phone recording is iPhone-only; elsewhere the row stays visible but
/// disabled with an honest label instead of a fake recording state. The top
/// of the sheet records a quick note by holding to talk (#142), with typing
/// as the alternative; either one is saved as material and nothing in it is
/// ever carried out.
Future<NewRecordingAction?> showNewRecordingSheet(BuildContext context) {
  return showModalBottomSheet<NewRecordingAction>(
    context: context,
    sheetAnimationStyle: AppMotion.sheetStyle(context),
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _NewRecordingPanel(),
  );
}

class _NewRecordingPanel extends StatefulWidget {
  const _NewRecordingPanel();

  @override
  State<_NewRecordingPanel> createState() => _NewRecordingPanelState();
}

class _NewRecordingPanelState extends State<_NewRecordingPanel> {
  final _text = TextEditingController();
  bool _typing = false;
  bool _savingText = false;
  String? _savedPath;
  String? _savedText;

  @override
  void initState() {
    super.initState();
    final controller = context.read<RecorderController>();
    if (runsOnMac && controller.phoneRecordingEnabled) {
      unawaited(controller.refreshPhoneMicInputs());
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _sendVoice() async {
    final path = await context.read<RecorderController>().finishVoiceNote();
    if (!mounted || path == null) return;
    setState(() {
      _savedPath = path;
      _savedText = null;
    });
  }

  Future<void> _saveText() async {
    setState(() => _savingText = true);
    try {
      final document = await context.read<RecorderController>().saveTextNote(
        _text.text,
      );
      if (!mounted) return;
      _text.clear();
      setState(() {
        _savedText = document.title;
        _savedPath = null;
        _typing = false;
      });
    } on StateError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _savingText = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RecorderController>();
    final phoneRecording = controller.phoneRecordingEnabled;
    final voiceError = controller.voiceInputErrors[VoiceTarget.note];
    final saved = _savedPath == null
        ? null
        : controller.recordingView(RecordingReference(path: _savedPath));
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '新记录',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              runsOnMac ? '原件先保存到本机，再决定是否转写或整理。' : '原件先保存到手机，再决定是否转写或整理。',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            if (_typing) ...[
              TextField(
                key: const ValueKey('new-record-text'),
                controller: _text,
                autofocus: true,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  hintText: '写下要记的事',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setState(() => _typing = false),
                    child: const Text('改用语音'),
                  ),
                  const Spacer(),
                  ValueListenableBuilder(
                    valueListenable: _text,
                    builder: (context, value, _) => FilledButton(
                      key: const ValueKey('new-record-text-save'),
                      onPressed: _savingText || value.text.trim().isEmpty
                          ? null
                          : _saveText,
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              HoldToTalkButton(
                key: const ValueKey('new-record-hold-to-talk'),
                label: phoneRecording
                    ? '按住说话记一条'
                    : (runsOnMac ? '按住说话当前不可用' : '按住说话仅在 iPhone 上提供'),
                enabled: phoneRecording,
                onStart: () => controller.startVoiceHold(VoiceTarget.note),
                onSend: _sendVoice,
                onCancel: controller.cancelVoiceHold,
              ),
              TextButton(
                key: const ValueKey('new-record-type'),
                onPressed: () => setState(() => _typing = true),
                child: const Text('改用文字记一条'),
              ),
            ],
            if (voiceError != null && !_typing)
              Text(
                voiceError,
                key: const ValueKey('new-record-voice-error'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
            if (saved != null) _SavedNote(view: saved),
            if (_savedText != null)
              _SavedNote(title: _savedText!, line: '文字已保存到资料'),
            const SizedBox(height: 8),
            _RecordOption(
              key: const ValueKey('new-record-phone'),
              icon: Icons.mic_none_rounded,
              title: runsOnMac ? '麦克风录音' : '手机录音',
              subtitle: phoneRecording
                  ? controller.allDayListening
                        ? '全天监听已打开：开始后一直识别、只留文字'
                        : (runsOnMac ? '用麦克风录下来，保存为原件' : '用手机麦克风录下来，保存为原件')
                  : (runsOnMac
                        ? '当前不可用；这里请用录音豆或导入音频'
                        : '只在 iPhone 上提供；这里请用录音豆或导入音频'),
              trailing: phoneRecording
                  ? null
                  : (runsOnMac ? '不可用' : '仅 iPhone'),
              onTap: phoneRecording
                  ? () => Navigator.pop(context, NewRecordingAction.phone)
                  : null,
            ),
            _RecordOption(
              key: const ValueKey('new-record-text-capture'),
              icon: Icons.subject_rounded,
              title: '纯文字记录',
              subtitle: phoneRecording
                  ? '一直识别你说的话，只留文字、不存录音；断网也不丢'
                  : (runsOnMac ? '当前不可用' : '只在 iPhone 上提供'),
              trailing: phoneRecording
                  ? null
                  : (runsOnMac ? '不可用' : '仅 iPhone'),
              onTap: phoneRecording
                  ? () => Navigator.pop(context, NewRecordingAction.textCapture)
                  : null,
            ),
            if (runsOnMac && phoneRecording)
              _MicPicker(
                inputs: controller.phoneMicInputs,
                choice: controller.phoneMicChoice,
                onChanged: controller.choosePhoneMic,
              ),
            _RecordOption(
              key: const ValueKey('new-record-import'),
              icon: Icons.audio_file_outlined,
              title: '导入本地音频',
              subtitle: '从文件中选择 WAV、M4A、MP3 等',
              onTap: () =>
                  Navigator.pop(context, NewRecordingAction.importAudio),
            ),
            _RecordOption(
              key: const ValueKey('new-record-pack'),
              icon: Icons.inventory_2_outlined,
              title: '导入资料包',
              subtitle: '恢复 Koe 导出的 .koepack，已有的资料不会重复',
              onTap: () =>
                  Navigator.pop(context, NewRecordingAction.importPack),
            ),
            _RecordOption(
              key: const ValueKey('new-record-device'),
              icon: Icons.headphones_rounded,
              title: '取回设备录音',
              subtitle: '从已连接的录音豆下载',
              onTap: () =>
                  Navigator.pop(context, NewRecordingAction.retrieveDevice),
            ),
          ],
        ),
      ),
    );
  }
}

/// What became of the note just made: saved, then its transcript as it
/// arrives, or why there is none yet.
class _SavedNote extends StatelessWidget {
  const _SavedNote({this.view, this.title, this.line});

  final RecordingViewData? view;
  final String? title;
  final String? line;

  @override
  Widget build(BuildContext context) {
    final view = this.view;
    final String status;
    String? text;
    if (view == null) {
      status = line!;
    } else if (view.text.trim().isNotEmpty) {
      status = '已保存为原件 · 已转写';
      text = view.text.trim();
    } else if (view.error != null) {
      status = '已保存为原件 · ${view.error}';
    } else if (view.processing) {
      status = '已保存为原件 · 正在转写';
    } else if (view.speechReady) {
      status = '已保存为原件 · 等待转写';
    } else {
      status = '已保存为原件 · 配置语音服务后可转写';
    }
    return Container(
      key: const ValueKey('new-record-saved'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bgPanel,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            view?.title ?? title!,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            status,
            key: const ValueKey('new-record-saved-status'),
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          if (text != null) ...[
            const SizedBox(height: 6),
            Text(text, maxLines: 4, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }
}

/// The microphone Koe records from on the Mac (#402), for the takes, text
/// capture and hold-to-talk started after a change; one already running
/// keeps its own.
class _MicPicker extends StatelessWidget {
  const _MicPicker({
    required this.inputs,
    required this.choice,
    required this.onChanged,
  });

  static const _systemDefault = '';

  final List<MicInput> inputs;
  final MicInput? choice;
  final ValueChanged<MicInput?> onChanged;

  @override
  Widget build(BuildContext context) {
    final chosen = choice;
    final missing =
        chosen != null && !inputs.any((input) => input.id == chosen.id);
    final selected = chosen?.id ?? _systemDefault;
    return Padding(
      key: const ValueKey('phone-mic-picker'),
      padding: const EdgeInsets.only(top: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('phone-mic-picker-$selected'),
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: '麦克风',
          isDense: true,
          border: OutlineInputBorder(),
        ),
        items: [
          const DropdownMenuItem(value: _systemDefault, child: Text('系统默认')),
          for (final input in inputs)
            DropdownMenuItem(
              value: input.id,
              child: Text(input.label, overflow: TextOverflow.ellipsis),
            ),
          if (missing)
            DropdownMenuItem(
              value: chosen.id,
              child: Text(
                '${chosen.label}（没有连接，用系统默认）',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (id) {
          if (id == null || id == selected) return;
          onChanged(inputs.where((input) => input.id == id).firstOrNull);
        },
      ),
    );
  }
}

class _RecordOption extends StatelessWidget {
  const _RecordOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: MergeSemantics(
        child: Semantics(
          button: true,
          enabled: enabled,
          child: Material(
            color: enabled ? AppColors.bgCard : AppColors.bgPanel,
            borderRadius: BorderRadius.circular(AppRadii.card),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadii.card),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        icon,
                        color: enabled
                            ? AppColors.textPrimary
                            : AppColors.textMuted,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: enabled
                                    ? AppColors.textPrimary
                                    : AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (trailing != null)
                        Text(
                          trailing!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        )
                      else
                        const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
