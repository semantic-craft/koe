import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/recorder_controller.dart';
import 'file_types.dart';
import 'recording_navigation.dart';
import 'screens/minutes_document_screen.dart';

/// Picks a `.koepack` and restores it, then opens what it became.
Future<void> pickAndImportMaterialPack(BuildContext context) async {
  final selected = await openFile(
    confirmButtonText: '导入',
    acceptedTypeGroups: const [materialPackFileTypes],
  );
  if (selected == null || !context.mounted) return;
  await importMaterialPackFrom(context, selected.path);
}

/// Restores the pack at [path]; a damaged pack is reported and the library
/// stays as it was.
Future<void> importMaterialPackFrom(BuildContext context, String path) async {
  final messenger = ScaffoldMessenger.of(context);
  final controller = context.read<RecorderController>();
  messenger.showSnackBar(const SnackBar(content: Text('正在读取资料包…')));
  MaterialPackImportOutcome outcome;
  try {
    outcome = await controller.importMaterialPack(path);
  } catch (error) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            error is MaterialPackException
                ? '${error.message}；请检查资料库后重试'
                : error is StateError
                ? error.message
                : '导入未完成，部分资料可能已保存；请检查资料库后重试',
          ),
        ),
      );
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(outcome.message)));
  if (!context.mounted) return;
  final restored = outcome.path;
  if (restored != null) {
    RecordingNavigation.open(
      context,
      RecordingReference(
        fileId: controller.fileIdFromPath(restored),
        path: restored,
      ),
    );
  } else if (outcome.minutesId != null) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: 'minutes/${outcome.minutesId}'),
        builder: (_) => MinutesDocumentScreen(documentId: outcome.minutesId!),
      ),
    );
  }
}
