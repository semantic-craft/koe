import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/minutes_document.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../file_types.dart';
import '../widgets/highlight.dart';
import 'recording_detail_screen.dart';

/// Read-only 妙记 text import with an optional audio pairing.
///
/// A text-only document never shows a fake player. When audio is paired but
/// the timecodes are unreliable, only whole-file playback is offered.
class MinutesDocumentScreen extends StatefulWidget {
  const MinutesDocumentScreen({
    super.key,
    required this.documentId,
    this.focusLine,
  });

  final String documentId;

  /// The sentence a citation points at: repeated above the text and marked
  /// in it, so the reader lands on it without scrolling.
  final int? focusLine;

  @override
  State<MinutesDocumentScreen> createState() => _MinutesDocumentScreenState();
}

class _MinutesDocumentScreenState extends State<MinutesDocumentScreen> {
  bool _attaching = false;
  String? _notice;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final document = c.minutesDocumentById(widget.documentId);
    if (document == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('导入文字')),
        body: const Center(child: Text('这条导入文字已不存在')),
      );
    }
    final audioPath = document.audioPath;
    final audioAsset = audioPath == null
        ? null
        : c.recordingAssetForPath(audioPath);
    final audioAvailable =
        audioPath != null &&
        audioAsset != null &&
        audioAsset.originalComplete &&
        File(audioPath).existsSync();
    final playing = audioPath != null && c.playingPath == audioPath;
    final canSeek = document.timingReliable && audioAvailable;
    final focus = widget.focusLine;
    final focusValid =
        focus != null && focus >= 0 && focus < document.segments.length;
    final header = <Widget>[
      _MetaRow(label: '来源', value: document.sourceName),
      _MetaRow(
        label: '发生时间',
        value: document.capturedAt == null
            ? '未知（导入文件没有提供）'
            : _formatDateTime(document.capturedAt!),
      ),
      _MetaRow(label: '导入时间', value: _formatDateTime(document.importedAt)),
      _MetaRow(
        label: '原音频',
        value: audioPath == null
            ? '尚未补配'
            : !audioAvailable
            ? '已配对，但原件不可用'
            : document.unaligned
            ? '已取得，时码不可靠'
            : '已配对，可按句回听',
      ),
      const SizedBox(height: 12),
      if (audioPath == null)
        _StatusCard(
          key: const ValueKey('minutes-text-only'),
          title: '只有文字，尚未补配音频',
          message: '可以阅读和整理，点击文字不会播放或推进计时。',
          action: _attaching
              ? null
              : FilledButton.icon(
                  key: const ValueKey('minutes-attach-audio'),
                  onPressed: () => _attach(document),
                  icon: const Icon(Icons.audio_file_outlined),
                  label: Text(_attaching ? '正在核验…' : '补配原音频'),
                ),
        )
      else ...[
        if (document.unaligned)
          const _StatusCard(
            key: ValueKey('minutes-unaligned'),
            title: '音频存在，但时码不可靠',
            message: '没有把这段文字绑定到具体秒数；可以整段播放，不能点句定位。',
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('minutes-play-all'),
                onPressed: !audioAvailable
                    ? null
                    : () => playing
                          ? c.togglePlayPause()
                          : c.playExported(audioPath),
                icon: Icon(
                  playing && c.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
                label: Text(playing && c.isPlaying ? '暂停整段' : '播放整段'),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey('minutes-replace-audio'),
              onPressed: _attaching ? null : () => _attach(document),
              child: const Text('重新配对'),
            ),
          ],
        ),
      ],
      if (document.warning != null) ...[
        const SizedBox(height: 10),
        Text(
          document.warning!,
          style: const TextStyle(
            fontSize: 13,
            color: AppColors.textSecondary,
            height: 1.4,
          ),
        ),
      ],
      if (_notice != null) ...[
        const SizedBox(height: 10),
        Text(
          _notice!,
          key: const ValueKey('minutes-attach-result'),
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
      ],
      if (focusValid) ...[
        const SizedBox(height: 18),
        Container(
          key: const ValueKey('minutes-focus-line'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '出处 · 第 ${focus + 1} 句\n${document.segments[focus].text}',
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
      ],
      const SizedBox(height: 18),
      const Text(
        '正文',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
    ];
    return Scaffold(
      key: ValueKey('minutes-document-${document.id}'),
      appBar: AppBar(title: Text(document.title)),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        itemCount: header.length + document.segments.length,
        itemBuilder: (context, index) {
          if (index < header.length) return header[index];
          final line = index - header.length;
          final segment = document.segments[line];
          return _SegmentRow(
            key: segment.highlighted
                ? ValueKey('minutes-highlight-$line')
                : null,
            segment: segment,
            focused: focusValid && line == focus,
            showTime: document.timingReliable,
            onTap: canSeek
                ? () => c.playFrom(
                    audioPath,
                    segment.start,
                    fileId: c.fileIdFromPath(audioPath),
                  )
                : null,
          );
        },
      ),
    );
  }

  Future<void> _attach(MinutesDocument document) async {
    final selected = await openFile(acceptedTypeGroups: const [audioFileTypes]);
    if (selected == null || !mounted) return;
    setState(() {
      _attaching = true;
      _notice = null;
    });
    final outcome = await context.read<RecorderController>().attachMinutesAudio(
      document.id,
      selected.path,
    );
    if (!mounted) return;
    final restored = outcome.restoredPath;
    if (restored != null) {
      // The pack is complete again: the recording replaces this text record.
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(outcome.message)));
      final fileId = context.read<RecorderController>().fileIdFromPath(
        restored,
      );
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => RecordingDetailScreen(
            reference: RecordingReference(fileId: fileId, path: restored),
          ),
        ),
      );
      return;
    }
    setState(() {
      _attaching = false;
      _notice = outcome.message;
    });
  }
}

class _SegmentRow extends StatelessWidget {
  const _SegmentRow({
    super.key,
    required this.segment,
    required this.showTime,
    this.focused = false,
    this.onTap,
  });

  final MinutesSegment segment;
  final bool showTime;
  final bool focused;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(fontSize: 15, height: 1.55);
    final textStyle = segment.highlighted
        ? base.merge(highlightTextStyle(context))
        : base;
    final content = Container(
      padding: EdgeInsets.symmetric(vertical: 8, horizontal: focused ? 8 : 0),
      decoration: focused
          ? BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTime || segment.speaker != null || segment.highlighted)
            Text(
              [
                if (segment.highlighted) '★ 重点',
                if (showTime) _formatDuration(segment.start),
                if (segment.speaker != null) segment.speaker!,
              ].join(' · '),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          const SizedBox(height: 3),
          if (onTap == null)
            SelectableText(segment.text, style: textStyle)
          else
            Text(segment.text, style: textStyle),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      child: Semantics(button: true, label: '回听这一段', child: content),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    super.key,
    required this.title,
    required this.message,
    this.action,
  });

  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.bgSubtle,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            message,
            style: const TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppColors.textSecondary,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 10), action!],
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _formatDuration(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
