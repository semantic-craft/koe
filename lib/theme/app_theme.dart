import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Spacing scale adapted from nexu-io/open-design (`tokens.css` `--s-*`).
class AppSpacing {
  AppSpacing._();

  static const double s2 = 2;
  static const double s4 = 4;
  static const double s6 = 6;
  static const double s8 = 8;
  static const double s10 = 10;
  static const double s12 = 12;
  static const double s14 = 14;
  static const double s16 = 16;
  static const double s18 = 18;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s28 = 28;
  static const double s32 = 32;
  static const double s48 = 48;
}

class AppFontSizes {
  AppFontSizes._();

  static const double xs = 12;
  static const double sm = 14;
  static const double md = 16;
  static const double lg = 22;
}

/// Corner radius scale (docs/design/ui-guidelines.md「圆角」).
class AppRadii {
  AppRadii._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 10;
  static const double lg = 12;
  static const double xl = 16;
  static const double pill = 999;

  /// Buttons and inputs.
  static const double button = sm;

  /// Sub-panels inside a page: tool strips, attachments, segmented tracks.
  static const double panel = md;

  /// Cards and list groups.
  static const double card = lg;

  /// Hero cards, dialogs and bottom sheets.
  static const double sheet = xl;

  static double concentric(double outer, double padding) =>
      (outer - padding) < xs ? xs : (outer - padding);
}

/// Motion durations and spring curves (docs/design/ui-guidelines.md「动效」).
///
/// Three durations and three springs; no default ease or linear curves.
/// Everything that moves goes through [duration] or [sheetStyle] so iOS
/// Reduce Motion turns it off: `KoeApp` folds iOS `reduceMotion` into
/// Flutter's `disableAnimations`, which is what [reduced] reads.
class AppMotion {
  AppMotion._();

  /// Focus rings, hover and press feedback.
  static const Duration micro = Duration(milliseconds: 70);

  /// Buttons, tabs, segmented controls, chips.
  static const Duration snap = Duration(milliseconds: 120);

  /// Panels, dialogs and sheets.
  static const Duration sheet = Duration(milliseconds: 300);

  /// Buttons, tabs and segmented switches: quick with a small overshoot.
  static const Curve snappy = SpringCurve(stiffness: 600, damping: 30);

  /// Panels and dialogs: settles with almost no overshoot.
  static const Curve gentle = SpringCurve(stiffness: 320, damping: 28);

  /// Closing drawers and snapping into place: overdamped, no overshoot.
  static const Curve heavySnap = SpringCurve(
    stiffness: 1200,
    damping: 80,
    mass: 0.1,
  );

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [base], or zero when the system asks for reduced motion.
  static Duration duration(BuildContext context, Duration base) =>
      reduced(context) ? Duration.zero : base;

  /// Bottom sheets open with [gentle] and close with [heavySnap].
  static AnimationStyle sheetStyle(BuildContext context) => reduced(context)
      ? AnimationStyle.noAnimation
      : AnimationStyle(
          curve: gentle,
          duration: sheet,
          reverseCurve: heavySnap,
          reverseDuration: snap,
        );
}

/// A damped spring from 0 to 1, stretched over the animation's duration.
///
/// The spring is simulated until it settles; the curve maps the animation's
/// 0..1 onto that span, so an underdamped spring overshoots past 1 and comes
/// back, and an overdamped one arrives without overshoot.
class SpringCurve extends Curve {
  const SpringCurve({
    required this.stiffness,
    required this.damping,
    this.mass = 1,
  });

  final double stiffness;
  final double damping;
  final double mass;

  static const _tolerance = Tolerance(distance: 0.001, velocity: 0.01);

  SpringSimulation _simulation() => SpringSimulation(
    SpringDescription(mass: mass, stiffness: stiffness, damping: damping),
    0,
    1,
    0,
    tolerance: _tolerance,
  );

  static final _settleTimes = <(double, double, double), double>{};

  double get _settleTime =>
      _settleTimes.putIfAbsent((stiffness, damping, mass), () {
        final simulation = _simulation();
        var time = 0.0;
        while (!simulation.isDone(time) && time < 5) {
          time += 0.004;
        }
        return time;
      });

  @override
  double transformInternal(double t) => _simulation().x(t * _settleTime);
}

/// Warm mainline color tokens. The light workspace palette below is the
/// single source of truth for [KoeTokens.light]; screens keep reading these
/// constants directly so the token layer adoption changes no pixel.
class AppColors {
  AppColors._();

