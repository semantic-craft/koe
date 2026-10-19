import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';

/// Shows what will be exported for [scope] and lets the user copy or share
/// it. Koe sends nothing by itself.
Future<void> showContextExportSheet(
  BuildContext context,
  ContextExportScope scope,
) {
  final c = context.read<RecorderController>();
  final (markdown, count) = c.exportContextMarkdown(scope);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '导出给外部 AI',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '$count 条资料，含转写原文、待办和出处（录音与时间位置），地点只到区县。'
              '复制后可粘贴到任意 AI 对话里。',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 320),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.borderStrong),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    markdown,
                    key: const ValueKey('context-export-preview'),
                    style: const TextStyle(fontSize: 12, height: 1.4),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('context-export-copy'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: markdown));
                      if (!sheetContext.mounted) return;
                      Navigator.pop(sheetContext);
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        const SnackBar(content: Text('已复制，可以粘贴给外部 AI')),
                      );
                    },
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: const Text('复制'),
                  ),
                ),
                if (Platform.isIOS || Platform.isMacOS) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('context-export-share'),
                      onPressed: () async {
                        final box =
                            sheetContext.findRenderObject() as RenderBox?;
                        await SharePlus.instance.share(
                          ShareParams(
                            text: markdown,
                            title: 'Koe 资料',
                            sharePositionOrigin: box == null
                                ? null
                                : box.localToGlobal(Offset.zero) & box.size,
                          ),
                        );
                      },
                      icon: const Icon(Icons.ios_share_rounded, size: 18),
                      label: const Text('分享'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
