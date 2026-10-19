import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/theme/app_theme.dart';

// #306: the dialog title slot rendered blank on iPhone and Mac because the
// title style had no color.
void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    for (final (name, theme) in [
      ('light', () => AppTheme.light),
      ('dark', () => AppTheme.dark),
    ]) {
      testWidgets('$name dialog title is drawn in textPrimary on '
          '${platform.name}', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final data = theme();
        await tester.pumpWidget(
          MaterialApp(
            theme: data,
            home: const AlertDialog(
              title: Text('新转写版本'),
              content: Text('正文'),
            ),
          ),
        );
        final color = DefaultTextStyle.of(
          tester.element(find.text('新转写版本')),
        ).style.color;
        expect(color, data.extension<KoeTokens>()!.textPrimary);
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}