  // Surface 0–3, from the canvas up (docs/design/ui-guidelines.md「表面」).
  /// Surface 0: warm paper canvas behind everything.
  static const surface0 = Color(0xFFF5F4F0);

  /// Surface 1: bars, sheets and the area a page scrolls on.
  static const surface1 = Color(0xFFFAF9F6);

  /// Surface 2: cards and list groups.
  static const surface2 = Color(0xFFFFFFFF);

  /// Surface 3: inputs, popovers and dialogs above a card.
  static const surface3 = Color(0xFFFFFFFF);

  // Older names for the same surfaces.
  static const bg = surface0;
  static const bgElevated = surface1;
  static const bgCard = surface2;
  static const bgCardHover = Color(0xFFECEAE4);
  static const bgPanel = Color(0xFFECEAE4);
  static const bgSubtle = Color(0xFFE5E2DA);
  static const bgMuted = Color(0xFFD8D5CC);

  // Crisp 1px warm borders.
  static const borderSoft = Color(0xFFECEAE4);
  static const border = Color(0xFFE2DFD7);
  static const borderStrong = Color(0xFFC7C4BA);
  static const borderSelected = Color(0xFFB3AFA4);
  static const borderFocus = Color(0xFF2E5E4E);

  // Three warm text levels. Muted meets WCAG AA (>= 4.6:1) on surfaces 0–3.
  static const textPrimary = Color(0xFF242320);
  static const textSecondary = Color(0xFF5C5A54);
  static const textMuted = Color(0xFF6E6C65);

  static const inkAccent = Color(0xFF2E5E4E);
  static const onInkAccent = Colors.white;
  static const accent = Color(0xFF2E5E4E);
  static const accentPressed = Color(0xFF23493C);
  static const accentSoft = Color(0xFFE8F0EC);
  static const accentBorder = Color(0xFFB8CEC4);

  static const amber = Color(0xFF8C6223);
  static const amberSoft = Color(0xFFF5ECE0);
  static const amberBorder = Color(0xFFDCC5A3);

  static const coral = Color(0xFF9E3E32);
  static const coralSoft = Color(0xFFF6E8E5);
  static const coralBorder = Color(0xFFDDB8B2);

  static const violet = Color(0xFF5C5A54);
  static const violetSoft = Color(0xFFECEAE4);

  static const gradientTop = Color(0xFFF5F4F0);
  static const gradientBottom = bg;

  static List<BoxShadow> get cardShadow => const [];

  static List<BoxShadow> get floatingShadow => [
    BoxShadow(
      color: const Color(0xFF141311).withValues(alpha: 0.10),
      blurRadius: 24,
      offset: const Offset(0, 6),
    ),
    BoxShadow(
      color: const Color(0xFF141311).withValues(alpha: 0.04),
      blurRadius: 6,
      offset: const Offset(0, 2),
    ),
  ];
}

/// Adaptive theme token extension supporting both light and dark modes.
@immutable
class KoeTokens extends ThemeExtension<KoeTokens> {
  const KoeTokens({
    required this.bg,
    required this.bgElevated,
    required this.bgCard,
    required this.bgPanel,
    required this.bgSubtle,
    required this.bgMuted,
    required this.borderSoft,
    required this.border,
    required this.borderStrong,
    required this.borderSelected,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.inkAccent,
    required this.onInkAccent,
    required this.accent,
    required this.accentPressed,
    required this.accentSoft,
    required this.accentBorder,
    required this.amber,
    required this.amberSoft,
    required this.amberBorder,
    required this.coral,
    required this.coralSoft,
    required this.coralBorder,
    required this.violet,
    required this.gradientTop,
    required this.gradientBottom,
    required this.cardShadow,
    required this.floatingShadow,
  });

  final Color bg;
  final Color bgElevated;
  final Color bgCard;
  final Color bgPanel;
  final Color bgSubtle;
  final Color bgMuted;
  final Color borderSoft;
  final Color border;
  final Color borderStrong;
  final Color borderSelected;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color inkAccent;
  final Color onInkAccent;
  final Color accent;
  final Color accentPressed;
  final Color accentSoft;
  final Color accentBorder;
  final Color amber;
  final Color amberSoft;
  final Color amberBorder;
  final Color coral;
  final Color coralSoft;
  final Color coralBorder;
  final Color violet;
  final Color gradientTop;
  final Color gradientBottom;
  final List<BoxShadow> cardShadow;
  final List<BoxShadow> floatingShadow;

