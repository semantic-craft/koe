import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/recorder_controller.dart';
import 'file_types.dart';

/// Picks one audio file and commits it to the original-audio library.
///
/// The controller owns copying, hashing and persistence. Cancelling the picker
/// creates no material and shows no success message.
Future<void> pickAndImportLocalAudio(BuildContext context) async {
  final selected = await openFile(
    confirmButtonText: '导入',
    acceptedTypeGroups: const [audioFileTypes],
  );
  if (selected == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('正在保存原件…')));
  try {
    final result = await context.read<RecorderController>().importLocalAudio(
      selected.path,
    );
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(result.duplicate ? '已复用资料库中的同一音频' : '原件已保存到资料库')),
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
