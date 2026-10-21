import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../import_audio.dart';
import '../import_pack.dart';
import '../recording_navigation.dart';
import '../widgets/hold_to_talk.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/status_indicators.dart';
import 'text_capture_sheet.dart';

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
    builder: (_) => const PhoneRecordingPanel(),
  );
  if (saved != null) {
    messenger.showSnackBar(const SnackBar(content: Text('手机录音已保存为原件')));
  }
}

class PhoneRecordingPanel extends StatefulWidget {
  const PhoneRecordingPanel({super.key});

  @override
  State<PhoneRecordingPanel> createState() => _PhoneRecordingPanelState();
}

class _PhoneRecordingPanelState extends State<PhoneRecordingPanel> {
  Timer? _ticker;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
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
    _ticker?.cancel();
    super.dispose();
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

  String _clock(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final hours = d.inHours;
    final rest =
        '${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
    return hours > 0 ? '$hours:$rest' : rest;
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RecorderController>();
    final active = controller.phoneRecordingActive;
    final paused = controller.phoneRecordingPaused;
    final error = controller.phoneRecordingError;
    return PopScope(
      canPop: !active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
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
                    active ? (paused ? '已暂停' : '手机录音中') : '手机录音',
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
              Text(
                _clock(controller.phoneRecordingElapsed),
                key: const ValueKey('phone-recording-elapsed'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w300,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error,
                  key: const ValueKey('phone-recording-error'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSecondary),
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
            const Text(
              '原件先保存到手机，再决定是否转写或整理。',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
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
                label: phoneRecording ? '按住说话记一条' : '按住说话仅在 iPhone 上提供',
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
              title: '手机录音',
              subtitle: phoneRecording
                  ? controller.allDayListening
                        ? '全天监听已打开：开始后一直识别、只留文字'
                        : '用手机麦克风录下来，保存为原件'
                  : '只在 iPhone 上提供；这里请用录音豆或导入音频',
              trailing: phoneRecording ? null : '仅 iPhone',
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
                  : '只在 iPhone 上提供',
              trailing: phoneRecording ? null : '仅 iPhone',
              onTap: phoneRecording
                  ? () => Navigator.pop(context, NewRecordingAction.textCapture)
                  : null,
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