  /// The warm mainline palette; every field comes from [AppColors].
  static final KoeTokens light = KoeTokens(
    bg: AppColors.bg,
    bgElevated: AppColors.bgElevated,
    bgCard: AppColors.bgCard,
    bgPanel: AppColors.bgPanel,
    bgSubtle: AppColors.bgSubtle,
    bgMuted: AppColors.bgMuted,
    borderSoft: AppColors.borderSoft,
    border: AppColors.border,
    borderStrong: AppColors.borderStrong,
    borderSelected: AppColors.borderSelected,
    textPrimary: AppColors.textPrimary,
    textSecondary: AppColors.textSecondary,
    textMuted: AppColors.textMuted,
    inkAccent: AppColors.inkAccent,
    onInkAccent: AppColors.onInkAccent,
    accent: AppColors.accent,
    accentPressed: AppColors.accentPressed,
    accentSoft: AppColors.accentSoft,
    accentBorder: AppColors.accentBorder,
    amber: AppColors.amber,
    amberSoft: AppColors.amberSoft,
    amberBorder: AppColors.amberBorder,
    coral: AppColors.coral,
    coralSoft: AppColors.coralSoft,
    coralBorder: AppColors.coralBorder,
    violet: AppColors.violet,
    gradientTop: AppColors.gradientTop,
    gradientBottom: AppColors.gradientBottom,
    cardShadow: AppColors.cardShadow,
    floatingShadow: AppColors.floatingShadow,
  );

