import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class GradientScaffold extends StatelessWidget {
  const GradientScaffold({
    super.key,
    required this.child,
    this.appBar,
    this.bottom,
  });

  final Widget child;
  final PreferredSizeWidget? appBar;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tokens.gradientTop, tokens.gradientBottom],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: appBar,
        body: child,
        bottomNavigationBar: bottom,
      ),
    );
  }
}

class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.borderColor,
    this.backgroundColor,
    this.radius = AppRadii.lg,
    this.glow = false,
    this.shadow = true,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? borderColor;
  final Color? backgroundColor;
  final double radius;
  final bool glow;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final borderRadius = BorderRadius.circular(radius);
    final card = AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.easeOut,
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor ?? tokens.bgCard,
        borderRadius: borderRadius,
        border: Border.all(color: borderColor ?? tokens.border),
        boxShadow: !shadow
            ? const []
            : glow
            ? [
                BoxShadow(
                  color: tokens.accent.withValues(alpha: 0.12),
                  blurRadius: 18,
                  offset: const Offset(0, 4),
                ),
                ...tokens.cardShadow,
              ]
            : tokens.cardShadow,
      ),
      child: Material(color: Colors.transparent, child: child),
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        splashColor: tokens.accent.withValues(alpha: 0.06),
        highlightColor: tokens.accent.withValues(alpha: 0.03),
        child: card,
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
          ] else ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BatteryRing extends StatelessWidget {
  const BatteryRing({
    super.key,
    required this.percent,
    this.size = 88,
    this.charging = false,
  });

  final int percent;
  final double size;
  final bool charging;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final p = percent.clamp(0, 100) / 100.0;
    final color = percent > 50
        ? tokens.mint
        : percent > 20
        ? tokens.amber
        : tokens.coral;

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: p,
          color: color,
          trackColor: tokens.borderSoft,
        ),
        child: Padding(
          padding: EdgeInsets.all(size * 0.14),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (charging)
                  Icon(Icons.bolt_rounded, color: tokens.amber, size: 14),
                Text(
                  '$percent%',
                  style: TextStyle(
                    fontSize: size * 0.21,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: tokens.textPrimary,
                    letterSpacing: -0.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  charging ? '充电中' : '电量',
                  style: TextStyle(
                    fontSize: size * 0.1,
                    height: 1,
                    color: tokens.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
  });

  final double progress;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 6;
    final bg = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.5
      ..strokeCap = StrokeCap.round;
    final fg = Paint()
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        colors: [color.withValues(alpha: 0.45), color],
      ).createShader(Rect.fromCircle(center: c, radius: r))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.5
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(c, r, bg);
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.trackColor != trackColor;
}

class AccentButton extends StatelessWidget {
  const AccentButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.filled = true,
    this.color,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool filled;
  final Color? color;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final c = color ?? tokens.accent;
    final enabled = onPressed != null;
    final fgColor = filled ? Colors.white : c;
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 17, color: fgColor),
          const SizedBox(width: 7),
        ],
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fgColor,
              fontWeight: FontWeight.w600,
              fontSize: 13.5,
              letterSpacing: -0.1,
            ),
          ),
        ),
      ],
    );

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.md),
              color: filled ? c : c.withValues(alpha: 0.06),
              border: filled
                  ? Border.all(color: c)
                  : Border.all(color: c.withValues(alpha: 0.38)),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: expand ? 14 : 16,
                  vertical: 11,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: tokens.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: tokens.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final label = Text(
      text.toUpperCase(),
      style: TextStyle(
        color: tokens.textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: trailing == null
          ? label
          : Row(
              children: [
                Expanded(child: label),
                trailing!,
              ],
            ),
    );
  }
}

/// Rounded-square icon badge adapted from open-design `SettingsWorkspaceSection` (`.entryIcon`).
class IconBadge extends StatelessWidget {
  const IconBadge({
    super.key,
    required this.icon,
    this.color,
    this.backgroundColor,
    this.borderColor,
    this.size = 34,
    this.iconSize = 17,
    this.radius = 9,
  });

  final IconData icon;
  final Color? color;
  final Color? backgroundColor;
  final Color? borderColor;
  final double size;
  final double iconSize;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final fg = color ?? tokens.textPrimary;
    final bg = backgroundColor ?? tokens.bgPanel;
    final border = borderColor ?? tokens.borderSoft;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: iconSize, color: fg),
    );
  }
}

/// Semantic notice banner adapted from open-design `.lockedBanner` / `.warning`.
class BannerNotice extends StatelessWidget {
  const BannerNotice({
    super.key,
    required this.message,
    this.icon = Icons.info_outline_rounded,
    this.color,
    this.backgroundColor,
    this.borderColor,
    this.trailing,
  });

  final String message;
  final IconData icon;
  final Color? color;
  final Color? backgroundColor;
  final Color? borderColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final fg = color ?? tokens.accent;
    final bg = backgroundColor ?? fg.withValues(alpha: 0.08);
    final border = borderColor ?? fg.withValues(alpha: 0.24);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: fg,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}
