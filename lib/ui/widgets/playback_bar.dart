import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import 'widgets.dart';

/// Sticky playback controls: play/pause, ±5s seek, speed dropdown, scrubber.
class PlaybackBar extends StatelessWidget {
  const PlaybackBar({super.key});

  static String _fmt(Duration d) {
    final total = d.inSeconds;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final h = d.inHours.toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    return '$m:$s';
  }

  static String _speedLabel(double s) {
    if (s == s.roundToDouble()) return '${s.toInt()}×';
    return '$s×';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    if (!c.hasLoadedTrack) return const SizedBox.shrink();
    final tokens = KoeTokens.of(context);

    final canSeek = c.duration > Duration.zero || c.position > Duration.zero;

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      borderColor: tokens.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.graphic_eq_rounded,
                color: tokens.accent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.playingTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: tokens.textPrimary,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭播放器',
                visualDensity: VisualDensity.compact,
                onPressed: c.stopPlayback,
                icon: const Icon(Icons.close_rounded, size: 18),
                color: tokens.textMuted,
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Scrubber
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: tokens.inkAccent,
              inactiveTrackColor: tokens.border,
              thumbColor: tokens.inkAccent,
              overlayColor: tokens.inkAccent.withValues(alpha: 0.12),
            ),
            child: Slider(
              value: c.playbackProgress,
              onChanged: canSeek
                  ? (v) {
                      final totalMs = c.duration.inMilliseconds > 0
                          ? c.duration.inMilliseconds
                          : 1;
                      c.seekTo(Duration(milliseconds: (v * totalMs).round()));
                    }
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Text(
                  _fmt(c.position),
                  style: TextStyle(
                    fontSize: 11,
                    color: tokens.textMuted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const Spacer(),
                Text(
                  _fmt(c.duration),
                  style: TextStyle(
                    fontSize: 11,
                    color: tokens.textMuted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              // Speed dropdown
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: tokens.bgPanel,
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  border: Border.all(color: tokens.border),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<double>(
                    value:
                        RecorderController.playbackSpeeds.contains(
                          c.playbackSpeed,
                        )
                        ? c.playbackSpeed
                        : 1.0,
                    isDense: true,
                    dropdownColor: tokens.bgCard,
                    icon: Icon(
                      Icons.arrow_drop_down_rounded,
                      color: tokens.textMuted,
                      size: 20,
                    ),
                    style: TextStyle(
                      color: tokens.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    items: [
                      for (final s in RecorderController.playbackSpeeds)
                        DropdownMenuItem(value: s, child: Text(_speedLabel(s))),
                    ],
                    onChanged: (v) {
                      if (v != null) c.setPlaybackSpeed(v);
                    },
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _RoundControl(
                      tooltip: '后退 5 秒',
                      icon: Icons.replay_5_rounded,
                      onPressed: canSeek
                          ? () => c.seekBy(const Duration(seconds: -5))
                          : null,
                    ),
                    const SizedBox(width: 10),
                    _PlayPauseButton(
                      playing: c.isPlaying,
                      onPressed: c.togglePlayPause,
                    ),
                    const SizedBox(width: 10),
                    _RoundControl(
                      tooltip: '前进 5 秒',
                      icon: Icons.forward_5_rounded,
                      onPressed: canSeek
                          ? () => c.seekBy(const Duration(seconds: 5))
                          : null,
                    ),
                  ],
                ),
              ),
              // Balance width of speed control so transport stays centered.
              const SizedBox(width: 72),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Material(
      color: tokens.inkAccent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 50,
          height: 50,
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: tokens.onInkAccent,
            size: 28,
          ),
        ),
      ),
    );
  }
}

class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: tokens.bgPanel,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              icon,
              size: 23,
              color: onPressed == null ? tokens.textFaint : tokens.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
