import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../import_audio.dart';
import '../recording_navigation.dart';
import '../widgets/scan_sheet.dart';

enum NewRecordingAction { phone, importAudio, retrieveDevice }

Future<void> handleNewRecordingAction(
  BuildContext context,
  NewRecordingAction action,
) async {
  switch (action) {
    case NewRecordingAction.importAudio:
      await pickAndImportLocalAudio(context);
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
      break;
  }
}

/// Entry sheet for a new material (#131).
///
/// Phone recording is not implemented until its own ticket, so the row stays
/// visible but disabled with an honest label instead of a fake recording state.
Future<NewRecordingAction?> showNewRecordingSheet(BuildContext context) {
  return showModalBottomSheet<NewRecordingAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
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
            const SizedBox(height: 12),
            _RecordOption(
              key: const ValueKey('new-record-import'),
              icon: Icons.audio_file_outlined,
              title: '导入本地音频',
              subtitle: '从文件中选择 WAV、M4A、MP3 等',
              onTap: () =>
                  Navigator.pop(sheetContext, NewRecordingAction.importAudio),
            ),
            _RecordOption(
              key: const ValueKey('new-record-device'),
              icon: Icons.headphones_rounded,
              title: '取回设备录音',
              subtitle: '从已连接的录音豆下载',
              onTap: () => Navigator.pop(
                sheetContext,
                NewRecordingAction.retrieveDevice,
              ),
            ),
            _RecordOption(
              key: const ValueKey('new-record-phone'),
              icon: Icons.mic_none_rounded,
              title: '手机录音',
              subtitle: '尚未开放；当前请用录音豆或导入音频',
              trailing: '尚未开放',
            ),
          ],
        ),
      ),
    ),
  );
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
      child: Material(
        color: enabled ? AppColors.bgCard : AppColors.bgPanel,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    icon,
                    color: enabled
                        ? AppColors.textPrimary
                        : AppColors.textFaint,
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
    );
  }
}

/// Global Ask Koe entry.
///
/// Conversation answers arrive with the P2 ticket. Until then this sheet says
/// so and routes to real title search and original-audio reading instead of
/// showing canned answers.
Future<void> showAskKoeSheet(
  BuildContext context, {
  VoidCallback? onOpenLibrary,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '问 Koe',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              '连续问答尚未开放。现在可以在「资料」里按标题搜索、打开原文并回听原件。',
              style: TextStyle(color: AppColors.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('知道了'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('ask-koe-open-library'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      onOpenLibrary?.call();
                    },
                    child: const Text('去资料'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
