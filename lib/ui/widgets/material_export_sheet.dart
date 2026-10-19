import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';

/// Hands a finished export file to the system share/save sheet. Returns
/// false when the user closed the sheet without sending it.
typedef MaterialShare =
    Future<bool> Function(BuildContext context, File file, String title);

Future<bool> _systemShare(BuildContext context, File file, String title) async {
  final box = context.findRenderObject() as RenderBox?;
  final result = await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path)],
      title: title,
      sharePositionOrigin: box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
  return result.status != ShareResultStatus.dismissed;
}

enum MaterialExportKind { reading, pack }

/// 资料详情 → 更多 → 导出 (#145): choose a reading copy or a restorable
/// pack, decide about the original audio, see what goes in, then share.
Future<void> showMaterialExportSheet(
  BuildContext context,
  RecordingReference reference, {
  MaterialShare? share,
}) {
  return showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: AppMotion.sheetStyle(context),
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: MaterialExportPanel(
        reference: reference,
        share: share ?? _systemShare,
      ),
    ),
  );
}

class MaterialExportPanel extends StatefulWidget {
  const MaterialExportPanel({
    super.key,
    required this.reference,
    required this.share,
  });

  final RecordingReference reference;
  final MaterialShare share;

  @override
  State<MaterialExportPanel> createState() => _MaterialExportPanelState();
}

class _MaterialExportPanelState extends State<MaterialExportPanel> {
  MaterialExportKind _kind = MaterialExportKind.pack;
  bool _includeAudio = false;
  bool _preparing = false;
  bool _cancelled = false;
  String? _error;

  Future<void> _export(MaterialExportPreview preview) async {
    final c = context.read<RecorderController>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    void toast(String message) =>
        messenger?.showSnackBar(SnackBar(content: Text(message)));
    setState(() {
      _preparing = true;
      _cancelled = false;
      _error = null;
    });
    File? file;
    try {
      file = _kind == MaterialExportKind.reading
          ? await c.exportReadingText(widget.reference)
          : await c.exportMaterialPack(
              widget.reference,
              includeAudio: _includeAudio && preview.audioAvailable,
              cancelled: () => _cancelled,
            );
    } on MaterialPackCancelled {
      if (mounted) setState(() => _preparing = false);
      toast('已取消导出，没有生成文件');
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _error = error is MaterialPackException ? error.message : '导出失败，请重试';
      });
      return;
    }
    if (!mounted) return;
    if (_cancelled) {
      await _discard(file);
      setState(() => _preparing = false);
      toast('已取消导出，没有生成文件');
      return;
    }
    bool sent;
    try {
      sent = await widget.share(context, file, preview.title);
    } catch (_) {
      await _discard(file);
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _error = '分享失败，文件没有发出；请重试';
      });
      return;
    }
    await _discard(file);
    if (!mounted) return;
    setState(() => _preparing = false);
    if (!sent) {
      toast('没有分享或保存，可再次导出');
      return;
    }
    Navigator.pop(context);
    toast(
      _kind == MaterialExportKind.reading
          ? '已导出阅读稿'
          : _includeAudio && preview.audioAvailable
          ? '已导出资料包（含原音频）'
          : '已导出资料包（不含原音频）',
    );
  }

  /// Export files only live until the share sheet is done with them.
  Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final preview = c.materialExportPreview(widget.reference);
    final pack = _kind == MaterialExportKind.pack;
    final packBlocked = pack ? preview.identityUnavailable : null;
    final withAudio = pack && _includeAudio && preview.audioAvailable;
    final rows = <(String, String)>[
      (
        '正文',
        !preview.hasText
            ? '还没有正文'
            : preview.edited
            ? '含你的校订'
            : '转写原文',
      ),
      if (preview.segments > 0) ('时间码', '${preview.segments} 段'),
      if (preview.speakers > 0) ('发言人', '${preview.speakers} 位'),
      if (preview.bookmarks > 0) ('书签', '${preview.bookmarks} 个'),
      if (preview.place != null) ('地点', preview.place!),
      if (preview.topic != null) ('主题', preview.topic!),
      (
        '原音频',
        !pack
            ? '不包含（阅读稿只含文字）'
            : withAudio
            ? '包含（${_size(preview.audioBytes!)}）'
            : '不包含；导入后需补配同一份原音频才能回听',
      ),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '导出资料',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            preview.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<MaterialExportKind>(
            key: const ValueKey('material-export-kind'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: MaterialExportKind.pack,
                label: Text('可恢复资料包'),
              ),
              ButtonSegment(
                value: MaterialExportKind.reading,
                label: Text('阅读稿'),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: _preparing
                ? null
                : (value) => setState(() {
                    _kind = value.single;
                    _error = null;
                  }),
          ),
          const SizedBox(height: 8),
          Text(
            pack
                ? '.koepack 文件，可导入另一台设备或重装后的 Koe，恢复时间码、发言人、校订和书签。'
                : 'Markdown 文字，给人阅读或粘贴到别处；不能重新导入 Koe。',
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
          if (pack) ...[
            const SizedBox(height: 4),
            SwitchListTile.adaptive(
              key: const ValueKey('material-export-audio'),
              contentPadding: EdgeInsets.zero,
              title: const Text('包含原音频'),
              subtitle: Text(
                preview.audioAvailable
                    ? '${_size(preview.audioBytes!)}，导入后可直接回听'
                    : preview.audioUnavailable!,
              ),
              value: withAudio,
              onChanged: preview.audioAvailable && !_preparing
                  ? (value) => setState(() => _includeAudio = value)
                  : null,
            ),
          ],
          const SizedBox(height: 8),
          Container(
            key: const ValueKey('material-export-contents'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.bgPanel,
              borderRadius: BorderRadius.circular(AppRadii.panel),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (label, value) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 64,
                          child: Text(
                            label,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            value,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (pack)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      '不含 API Key、录音豆配对信息和本机文件路径。',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (packBlocked != null || _error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error ?? packBlocked!,
              key: const ValueKey('material-export-error'),
              style: const TextStyle(fontSize: 13, color: AppColors.coral),
            ),
          ],
          const SizedBox(height: 12),
          if (_preparing)
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(withAudio ? '正在准备资料包（含原音频）…' : '正在准备…')),
                TextButton(
                  key: const ValueKey('material-export-cancel'),
                  onPressed: _cancelled
                      ? null
                      : () => setState(() => _cancelled = true),
                  child: const Text('取消'),
                ),
              ],
            )
          else
            FilledButton.icon(
              key: const ValueKey('material-export-share'),
              onPressed: packBlocked != null ? null : () => _export(preview),
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: Text(pack ? '导出资料包' : '导出阅读稿'),
            ),
        ],
      ),
    );
  }
}

String _size(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
