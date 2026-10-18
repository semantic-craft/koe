import 'package:koe/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots to home shell', (tester) async {
    await tester.pumpWidget(const KoeApp());
    // Phone primary tabs are Today, Projects and Materials (#131).
    expect(find.text('今日'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('资料'), findsOneWidget);

    final nav = tester.widget<Container>(
      find.byKey(const ValueKey('bottom-navigation-bar')),
    );
    final decoration = nav.decoration! as BoxDecoration;
    expect(decoration.border, isNotNull);
    expect(decoration.borderRadius, isNull);

    final activeIndicator = find.byKey(const ValueKey('active-tab-indicator'));
    expect(activeIndicator, findsOneWidget);
    expect(
      tester.getCenter(activeIndicator).dy,
      greaterThan(tester.getCenter(find.text('今日')).dy),
    );
  });
}
