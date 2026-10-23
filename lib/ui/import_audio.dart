import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/recorder_controller.dart';
import '../theme/app_theme.dart';
import 'file_types.dart';
import 'widgets/expected_speakers.dart';

/// Picks one audio file, asks about how many people speak in it (R24.2) and
/// commits it to the original-audio library.
///
/// The controller owns copying, hashing and persistence. Cancelling the picker
/// or the dialog creates no material and shows no success message.
Future<void> pickAndImportLocalAudio(BuildContext context) async {
  final selected = await openFile(
    confirmButtonText: '导入',
    acceptedTypeGroups: const [audioFileTypes],
  );
  if (selected == null || !context.mounted) return;
  final choice = await showDialog<({int? expectedSpeakers})>(
    context: context,
    builder: (_) => _ImportAudioDialog(name: selected.name),
  );
  if (choice == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('正在保存原件…')));
  final controller = context.read<RecorderController>();
  try {
    final result = await controller.importLocalAudio(
      selected.path,
      expectedSpeakers: choice.expectedSpeakers,
    );
    if (!context.mounted) return;
    // A recording transcribed, or being transcribed, keeps its own number.
    final countKept =
        choice.expectedSpeakers != null &&
        controller.expectedSpeakersForPath(result.path) !=
            choice.expectedSpeakers;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(switch ((result.duplicate, countKept)) {
          (false, _) => '原件已保存到资料库',
          (true, false) => '已复用资料库中的同一音频',
          (true, true) => '已复用资料库中的同一音频；它已转写过或正在转写，人数没改，可在详情里重新区分发言人',
        }),
      ),
    );
  } catch (error) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(error is StateError ? error.message : '无法导入音频，请重试'),
      ),
    );
  }
}

class _ImportAudioDialog extends StatefulWidget {
  const _ImportAudioDialog({required this.name});

  final String name;

  @override
  State<_ImportAudioDialog> createState() => _ImportAudioDialogState();
}

class _ImportAudioDialogState extends State<_ImportAudioDialog> {
  int? _expectedSpeakers;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        '导入「${widget.name}」',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '大约几个人',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              '分发言人时按这个人数分；不确定就选自动判断。',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 8),
            ExpectedSpeakersChips(
              selected: _expectedSpeakers,
              onSelected: (count) => setState(() => _expectedSpeakers = count),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('confirm-import-audio'),
          onPressed: () =>
              Navigator.pop(context, (expectedSpeakers: _expectedSpeakers)),
          child: const Text('导入'),
        ),
      ],
    );
  }
}
