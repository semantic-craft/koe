import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// A small dot that slowly breathes while something is live, such as a
/// recording in progress. With Reduce Motion on it stays still.
class BreathingDot extends StatefulWidget {
  const BreathingDot({super.key, this.size = 8, this.color});

  final double size;
  final Color? color;

  /// One full breath, in and out.
  static const period = Duration(milliseconds: 2400);

  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: BreathingDot.period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  void _sync() {
    if (AppMotion.reduced(context)) {
      _controller.value = 1;
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? KoeTokens.of(context).accent;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // 0 → 1 → 0 over one period, eased at both ends like a breath.
        final breath = (1 - math.cos(_controller.value * 2 * math.pi)) / 2;
        final scale = AppMotion.reduced(context) ? 1.0 : 0.82 + 0.18 * breath;
        final opacity = AppMotion.reduced(context) ? 1.0 : 0.55 + 0.45 * breath;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: color.withValues(alpha: opacity),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

/// Three dots that rise and fade in turn while AI is producing something
/// (asking Koe, writing a diary, organizing). Replaces a spinner. With Reduce
/// Motion on the dots are shown still.
class ThinkingDots extends StatefulWidget {
  const ThinkingDots({super.key, this.color, this.dotSize = 4});

  final Color? color;
  final double dotSize;

  static const period = Duration(milliseconds: 1900);

  @override
  State<ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: ThinkingDots.period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Opacity and lift for one dot at [t] (0..1 through its cycle):
  /// fade in while rising, rest, then fade out.
  static (double, double) _frame(double t) {
    const curve = Cubic(0.4, 0, 0.2, 1);
    if (t < 0.08) return (0, 0);
    if (t < 0.22) {
      final k = curve.transform((t - 0.08) / 0.14);
      return (k, -2.5 * k);
    }
    if (t < 0.36) {
      final k = curve.transform((t - 0.22) / 0.14);
      return (1, -2.5 * (1 - k));
    }
    if (t < 0.70) return (1, 0);
    if (t < 0.90) return (1 - curve.transform((t - 0.70) / 0.20), 0);
    return (0, 0);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? KoeTokens.of(context).accent;
    final reduced = AppMotion.reduced(context);
    return Semantics(
      label: '正在生成',
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) SizedBox(width: widget.dotSize * 0.9),
              Builder(
                builder: (context) {
                  // Each dot trails the previous one by 0.15 s.
                  final shift = i * 150 / ThinkingDots.period.inMilliseconds;
                  final (opacity, lift) = reduced
                      ? (0.6, 0.0)
                      : _frame((_controller.value - shift) % 1);
                  return Transform.translate(
                    offset: Offset(0, lift),
                    child: Container(
                      width: widget.dotSize,
                      height: widget.dotSize,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: opacity),
                        shape: BoxShape.circle,
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
