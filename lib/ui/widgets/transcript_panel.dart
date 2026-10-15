import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import 'widgets.dart';

/// Live / final transcript card.
///
/// Use [compact] on the live home view to avoid duplicating large chrome.
class TranscriptPanel extends StatelessWidget {
  const TranscriptPanel({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final tokens = KoeTokens.of(context);
    final hasText =
        c.transcript.isNotEmpty || (c.transcriptPartial?.isNotEmpty ?? false);
    final show =
        c.autoTranscribe ||
        c.transcribing ||
        hasText ||
        c.transcriptError != null ||
        !c.sttConfigured;

    if (!show) return const SizedBox.shrink();

    final draft = c.transcript.isNotEmpty
        ? c.transcript
        : (c.transcriptPartial ?? '');

    if (compact) {
      if (!hasText && c.sttConfigured) return const SizedBox.shrink();
      return SurfaceCard(
        borderColor: tokens.border,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!c.sttConfigured)
              Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 15,
                    color: tokens.amber,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '请在设置中配置语音服务',
                      style: TextStyle(
                        color: tokens.amber,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              )
            else if (hasText)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '转写',
                      style: TextStyle(
                        color: tokens.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: draft));
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('转写已复制')));
                    },
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('复制'),
                  ),
                ],
              ),
          ],
        ),
      );
    }

    final active = c.streamingSttActive || c.transcribing;
    return SurfaceCard(
      borderColor: active ? tokens.accentBorder : tokens.border,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconBadge(
                icon: Icons.subtitles_outlined,
                size: 30,
                iconSize: 16,
                radius: 8,
                color: active ? tokens.accent : tokens.textSecondary,
                backgroundColor: active ? tokens.accentSoft : tokens.bgPanel,
                borderColor: active ? tokens.accentBorder : tokens.borderSoft,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  c.streamingSttActive
                      ? '实时转写'
                      : c.transcribing
                      ? '正在转写…'
                      : '转写',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    color: tokens.textPrimary,
                  ),
                ),
              ),
              if (active) ...[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: tokens.accent,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Switch.adaptive(
                value: c.autoTranscribe,
                activeTrackColor: tokens.accent.withValues(alpha: 0.45),
                activeThumbColor: tokens.accent,
                onChanged: c.setAutoTranscribe,
              ),
            ],
          ),
          if (!c.sttConfigured) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: tokens.amberSoft,
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(color: tokens.amberBorder),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 15,
                    color: tokens.amber,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '请在设置中配置语音服务',
                      style: TextStyle(
                        color: tokens.amber,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (c.transcriptError != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: tokens.coralSoft,
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(color: tokens.coralBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.error_outline_rounded,
                      size: 15,
                      color: tokens.coral,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      c.transcriptError!,
                      style: TextStyle(
                        color: tokens.coral,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (draft.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 180),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: tokens.bgPanel,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(color: tokens.borderSoft),
              ),
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: SelectionArea(
                    child: Text.rich(
                      _formatTranscriptSpan(draft, tokens),
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.55,
                        color: tokens.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: draft));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('转写已复制')));
                  },
                  icon: const Icon(Icons.copy_rounded, size: 15),
                  label: const Text('复制'),
                ),
                TextButton(
                  onPressed: c.clearTranscript,
                  child: const Text('清空'),
                ),
              ],
            ),
          ] else if (c.sttConfigured && c.autoTranscribe) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: tokens.bgPanel,
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(color: tokens.borderSoft),
              ),
              child: Row(
                children: [
                  Icon(
                    c.streamingSttActive
                        ? Icons.graphic_eq_rounded
                        : Icons.mic_none_rounded,
                    size: 15,
                    color: tokens.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.streamingSttActive
                          ? '正在转写…'
                          : c.speechProvider == SttProvider.moss
                          ? '录音结束后生成文字'
                          : '等待语音',
                      style: TextStyle(
                        color: tokens.textMuted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static TextSpan _formatTranscriptSpan(String text, KoeTokens tokens) {
    final speakerPattern = RegExp(r'^([^:：\n]{1,24}[：:])(.*)$');
    final match = speakerPattern.firstMatch(text);
    if (match == null) {
      return TextSpan(text: text);
    }
    return TextSpan(
      children: [
        TextSpan(
          text: match.group(1),
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: tokens.accent,
          ),
        ),
        TextSpan(text: match.group(2)),
      ],
    );
  }
}
