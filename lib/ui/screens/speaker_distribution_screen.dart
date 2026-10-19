import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/stt_types.dart';
import '../../state/recorder_controller.dart';
import '../../state/speaker_distribution.dart';
import '../../theme/app_theme.dart';
import '../transcript_jump.dart';

/// 「发言人」view of one recording (#143): who spoke when, how much, and
/// the segment times that open the matching sentence.
///
/// Built from the same segments the reader shows, after the user's speaker
/// corrections, so a fix made in the text shows up here at once.
class SpeakerDistributionScreen extends StatefulWidget {
  const SpeakerDistributionScreen({
    super.key,
    required this.reference,
    required this.onOpenSource,
  });

  final RecordingReference reference;

  /// Opens the sentence at a segment and, when the audio is here, plays it.
  final ValueChanged<TranscriptJump> onOpenSource;

  @override
  State<SpeakerDistributionScreen> createState() =>
      _SpeakerDistributionScreenState();
}

class _SpeakerDistributionScreenState extends State<SpeakerDistributionScreen> {
  static const _collapsedChips = 12;
  final _expanded = <String?>{};

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final recording = c.recordingView(widget.reference);
    final path = recording.path;
    final source = normalizeSttText(recording.text);
    final aliases = path == null
        ? const <String, String>{}
        : c.speakerAliasesForPath(path);
    final segments =
        transcriptSegmentsMatchText(
          recording.segments,
          source,
          aliases: aliases,
        )
        ? recording.segments
        : const <TranscriptSegment>[];
    final audioChanged = c.recordingAudioChanged(widget.reference);
    final duration = path == null || !recording.originalPresent || audioChanged
        ? null
        : c.localDurationForPath(path);
    final locatable =
        recording.originalPresent &&
        !recording.audioLocked &&
        !audioChanged &&
        transcriptSegmentsLocatable(segments, duration: duration);
    final distribution = segments.isEmpty
        ? null
        : buildSpeakerDistribution(segments, total: duration);

    String label(String? id) {
      if (id == null) return '未标注发言人';
      final alias = aliases[id]?.trim();
      return alias == null || alias.isEmpty ? '说话人 $id' : alias;
    }

    final notices = <Widget>[
      if (recording.processing)
        _Notice(
          key: const ValueKey('speaker-processing'),
          message: distribution == null
              ? '正在转写，完成后按新结果统计发言分布。'
              : '正在重新转写，完成后按新结果统计；下面仍是当前版本。',
        ),
      if (recording.error != null)
        _Notice(
          key: const ValueKey('speaker-error'),
          error: true,
          message: distribution == null
              ? '转写没有完成：${recording.error}\n重新转写成功后才能统计发言分布。'
              : '重新转写没有完成：${recording.error}\n下面是当前版本的统计。',
        ),
      if (!recording.processing &&
          recording.error == null &&
          distribution == null)
        source.isEmpty
            ? const _Notice(
                key: ValueKey('speaker-no-transcript'),
                message: '还没有转写文字。转写完成后，这里显示谁在什么时候说话。',
              )
            : _Notice(
                key: const ValueKey('speaker-no-segments'),
                message: recording.manuallyEdited
                    ? '正文校订后，原来的分段时码不再对应文字，无法统计发言分布；文字仍可阅读。'
                    : '这份转写没有带时码的发言分段，无法统计发言分布；文字仍可阅读。',
              ),
      if (distribution != null && !distribution.hasLabels)
        const _Notice(
          key: ValueKey('speaker-no-labels'),
          message: '转写服务没有区分发言人，所有发言都记为「未标注发言人」；不按声音推测是谁。',
        ),
      if (distribution != null && !locatable)
        _Notice(
          key: ValueKey(
            !recording.originalPresent
                ? 'speaker-audio-missing'
                : audioChanged
                ? 'speaker-audio-changed'
                : 'speaker-not-locatable',
          ),
          message: !recording.originalPresent
              ? '原音频不在本机：统计仍可查看，片段时间暂时不能回听。'
              : audioChanged
              ? '录音已更换，旧时码无法定位到原音频；片段时间暂时不能回听。'
              : '这份转写的时码不足以逐句定位，片段时间暂时不能回听。',
        ),
    ];

