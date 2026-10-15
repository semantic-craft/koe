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

/// Neutral-first color tokens for Koe, adapted from nexu-io/open-design
/// (`apps/web/src/styles/tokens.css` & `material.css`, Apache-2.0).
class AppColors {
  AppColors._();

  // Light workspace surfaces (`--bg`, `--bg-panel`, `--bg-subtle`, `--bg-muted`)
  static const bg = Color(0xFFFAFAFA);
  static const bgElevated = Color(0xFFFFFFFF);
  static const bgCard = Color(0xFFFFFFFF);
  static const bgPanel = Color(0xFFF5F5F4);
  static const bgCardHover = Color(0xFFEDEDED);
  static const bgSubtle = Color(0xFFEDEDED);
  static const bgMuted = Color(0xFFDBDBDB);

  // Crisp 1px borders (`--border-soft`, `--border`, `--border-strong`, `--border-selected`)
  static const borderSoft = Color(0xFFEDEDED);
  static const border = Color(0xFFDBDBDB);
  static const borderStrong = Color(0xFFBDBDBD);
  static const borderSelected = Color(0xFFA3A3A3);
  static const borderFocus = Color(0xFF1A74FF);

  // Typography ink ladder (`--text-strong`, `--text`, `--text-muted`, `--text-soft`, `--text-faint`)
  static const textPrimary = Color(0xFF202020);
  static const textBody = Color(0xFF494949);
  static const textSecondary = Color(0xFF5C5C5C);
  static const textMuted = Color(0xFF848484);
  static const textFaint = Color(0xFFBDBDBD);

  // Primary ink & semantic status colors (`--accent`, `--blue`, `--green`, `--amber`, `--red`)
  static const inkAccent = Color(0xFF202020);
  static const accent = Color(0xFF1A74FF);
  static const accentSoft = Color(0xFFEAF3FF);
  static const accentBorder = Color(0xFFB8D4FF);

  static const mint = Color(0xFF00AA54);
  static const mintSoft = Color(0xFFF2FBF6);
  static const mintBorder = Color(0xFF9CE6BE);

  static const amber = Color(0xFFE86418);
  static const amberSoft = Color(0xFFFFF5EE);
  static const amberBorder = Color(0xFFFFCBA8);

  static const coral = Color(0xFFF04142);
  static const coralSoft = Color(0xFFFFF2F2);
  static const coralBorder = Color(0xFFFFC2C2);

  static const violet = Color(0xFF6E44FF);
  static const violetSoft = Color(0xFFF3EFFF);

  static const gradientTop = Color(0xFFFAFAFA);
  static const gradientBottom = Color(0xFFF3F3F2);