  /// Provisional warm-dark counterpart. Not exercised by the app (main.dart
  /// locks [ThemeMode.light]); values follow the light palette's structure
  /// and may be tuned when a dark mode is actually designed.
  static final KoeTokens dark = KoeTokens(
    bg: const Color(0xFF221E1B),
    bgElevated: const Color(0xFF2A2521),
    bgCard: const Color(0xFF2A2521),
    bgPanel: const Color(0xFF332D28),
    bgSubtle: const Color(0xFF3A332D),
    bgMuted: const Color(0xFF4A423A),
    borderSoft: const Color(0xFF332D28),
    border: const Color(0xFF453D36),
    borderStrong: const Color(0xFF5A5048),
    borderSelected: const Color(0xFF6E635A),
    textPrimary: const Color(0xFFF5F1EC),
    textSecondary: const Color(0xFFC9C2B9),
    textMuted: const Color(0xFF9C948A),
    inkAccent: const Color(0xFFF5F1EC),
    onInkAccent: const Color(0xFF221E1B),
    accent: const Color(0xFF6FA894),
    accentPressed: const Color(0xFF5B917E),
    accentSoft: const Color(0xFF21362F),
    accentBorder: const Color(0xFF335247),
    amber: const Color(0xFFD9A05B),
    amberSoft: const Color(0xFF33281C),
    amberBorder: const Color(0xFF57432B),
    coral: const Color(0xFFE08A85),
    coralSoft: const Color(0xFF36201E),
    coralBorder: const Color(0xFF5A302C),
    violet: const Color(0xFFC9C2B9),
    gradientTop: const Color(0xFF221E1B),
    gradientBottom: const Color(0xFF1B1815),
    cardShadow: const [],
    floatingShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.38),
        blurRadius: 24,
        offset: const Offset(0, 6),
      ),
    ],
  );

  static KoeTokens of(BuildContext context) {
    return Theme.of(context).extension<KoeTokens>() ?? light;
  }

  @override
  KoeTokens copyWith({
    Color? bg,
    Color? bgElevated,
    Color? bgCard,
    Color? bgPanel,
    Color? bgSubtle,
    Color? bgMuted,
    Color? borderSoft,
    Color? border,
    Color? borderStrong,
    Color? borderSelected,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? inkAccent,
    Color? onInkAccent,
    Color? accent,
    Color? accentPressed,
    Color? accentSoft,
    Color? accentBorder,
    Color? amber,
    Color? amberSoft,
    Color? amberBorder,
    Color? coral,
    Color? coralSoft,
    Color? coralBorder,
    Color? violet,
    Color? gradientTop,
    Color? gradientBottom,
    List<BoxShadow>? cardShadow,
    List<BoxShadow>? floatingShadow,
  }) {
    return KoeTokens(
      bg: bg ?? this.bg,
      bgElevated: bgElevated ?? this.bgElevated,
      bgCard: bgCard ?? this.bgCard,
      bgPanel: bgPanel ?? this.bgPanel,
      bgSubtle: bgSubtle ?? this.bgSubtle,
      bgMuted: bgMuted ?? this.bgMuted,
      borderSoft: borderSoft ?? this.borderSoft,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      borderSelected: borderSelected ?? this.borderSelected,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      inkAccent: inkAccent ?? this.inkAccent,
      onInkAccent: onInkAccent ?? this.onInkAccent,
      accent: accent ?? this.accent,
      accentPressed: accentPressed ?? this.accentPressed,
      accentSoft: accentSoft ?? this.accentSoft,
      accentBorder: accentBorder ?? this.accentBorder,
      amber: amber ?? this.amber,
      amberSoft: amberSoft ?? this.amberSoft,
      amberBorder: amberBorder ?? this.amberBorder,
      coral: coral ?? this.coral,
      coralSoft: coralSoft ?? this.coralSoft,
      coralBorder: coralBorder ?? this.coralBorder,
      violet: violet ?? this.violet,
      gradientTop: gradientTop ?? this.gradientTop,
      gradientBottom: gradientBottom ?? this.gradientBottom,
      cardShadow: cardShadow ?? this.cardShadow,
      floatingShadow: floatingShadow ?? this.floatingShadow,
    );
  }

  @override
  KoeTokens lerp(ThemeExtension<KoeTokens>? other, double t) {
    if (other is! KoeTokens) return this;
    return KoeTokens(
      bg: Color.lerp(bg, other.bg, t)!,
      bgElevated: Color.lerp(bgElevated, other.bgElevated, t)!,
      bgCard: Color.lerp(bgCard, other.bgCard, t)!,
      bgPanel: Color.lerp(bgPanel, other.bgPanel, t)!,
      bgSubtle: Color.lerp(bgSubtle, other.bgSubtle, t)!,
      bgMuted: Color.lerp(bgMuted, other.bgMuted, t)!,
      borderSoft: Color.lerp(borderSoft, other.borderSoft, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      borderSelected: Color.lerp(borderSelected, other.borderSelected, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      inkAccent: Color.lerp(inkAccent, other.inkAccent, t)!,
      onInkAccent: Color.lerp(onInkAccent, other.onInkAccent, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentPressed: Color.lerp(accentPressed, other.accentPressed, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentBorder: Color.lerp(accentBorder, other.accentBorder, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      amberSoft: Color.lerp(amberSoft, other.amberSoft, t)!,
      amberBorder: Color.lerp(amberBorder, other.amberBorder, t)!,
      coral: Color.lerp(coral, other.coral, t)!,
      coralSoft: Color.lerp(coralSoft, other.coralSoft, t)!,
      coralBorder: Color.lerp(coralBorder, other.coralBorder, t)!,
      violet: Color.lerp(violet, other.violet, t)!,
      gradientTop: Color.lerp(gradientTop, other.gradientTop, t)!,
      gradientBottom: Color.lerp(gradientBottom, other.gradientBottom, t)!,
      cardShadow: t < 0.5 ? cardShadow : other.cardShadow,
      floatingShadow: t < 0.5 ? floatingShadow : other.floatingShadow,
    );
  }
}

/// Builds the Material themes from [KoeTokens]. The light output matches the
/// previous hardcoded warm theme pixel for pixel; component values below are
/// the warm mainline's, expressed through the token layer.
class AppTheme {
  static ThemeData get light => _build(Brightness.light, KoeTokens.light);

  static ThemeData get dark => _build(Brightness.dark, KoeTokens.dark);

  static ThemeData _build(Brightness brightness, KoeTokens t) {
    final isDark = brightness == Brightness.dark;
    // Keep the full legacy constructors: `ColorScheme.light()` with no
    // arguments leaves many fields null in this Flutter version, which would
    // shift component defaults. Only the warm-token-sourced values change.
    final colorScheme = isDark
        ? ColorScheme.dark(
            surface: t.bgElevated,
            primary: t.accent,
            // Koe has one accent: Material's secondary roles (selected
            // chips, progress tracks, switches) resolve to the same bamboo green.
            secondary: t.accent,
            secondaryContainer: t.accentSoft,
            onSecondaryContainer: t.accent,
            error: t.coral,
            onPrimary: Colors.white,
            onSurface: t.textPrimary,
            outline: t.border,
          )
        : ColorScheme.light(
            surface: t.bgElevated,
            primary: t.accent,
            // Koe has one accent: Material's secondary roles (selected
            // chips, progress tracks, switches) resolve to the same bamboo green.
            secondary: t.accent,
            secondaryContainer: t.accentSoft,
            onSecondaryContainer: t.accent,
            error: t.coral,
            onPrimary: Colors.white,
            onSurface: t.textPrimary,
            outline: t.border,
          );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: t.bg,
      colorScheme: colorScheme,
      // Adaptive switches on iOS/macOS otherwise fall back to system green
      // when a call site sets no colors; let them take the accent instead.
      cupertinoOverrideTheme: const CupertinoThemeData(applyThemeToAll: true),
      extensions: [t],
    );

    // iPhone keeps Apple's 44pt touch target; the Mac uses the denser
    // pointer size (docs/design/ui-guidelines.md「按钮尺寸」).
    final compact = defaultTargetPlatform == TargetPlatform.macOS;
    final control = compact ? 32.0 : 44.0;
    final controlSize = Size(control, control);
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.button),
    );
    // Keyboard focus draws an accent ring outside the control (mainly macOS);
    // nothing else gets an outline, per the one-border rule. `none` rather
    // than null: null lets OutlinedButton fall back to Material's outline.
    final focusRing = WidgetStateProperty.resolveWith<BorderSide?>(
      (states) => states.contains(WidgetState.focused)
          ? BorderSide(
              color: t.accent,
              width: 2,
              strokeAlign: BorderSide.strokeAlignOutside,
            )
          : BorderSide.none,
    );
    final motion = ButtonStyle(
      side: focusRing,
      animationDuration: AppMotion.snap,
      splashFactory: InkRipple.splashFactory,
    );
    return base.copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style:
            FilledButton.styleFrom(
                  minimumSize: controlSize,
                  shape: buttonShape,
                  elevation: 0,
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                )
                .merge(motion)
                .copyWith(
                  backgroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.disabled)
                        ? t.bgSubtle
                        : states.contains(WidgetState.pressed)
                        ? t.accentPressed
                        : t.accent,
                  ),
                  overlayColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: controlSize,
          shape: buttonShape,
          foregroundColor: t.textSecondary,
        ).merge(motion),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: controlSize,
          shape: buttonShape,
          foregroundColor: t.textPrimary,
          backgroundColor: t.bgPanel,
        ).merge(motion),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: controlSize,
          shape: buttonShape,
          foregroundColor: t.textSecondary,
        ).merge(motion),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(controlSize),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          side: const WidgetStatePropertyAll(BorderSide.none),
          animationDuration: AppMotion.snap,
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? t.accentSoft
                : t.bgPanel,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? t.textMuted
                : states.contains(WidgetState.selected)
                ? t.accent
                : t.textPrimary,
          ),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 14)),
        ),
      ),
      chipTheme: ChipThemeData(
        // Chips sit inside cards and lists; fill alone shows state.
        side: BorderSide.none,
        shape: const StadiumBorder(),
        backgroundColor: t.bgPanel,
        selectedColor: t.accentSoft,
        secondarySelectedColor: t.accentSoft,
        labelStyle: TextStyle(color: t.textSecondary, fontSize: 14),
        secondaryLabelStyle: TextStyle(color: t.accent, fontSize: 14),
        checkmarkColor: t.accent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? t.accent : t.bgMuted,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xs),
        ),
        // Unchecked outline keeps 3:1 against the card (WCAG 1.4.11).
        side: BorderSide(color: t.textMuted, width: 1.5),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.accent,
        linearTrackColor: t.accentSoft,
        circularTrackColor: Colors.transparent,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: t.accent,
        inactiveTrackColor: t.border,
        thumbColor: t.accent,
        overlayColor: t.accent.withValues(alpha: 0.12),
      ),
      listTileTheme: ListTileThemeData(
        minVerticalPadding: AppSpacing.s10,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        iconColor: t.textSecondary,
        textColor: t.textPrimary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.bgCard,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s14,
          vertical: AppSpacing.s14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          borderSide: BorderSide(color: t.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          borderSide: BorderSide(color: t.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          borderSide: BorderSide(color: t.accent, width: 2),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: t.bgCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
          side: BorderSide(color: t.border, width: 0),
        ),
        elevation: 4,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.bgCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sheet),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.bgElevated,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.sheet),
          ),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: t.textPrimary,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: t.textPrimary),
      ),
      // Start from the base theme so slots Koe doesn't restyle (headlineSmall
      // for dialog titles, titleLarge, bodySmall…) keep a themed color; a bare
      // TextTheme left them colorless and dialog titles drew blank (#306).
      textTheme: _tabular(
        base.textTheme.copyWith(
          displayLarge: TextStyle(
            fontSize: AppFontSizes.lg,
            fontWeight: FontWeight.w700,
            color: t.textPrimary,
            letterSpacing: -0.3,
            height: 1.2,
          ),
          displayMedium: TextStyle(
            fontSize: AppFontSizes.lg,
            fontWeight: FontWeight.w700,
            color: t.textPrimary,
            letterSpacing: -0.3,
          ),
          displaySmall: TextStyle(
            fontSize: AppFontSizes.lg,
            fontWeight: FontWeight.w600,
            color: t.textPrimary,
            letterSpacing: -0.3,
          ),
          headlineLarge: TextStyle(
            fontSize: AppFontSizes.lg,
            fontWeight: FontWeight.w600,
            color: t.textPrimary,
            letterSpacing: -0.3,
          ),
          headlineMedium: TextStyle(
            fontSize: AppFontSizes.lg,
            fontWeight: FontWeight.w600,
            color: t.textPrimary,
            letterSpacing: -0.3,
          ),
          headlineSmall: TextStyle(
            fontSize: AppFontSizes.md,
            fontWeight: FontWeight.w600,
            color: t.textPrimary,
          ),
          titleLarge: TextStyle(
            fontSize: AppFontSizes.lg,
            fontWeight: FontWeight.w600,
            color: t.textPrimary,
          ),
          titleMedium: TextStyle(
            fontSize: AppFontSizes.md,
            fontWeight: FontWeight.w600,
            color: t.textPrimary,
          ),
          titleSmall: TextStyle(
            fontSize: AppFontSizes.sm,
            fontWeight: FontWeight.w600,
            color: t.textPrimary,
          ),
          bodyLarge: TextStyle(
            fontSize: AppFontSizes.sm,
            fontWeight: FontWeight.w400,
            color: t.textPrimary,
            height: 1.4,
          ),
          bodyMedium: TextStyle(
            fontSize: AppFontSizes.sm,
            fontWeight: FontWeight.w400,
            color: t.textSecondary,
            height: 1.4,
          ),
          bodySmall: TextStyle(
            fontSize: AppFontSizes.xs,
            fontWeight: FontWeight.w400,
            color: t.textSecondary,
            height: 1.4,
          ),
          labelLarge: TextStyle(
            fontSize: AppFontSizes.sm,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
            color: t.textPrimary,
          ),
          labelMedium: TextStyle(
            fontSize: AppFontSizes.xs,
            fontWeight: FontWeight.w500,
            color: t.textSecondary,
          ),
          labelSmall: TextStyle(
            fontSize: AppFontSizes.xs,
            fontWeight: FontWeight.w500,
            color: t.textMuted,
          ),
        ),
      ),
      // thickness 0 draws a one-physical-pixel hairline on every screen.
      dividerTheme: DividerThemeData(color: t.border, thickness: 0, space: 1),
      cardTheme: CardThemeData(
        color: t.bgCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
          side: BorderSide(color: t.border, width: 0),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.bgElevated,
        contentTextStyle: TextStyle(color: t.textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 4,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(backgroundColor: WidgetStatePropertyAll(t.bgCard)),
      ),
    );
  }

  /// Every text style uses tabular figures, so timers, durations and counts
  /// keep their width as digits change; Chinese text is unaffected.
  static TextTheme _tabular(TextTheme theme) {
    const features = [FontFeature.tabularFigures()];
    TextStyle? apply(TextStyle? style) =>
        style?.copyWith(fontFeatures: features);
    return theme.copyWith(
      displayLarge: apply(theme.displayLarge),
      displayMedium: apply(theme.displayMedium),
      displaySmall: apply(theme.displaySmall),
      headlineLarge: apply(theme.headlineLarge),
      headlineMedium: apply(theme.headlineMedium),
      headlineSmall: apply(theme.headlineSmall),
      titleLarge: apply(theme.titleLarge),
      titleMedium: apply(theme.titleMedium),
      titleSmall: apply(theme.titleSmall),
      bodyLarge: apply(theme.bodyLarge),
      bodyMedium: apply(theme.bodyMedium),
      bodySmall: apply(theme.bodySmall),
      labelLarge: apply(theme.labelLarge),
      labelMedium: apply(theme.labelMedium),
      labelSmall: apply(theme.labelSmall),
    );
  }
}