    return Scaffold(
      key: const ValueKey('speaker-distribution'),
      backgroundColor: AppColors.bgElevated,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('发言人'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              Text(
                recording.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 12),
              for (final notice in notices) ...[
                notice,
                const SizedBox(height: 8),
              ],
              if (distribution != null) ...[
                const SizedBox(height: 8),
                _Section(
                  title: '占比',
                  child: _Shares(distribution: distribution, label: label),
                ),
                const SizedBox(height: 16),
                _Section(
                  title: '发言时间线',
                  child: _Timeline(distribution: distribution, label: label),
                ),
                const SizedBox(height: 16),
                _Section(
                  title: '片段',
                  subtitle: locatable ? '点时间打开原句并从那里回听。' : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final share in [
                        ...distribution.speakers,
                        ?distribution.unlabeled,
                      ])
                        _speakerSegments(
                          share,
                          label(share.speakerId),
                          segments,
                          locatable,
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _speakerSegments(
    SpeakerShare share,
    String name,
    List<TranscriptSegment> segments,
    bool locatable,
  ) {
    final id = share.speakerId;
    final all = share.segmentIndices;
    final expanded = _expanded.contains(id);
    final shown = expanded || all.length <= _collapsedChips
        ? all
        : all.take(_collapsedChips).toList();
    final groupKey = id ?? 'unlabeled';
    return Padding(
      key: ValueKey('speaker-segments-$groupKey'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SpeakerName(name: name, unlabeled: id == null),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 2,
            children: [
              for (final index in shown)
                _SegmentTime(
                  key: ValueKey('speaker-segment-$index'),
                  time: segments[index].start,
                  semantics: '$name ${_clock(segments[index].start)}',
                  onTap: locatable
                      ? () => widget.onOpenSource(
                          TranscriptJump(
                            segmentIndex: index,
                            start: segments[index].start,
                            snippet: segments[index].text,
                          ),
                        )
                      : null,
                ),
              if (shown.length < all.length)
                TextButton(
                  onPressed: () => setState(() => _expanded.add(id)),
                  child: Text('显示全部 ${all.length} 段'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Shares extends StatelessWidget {
  const _Shares({required this.distribution, required this.label});

  final SpeakerDistribution distribution;
  final String Function(String?) label;

  @override
  Widget build(BuildContext context) {
    final d = distribution;
    final total = d.total;
    final silence = d.silence;
    final secondary = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '有人声 ${_clock(d.voiced)}'
          ' · 录音 ${total == null ? '时长未知' : _clock(total)}',
          key: const ValueKey('speaker-denominator'),
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 12),
        for (final share in [...d.speakers, ?d.unlabeled])
          _ShareRow(
            key: ValueKey('speaker-share-${share.speakerId ?? 'unlabeled'}'),
            name: label(share.speakerId),
            unlabeled: share.speakerId == null,
            talk: share.talk,
            share: d.shareOfVoiced(share.talk),
          ),
        const SizedBox(height: 4),
        _MetricRow(
          key: const ValueKey('speaker-overlap'),
          name: '重叠',
          value: _clock(d.overlap),
          detail: '两人及以上同时说话，已分别计入各方',
        ),
        _MetricRow(
          key: const ValueKey('speaker-silence'),
          name: '无人声',
          value: silence == null ? '未知' : _clock(silence),
          detail: silence == null || total == null
              ? '原音频不在本机，无法量出录音总时长'
              : '占录音 ${_percent(silence.inMicroseconds / total.inMicroseconds)}',
        ),
        const SizedBox(height: 12),
        Text(
          '占比 = 本人发言时长 ÷ 有人声总时长。重叠时段同时计入每位发言人，'
          '所以合计可能超过 100%。未标注发言人单列，不按声音推测是谁。',
          key: const ValueKey('speaker-method'),
          style: secondary,
        ),
        if (d.untimedSegments > 0) ...[
          const SizedBox(height: 6),
          Text(
            '有 ${d.untimedSegments} 段缺少结束时间，没有计入时长。',
            key: const ValueKey('speaker-untimed'),
            style: secondary,
          ),
        ],
      ],
    );
  }
}

class _ShareRow extends StatelessWidget {
  const _ShareRow({
    super.key,
    required this.name,
    required this.unlabeled,
    required this.talk,
    required this.share,
  });

  final String name;
  final bool unlabeled;
  final Duration talk;
  final double? share;

  @override
  Widget build(BuildContext context) {
    final percent = share == null ? '—' : _percent(share!);
    return Semantics(
      label: '$name，发言 ${_clock(talk)}，占有人声 $percent',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: _SpeakerName(name: name, unlabeled: unlabeled),
                ),
                Text(
                  '${_clock(talk)}  $percent',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.xs),
              child: SizedBox(
                height: 6,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: AppColors.bgSubtle),
                    AnimatedFractionallySizedBox(
                      duration: AppMotion.duration(context, AppMotion.sheet),
                      curve: AppMotion.gentle,
                      alignment: Alignment.centerLeft,
                      widthFactor: (share ?? 0).clamp(0.0, 1.0),
                      child: ColoredBox(
                        color: unlabeled
                            ? AppColors.textMuted
                            : AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    super.key,
    required this.name,
    required this.value,
    required this.detail,
  });

  final String name;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            name,
            style: const TextStyle(color: AppColors.textPrimary),
          ),
        ),
        Expanded(
          child: Text(
            detail,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(width: 8),
        Text(value, style: const TextStyle(color: AppColors.textSecondary)),
      ],
    ),
  );
}

/// One row per speaker on a shared time axis, plus a row for overlap.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.distribution, required this.label});

  final SpeakerDistribution distribution;
  final String Function(String?) label;

  @override
  Widget build(BuildContext context) {
    final d = distribution;
    final groups = [...d.speakers, ?d.unlabeled];
    var axis = d.total ?? Duration.zero;
    for (final share in groups) {
      if (share.spans.isNotEmpty && share.spans.last.end > axis) {
        axis = share.spans.last.end;
      }
    }
    if (axis <= Duration.zero) {
      return Text(
        '这些分段都没有结束时间，画不出时间线。',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final share in groups)
          _TimelineRow(
            name: label(share.speakerId),
            spans: share.spans,
            axis: axis,
            color: share.speakerId == null
                ? AppColors.textMuted
                : AppColors.accent,
          ),
        if (d.overlapSpans.isNotEmpty)
          _TimelineRow(
            name: '重叠',
            spans: d.overlapSpans,
            axis: axis,
            color: AppColors.textSecondary,
          ),
        Padding(
          padding: const EdgeInsets.only(left: 80),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('00:00', style: _axisStyle(context)),
              Text(_clock(axis), style: _axisStyle(context)),
            ],
          ),
        ),
      ],
    );
  }

  TextStyle? _axisStyle(BuildContext context) => Theme.of(
    context,
  ).textTheme.labelSmall?.copyWith(color: AppColors.textMuted);
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.name,
    required this.spans,
    required this.axis,
    required this.color,
  });