  /// Layered neutral shadow (`--shadow-sm` from open-design).
  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: const Color(0xFF1C1B1A).withValues(alpha: 0.045),
      blurRadius: 10,
      offset: const Offset(0, 2),
    ),
    BoxShadow(
      color: const Color(0xFF1C1B1A).withValues(alpha: 0.03),
      blurRadius: 2,
      offset: const Offset(0, 1),
    ),
  ];

  /// Elevated floating surface shadow (`--shadow-md` from open-design).
  static List<BoxShadow> get floatingShadow => [
    BoxShadow(
      color: const Color(0xFF1C1B1A).withValues(alpha: 0.08),
      blurRadius: 24,
      offset: const Offset(0, 6),
    ),
    BoxShadow(
      color: const Color(0xFF1C1B1A).withValues(alpha: 0.04),
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
    required this.mint,
    required this.mintSoft,
    required this.mintBorder,
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
  final Color mint;
  final Color mintSoft;
  final Color mintBorder;
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
    onInkAccent: Colors.white,
    accent: AppColors.accent,
    accentSoft: AppColors.accentSoft,
    accentBorder: AppColors.accentBorder,
    mint: AppColors.mint,
    mintSoft: AppColors.mintSoft,
    mintBorder: AppColors.mintBorder,
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

  static final KoeTokens dark = KoeTokens(
    bg: const Color(0xFF202020),
    bgElevated: const Color(0xFF2A2A2A),
    bgCard: const Color(0xFF2A2A2A),
    bgPanel: const Color(0xFF353535),
    bgSubtle: const Color(0xFF3D3D3D),
    bgMuted: const Color(0xFF5C5C5C),
    borderSoft: const Color(0xFF353535),
    border: const Color(0xFF494949),
    borderStrong: const Color(0xFF5C5C5C),
    borderSelected: const Color(0xFF848484),
    textPrimary: const Color(0xFFFAFAFA),
    textBody: const Color(0xFFEDEDED),
    textSecondary: const Color(0xFFBDBDBD),
    textMuted: const Color(0xFF848484),
    textFaint: const Color(0xFF5C5C5C),
    inkAccent: const Color(0xFFFAFAFA),
    onInkAccent: const Color(0xFF202020),
    accent: const Color(0xFF3AA5F0),
    accentSoft: const Color(0xFF1A2A3D),
    accentBorder: const Color(0xFF294D73),
    mint: const Color(0xFF3BBF7D),
    mintSoft: const Color(0xFF142E21),
    mintBorder: const Color(0xFF21543B),
    amber: const Color(0xFFFFC740),
    amberSoft: const Color(0xFF332614),
    amberBorder: const Color(0xFF614722),
    coral: const Color(0xFFFF5E5E),
    coralSoft: const Color(0xFF36191A),
    coralBorder: const Color(0xFF6B2D2E),
    violet: const Color(0xFF9775FA),
    gradientTop: const Color(0xFF202020),
    gradientBottom: const Color(0xFF1A1A1A),
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
    Color? mint,
    Color? mintSoft,
    Color? mintBorder,
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
      mint: mint ?? this.mint,
      mintSoft: mintSoft ?? this.mintSoft,
      mintBorder: mintBorder ?? this.mintBorder,
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
      mint: Color.lerp(mint, other.mint, t)!,
      mintSoft: Color.lerp(mintSoft, other.mintSoft, t)!,
      mintBorder: Color.lerp(mintBorder, other.mintBorder, t)!,
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

class AppTheme {
  static ThemeData get light => _build(Brightness.light, KoeTokens.light);

  static ThemeData get dark => _build(Brightness.dark, KoeTokens.dark);

  static ThemeData _build(Brightness brightness, KoeTokens t) {
    final isDark = brightness == Brightness.dark;
    final colorScheme =
        (isDark ? const ColorScheme.dark() : const ColorScheme.light())
            .copyWith(
              surface: t.bgElevated,
              surfaceContainerHighest: t.bgSubtle,
              primary: t.accent,
              onPrimary: Colors.white,
              secondary: t.mint,
              onSecondary: Colors.white,
              error: t.coral,
              onError: Colors.white,
              onSurface: t.textPrimary,
              onSurfaceVariant: t.textSecondary,
              outline: t.border,
              outlineVariant: t.borderSoft,
            );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: t.bg,
      colorScheme: colorScheme,
      extensions: [t],
    );

    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.md),
      borderSide: BorderSide(color: t.border),
    );

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: t.textPrimary,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: t.textPrimary, size: 20),
      ),
      textTheme: TextTheme(
        displayLarge: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          color: t.textPrimary,
          letterSpacing: -0.8,
          height: 1.15,
        ),
        headlineMedium: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: t.textPrimary,
          letterSpacing: -0.35,
          height: 1.25,
        ),
        titleLarge: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: t.textPrimary,
          letterSpacing: -0.2,
          height: 1.3,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: t.textPrimary,
          letterSpacing: -0.15,
          height: 1.35,
        ),
        titleSmall: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: t.textPrimary,
          height: 1.35,
        ),
        bodyLarge: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w400,
          color: t.textPrimary,
          height: 1.55,
        ),
        bodyMedium: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: t.textSecondary,
          height: 1.45,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: t.textMuted,
          height: 1.4,
        ),
        labelLarge: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
          color: t.textPrimary,
        ),
        labelMedium: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: t.textSecondary,
        ),
        labelSmall: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: t.textMuted,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: t.borderSoft,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        color: t.bgCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: BorderSide(color: t.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.bgPanel,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s12,
          vertical: AppSpacing.s12,
        ),
        hintStyle: TextStyle(color: t.textMuted, fontSize: 13),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: t.accent, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: t.coral),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.inkAccent,
          foregroundColor: t.onInkAccent,
          disabledBackgroundColor: t.bgSubtle,
          disabledForegroundColor: t.textMuted,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.textPrimary,
          side: BorderSide(color: t.border),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.textPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.sm),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return t.inkAccent;
            }
            return t.bgPanel;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return t.onInkAccent;
            }
            return t.textSecondary;
          }),
          side: WidgetStatePropertyAll(BorderSide(color: t.border)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return t.textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accent;
          return t.bgSubtle;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.transparent;
          return t.border;
        }),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: t.bgCard,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: BorderSide(color: t.border),
        ),
        textStyle: TextStyle(
          color: t.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.bgCard,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
          side: BorderSide(color: t.border),
        ),
        titleTextStyle: TextStyle(
          color: t.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        contentTextStyle: TextStyle(
          color: t.textSecondary,
          fontSize: 13,
          height: 1.45,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.bgCard,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: t.bgCard,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.xl),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.textPrimary,
        contentTextStyle: TextStyle(
          color: t.bgCard,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 4,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(t.bgCard),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
    );
  }
}
