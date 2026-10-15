import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anker_recorder/theme/app_theme.dart';

void main() {
  testWidgets('light and dark themes register KoeTokens', (tester) async {
    final light = AppTheme.light;
    final dark = AppTheme.dark;
    final lightTokens = light.extension<KoeTokens>();
    final darkTokens = dark.extension<KoeTokens>();
    expect(lightTokens, isNotNull);
    expect(darkTokens, isNotNull);
    // The warm mainline is light-locked; dark is its structural counterpart
    // and must stay registered independently.
    expect(darkTokens, isNot(same(lightTokens)));
  });

  testWidgets('KoeTokens.of falls back to light without extension', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData(), home: const SizedBox.shrink()),
    );
    final context = tester.element(find.byType(SizedBox));
    expect(KoeTokens.of(context), same(KoeTokens.light));
  });

  testWidgets('KoeTokens keeps warm accent and surfaces', (tester) async {
    final tokens = KoeTokens.light;
    expect(tokens.accent, same(AppColors.accent));
    expect(tokens.bg, same(AppColors.bg));
    expect(tokens.bgCard, same(AppColors.bgCard));
    expect(tokens.textPrimary, same(AppColors.textPrimary));
    expect(tokens.border, same(AppColors.border));
    expect(tokens.gradientTop, same(AppColors.gradientTop));
    expect(tokens.gradientBottom, same(AppColors.gradientBottom));
    expect(tokens.cardShadow, equals(AppColors.cardShadow));
  });

  test('KoeTokens.copyWith replaces only given fields', () {
    final tokens = KoeTokens.light;
    final changed = tokens.copyWith(accent: const Color(0xFF123456));
    expect(changed.accent, const Color(0xFF123456));
    expect(changed.bg, same(tokens.bg));
    expect(changed.border, same(tokens.border));
  });

  test('KoeTokens.lerp interpolates colors and picks shadows at midpoint', () {
    final a = KoeTokens.light.copyWith(accent: const Color(0xFF000000));
    final b = KoeTokens.light.copyWith(accent: const Color(0xFF0000FE));
    final mid = a.lerp(b, 0.5);
    expect(mid.accent, const Color(0xFF00007F));
    expect(mid.bg, a.bg);
    expect(mid.floatingShadow, a.floatingShadow);
    final flipped = a.lerp(b, 0.75);
    expect(flipped.floatingShadow, b.floatingShadow);
  });
}