  final String name;
  final List<SpeakerSpan> spans;
  final Duration axis;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$name：${spans.length} 段发言',
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.textPrimary),
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 14,
              child: CustomPaint(
                painter: _SpansPainter(spans: spans, axis: axis, color: color),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _SpansPainter extends CustomPainter {
  _SpansPainter({required this.spans, required this.axis, required this.color});

  final List<SpeakerSpan> spans;
  final Duration axis;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = const Radius.circular(AppRadii.xs);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, radius),
      Paint()..color = AppColors.bgSubtle,
    );
    final paint = Paint()..color = color;
    final scale = size.width / axis.inMicroseconds;
    for (final span in spans) {
      final left = span.start.inMicroseconds * scale;
      // Keep very short turns visible as a sliver.
      final width = ((span.end - span.start).inMicroseconds * scale).clamp(
        1.5,
        size.width,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, 0, width, size.height),
          radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SpansPainter old) =>
      old.spans != spans || old.axis != axis || old.color != color;
}

class _SpeakerName extends StatelessWidget {
  const _SpeakerName({required this.name, required this.unlabeled});

  final String name;
  final bool unlabeled;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(
        unlabeled ? Icons.help_outline_rounded : Icons.person_outline_rounded,
        size: 16,
        color: unlabeled ? AppColors.textMuted : AppColors.textSecondary,
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: unlabeled ? AppColors.textSecondary : AppColors.textPrimary,
          ),
        ),
      ),
    ],
  );
}

class _SegmentTime extends StatelessWidget {
  const _SegmentTime({
    super.key,
    required this.time,
    required this.semantics,
    required this.onTap,
  });

  final Duration time;
  final String semantics;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = _clock(time);
    final tap = onTap;
    if (tap == null) {
      // Without playable audio the time is information, not a control.
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Text(text, style: const TextStyle(color: AppColors.textMuted)),
      );
    }
    return Semantics(
      label: '$semantics，打开原句并回听',
      button: true,
      excludeSemantics: true,
      child: TextButton(
        onPressed: tap,
        style: TextButton.styleFrom(
          backgroundColor: AppColors.bgPanel,
          foregroundColor: AppColors.accent,
          minimumSize: const Size(56, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
        ),
        child: Text(text),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(AppRadii.card),
      border: Border.fromBorderSide(
        const BorderSide(color: AppColors.border, width: 0),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
        size: 16,
        color: error ? AppColors.coral : AppColors.textMuted,
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          message,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: error ? AppColors.coral : AppColors.textSecondary,
          ),
        ),
      ),
    ],
  );
}

String _clock(Duration value) {
  final total = value.inSeconds.clamp(0, 359999);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int part) => part.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

String _percent(double fraction) {
  if (fraction <= 0) return '0%';
  final value = fraction * 100;
  return value < 1 ? '<1%' : '${value.round()}%';
}
