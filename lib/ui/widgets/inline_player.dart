import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';

/// A replayable bookmark position drawn above the progress track.
class InlinePlayerMarker {
  const InlinePlayerMarker({
    required this.id,
    required this.at,
    required this.label,
  });

  final String id;
  final Duration at;
  final String label;
}

/// Compact play controls for a **local** exported file.
class InlinePlayer extends StatelessWidget {
  const InlinePlayer({
    super.key,
    required this.path,
    this.fileId,
    this.markers = const [],
    this.onMarkerTap,
    this.onAddBookmark,
  });

  final String path;
  final int? fileId;
  final List<InlinePlayerMarker> markers;
  final ValueChanged<InlinePlayerMarker>? onMarkerTap;
  final VoidCallback? onAddBookmark;

  static String _fmt(Duration d) {
    final total = d.inSeconds.abs();
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  static String _speedLabel(double s) {
    if (s == s.roundToDouble()) return '${s.toInt()}×';
    return '$s×';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    // Position ticks notify [positionListenable] only, not the controller.
    return ValueListenableBuilder<Duration>(
      valueListenable: c.positionListenable,
      builder: (context, position, _) => _player(context, c, position),
    );
  }

  Widget _player(
    BuildContext context,
    RecorderController c,
    Duration position,
  ) {
    final loaded = c.playingPath == path;
    final playing = loaded && c.isPlaying;
    final completed = loaded && c.playbackCompleted;
    final canSeek =
        loaded && (c.duration > Duration.zero || position > Duration.zero);
    final progress = loaded ? c.playbackProgress : 0.0;
    final total = loaded && c.duration > Duration.zero
        ? c.duration
        : c.localDurationForPath(path);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (markers.isNotEmpty && total != null && total > Duration.zero)
          _MarkerStrip(markers: markers, total: total, onTap: onMarkerTap),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: AppColors.accent,
            inactiveTrackColor: AppColors.border,
            thumbColor: AppColors.accent,
            overlayColor: AppColors.accent.withValues(alpha: 0.12),
          ),
          // Keep Slider's value-indicator portal in this subtree. Otherwise a
          // pushed route can serialize an orphan node and freeze macOS AXTree.
          // https://github.com/flutter/flutter/issues/190357
          child: Overlay.wrap(
            alwaysSizeToContent: true,
            clipBehavior: Clip.none,
            child: MergeSemantics(
              child: Semantics(
                label: '播放进度',
                child: Slider(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  value: progress,
                  semanticFormatterCallback: (v) => _fmt(
                    Duration(
                      milliseconds: (v * c.duration.inMilliseconds).round(),
                    ),
                  ),
                  onChanged: canSeek
                      ? (v) {
                          final totalMs = c.duration.inMilliseconds > 0
                              ? c.duration.inMilliseconds
                              : 1;
                          c.seekTo(
                            Duration(milliseconds: (v * totalMs).round()),
                          );
                        }
                      : null,
                ),
              ),
            ),
          ),
        ),
        Row(
          children: [
            Text(
              loaded ? _fmt(position) : '00:00',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (loaded) ...[
              const Spacer(),
              if (completed)
                const Text(
                  '已结束',
                  key: ValueKey('playback-completed'),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (completed) const Spacer(),
              Text(
                _fmt(c.duration),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            PopupMenuButton<double>(
              tooltip: '播放速度',
              initialValue: c.playbackSpeed,
              onSelected: c.setPlaybackSpeed,
              itemBuilder: (_) => [
                for (final speed in RecorderController.playbackSpeeds)
                  PopupMenuItem(value: speed, child: Text(_speedLabel(speed))),
              ],
              child: Container(
                constraints: const BoxConstraints(minWidth: 72, minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: AppColors.bgCardHover,
                  borderRadius: BorderRadius.circular(AppRadii.button),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _speedLabel(c.playbackSpeed),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const Icon(Icons.expand_more_rounded, size: 20),
                  ],
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _IconBtn(
                  icon: Icons.fast_rewind_rounded,
                  tooltip: '后退 15 秒',
                  onPressed: canSeek
                      ? () => c.seekBy(const Duration(seconds: -15))
                      : null,
                ),
                const SizedBox(width: 2),
                Semantics(
                  button: true,
                  label: playing
                      ? '暂停播放'
                      : completed
                      ? '重新播放'
                      : '播放录音',
                  onTap: () => c.playExported(path, fileId: fileId),
                  excludeSemantics: true,
                  child: Material(
                    color: AppColors.accent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => c.playExported(path, fileId: fileId),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: Tooltip(
                          message: playing
                              ? '暂停播放'
                              : completed
                              ? '重新播放'
                              : '播放录音',
                          child: Icon(
                            playing
                                ? Icons.pause_rounded
                                : completed
                                ? Icons.replay_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                _IconBtn(
                  icon: Icons.fast_forward_rounded,
                  tooltip: '前进 15 秒',
                  onPressed: canSeek
                      ? () => c.seekBy(const Duration(seconds: 15))
                      : null,
                ),
              ],
            ),
            if (onAddBookmark != null)
              _IconBtn(
                icon: Icons.bookmark_add_outlined,
                tooltip: '为当前片段加书签',
                size: 26,
                onPressed: onAddBookmark,
              ),
          ],
        ),
      ],
    );
  }
}

class _MarkerStrip extends StatelessWidget {
  const _MarkerStrip({required this.markers, required this.total, this.onTap});

  final List<InlinePlayerMarker> markers;
  final Duration total;
  final ValueChanged<InlinePlayerMarker>? onTap;

  // Matches the slider thumb radius so a marker sits over its track position.
  static const _inset = 6.0;
  static const _target = 44.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('player-marker-strip'),
      height: 32,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final track = (constraints.maxWidth - _inset * 2).clamp(
            0.0,
            double.infinity,
          );
          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (final (index, marker) in markers.indexed)
                Positioned(
                  left:
                      (_inset +
                              track *
                                  (marker.at.inMilliseconds /
                                          total.inMilliseconds)
                                      .clamp(0.0, 1.0) -
                              _target / 2)
                          .clamp(0.0, constraints.maxWidth - _target),
                  top: 0,
                  bottom: 0,
                  width: _target,
                  child: Semantics(
                    button: true,
                    label:
                        '回听书签 ${InlinePlayer._fmt(marker.at)} ${marker.label}',
                    excludeSemantics: true,
                    child: InkResponse(
                      key: ValueKey('player-marker-$index'),
                      onTap: onTap == null ? null : () => onTap!(marker),
                      radius: 18,
                      child: const Icon(
                        Icons.bookmark_rounded,
                        size: 18,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 30,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    // IconButton's own tooltip names the button for screen readers; an
    // outer Tooltip left the label on a separate, role-less node.
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: size),
      color: onPressed == null ? AppColors.textMuted : AppColors.textPrimary,
      constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
    );
  }
}
