import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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

/// Corner radius scale adapted from nexu-io/open-design (`tokens.css` `--r-*`).
class AppRadii {
  AppRadii._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 10;
  static const double lg = 12;
  static const double xl = 16;
  static const double pill = 999;
}

/// Motion durations and easing curves adapted from nexu-io/open-design.
class AppMotion {
  AppMotion._();

  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration exit = Duration(milliseconds: 140);
  static const Duration slow = Duration(milliseconds: 280);

  /// Open-design deceleration curve (`cubic-bezier(0.23, 1, 0.32, 1)`).
  static const Curve easeOut = Cubic(0.23, 1.0, 0.32, 1.0);
}

/// Warm mainline color tokens. The light workspace palette below is the
/// single source of truth for [KoeTokens.light]; screens keep reading these
/// constants directly so the token layer adoption changes no pixel.
class AppColors {
  AppColors._();

  // Light workspace surfaces.
  static const bg = Color(0xFFF5F5F3);
  static const bgElevated = Color(0xFFFCFCFB);
  static const bgCard = Color(0xFFFFFFFF);
  static const bgCardHover = Color(0xFFECEBE6);
  static const bgPanel = Color(0xFFECEBE6);
  static const bgSubtle = Color(0xFFE7E5DE);
  static const bgMuted = Color(0xFFD9D6CD);

  // Crisp 1px borders.
  static const borderSoft = Color(0xFFECEBE6);
  static const border = Color(0xFFE4E3DD);
  static const borderStrong = Color(0xFFC9C6BC);
  static const borderSelected = Color(0xFFB5AFA5);
  static const borderFocus = Color(0xFFA4472B);

  // Typography ink ladder.
  static const textPrimary = Color(0xFF252521);
  static const textBody = Color(0xFF454540);
  static const textSecondary = Color(0xFF686860);
  static const textMuted = Color(0xFF75756D);
  static const textFaint = Color(0xFF9C9C93);

  // Primary ink & semantic status colors.
  static const inkAccent = Color(0xFFA4472B);
  static const onInkAccent = Colors.white;
  static const accent = Color(0xFFA4472B);
  static const accentSoft = Color(0xFFF6E9E2);
  static const accentBorder = Color(0xFFD8B7A8);

  static const amber = Color(0xFF966018);
  static const amberSoft = Color(0xFFF7ECDD);
  static const amberBorder = Color(0xFFDFC49E);

  static const coral = Color(0xFFB73333);
  static const coralSoft = Color(0xFFF8E7E4);
  static const coralBorder = Color(0xFFE4B7B1);

  static const violet = Color(0xFF686860);
  static const violetSoft = Color(0xFFECEBE6);

  static const gradientTop = Color(0xFFF5F5F3);
  static const gradientBottom = bg;

  /// Soft drop shadow for cards on light surfaces.
  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: const Color(0xFF0B0D12).withValues(alpha: 0.06),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
    BoxShadow(
      color: const Color(0xFF0B0D12).withValues(alpha: 0.03),
      blurRadius: 4,
      offset: const Offset(0, 1),
    ),
  ];

  /// Elevated floating surface shadow.
  static List<BoxShadow> get floatingShadow => [
    BoxShadow(
      color: const Color(0xFF0B0D12).withValues(alpha: 0.10),
      blurRadius: 24,
      offset: const Offset(0, 6),
    ),
    BoxShadow(
      color: const Color(0xFF0B0D12).withValues(alpha: 0.04),
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
    required this.textBody,
    required this.textSecondary,
    required this.textMuted,
    required this.textFaint,
    required this.inkAccent,
    required this.onInkAccent,
    required this.accent,
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
  final Color textBody;
  final Color textSecondary;
  final Color textMuted;
  final Color textFaint;
  final Color inkAccent;
  final Color onInkAccent;
  final Color accent;
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
    textBody: AppColors.textBody,
    textSecondary: AppColors.textSecondary,
    textMuted: AppColors.textMuted,
    textFaint: AppColors.textFaint,
    inkAccent: AppColors.inkAccent,
    onInkAccent: AppColors.onInkAccent,
    accent: AppColors.accent,
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
    textBody: const Color(0xFFE4DED7),
    textSecondary: const Color(0xFFC9C2B9),
    textMuted: const Color(0xFF9C948A),
    textFaint: const Color(0xFF6E675F),
    inkAccent: const Color(0xFFF5F1EC),
    onInkAccent: const Color(0xFF221E1B),
    accent: const Color(0xFFC97B54),
    accentSoft: const Color(0xFF3D2B22),
    accentBorder: const Color(0xFF5A3B2C),
    amber: const Color(0xFFD9A05B),
    amberSoft: const Color(0xFF33281C),
    amberBorder: const Color(0xFF57432B),
    coral: const Color(0xFFE08A85),
    coralSoft: const Color(0xFF36201E),
    coralBorder: const Color(0xFF5A302C),
    violet: const Color(0xFFB9A8D9),
    gradientTop: const Color(0xFF221E1B),
    gradientBottom: const Color(0xFF1B1815),
    cardShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.24),
        blurRadius: 10,
        offset: const Offset(0, 2),
      ),
    ],
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
    Color? textBody,
    Color? textSecondary,
    Color? textMuted,
    Color? textFaint,
    Color? inkAccent,
    Color? onInkAccent,
    Color? accent,
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
      textBody: textBody ?? this.textBody,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      textFaint: textFaint ?? this.textFaint,
      inkAccent: inkAccent ?? this.inkAccent,
      onInkAccent: onInkAccent ?? this.onInkAccent,
      accent: accent ?? this.accent,
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
      textBody: Color.lerp(textBody, other.textBody, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      inkAccent: Color.lerp(inkAccent, other.inkAccent, t)!,
      onInkAccent: Color.lerp(onInkAccent, other.onInkAccent, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
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
            // chips, progress tracks, switches) resolve to the same brick red.
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
            // chips, progress tracks, switches) resolve to the same brick red.
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

    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.sm),
    );
    return base.copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: buttonShape,
          elevation: 0,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: buttonShape,
          foregroundColor: t.textSecondary,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: buttonShape,
          foregroundColor: t.textPrimary,
          backgroundColor: t.bgPanel,
          side: BorderSide.none,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: buttonShape,
          foregroundColor: t.textSecondary,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          side: const WidgetStatePropertyAll(BorderSide.none),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? t.accentSoft
                : t.bgPanel,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? t.textMuted
                : t.textPrimary,
          ),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 14)),
        ),
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
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: BorderSide(color: t.border),
        ),
        elevation: 4,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.bgCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.bgElevated,
        surfaceTintColor: Colors.transparent,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: t.textPrimary,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: t.textPrimary),
      ),
      textTheme: TextTheme(
        displayLarge: TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w700,
          color: t.textPrimary,
          letterSpacing: -1,
          height: 1.1,
        ),
        headlineMedium: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: t.textPrimary,
          letterSpacing: -0.4,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: t.textPrimary,
        ),
        bodyLarge: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w400,
          color: t.textPrimary,
          height: 1.4,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: t.textSecondary,
          height: 1.4,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: t.textPrimary,
        ),
      ),
      dividerTheme: DividerThemeData(color: t.border, thickness: 1, space: 1),
      cardTheme: CardThemeData(
        color: t.bgCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: BorderSide(color: t.border),
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
}
