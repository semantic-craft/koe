import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/mac_interpreting.dart';
import 'package:koe/state/mac_interpreting.dart';
import 'package:koe/state/live_minutes_store.dart';
import 'package:koe/ui/widgets/mac_interpreting_panel.dart';

class Devices extends MacInterpreting {
  Devices({this.ready = false});
  final bool ready;
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async => method == 'devices'
      ? {
          'inputs': [
            {'uid': 'mic', 'name': '内置麦克风'},
          ],
          'outputs': ready
              ? [
                  {'uid': 'hole', 'name': 'BlackHole 2ch'},
                ]
              : [],
          'defaultInput': ready ? 'hole' : 'mic',
          'error': '',
        }
      : null;
}

void main() {
  testWidgets(
    'reopening settings shows the pinned input after automatic routing',
    (tester) async {
      final m = MacInterpretingState(
        bridge: Devices(ready: true),
        store: LiveMinutesStore(inMemory: true),
        translate: (s, a, c) async => '',
        configuration: () => 'test',
      );
      await m.enable(input: 'mic', output: 'hole', automatic: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MacInterpretingPanel(
                model: m,
                onEnable: (a, b, c) async {},
                canInstall: () => true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('内置麦克风'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets(
    'missing driver has recovery instructions at narrow width and large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final m = MacInterpretingState(
        bridge: Devices(),
        store: LiveMinutesStore(inMemory: true),
        translate: (s, a, c) async => '',
        configuration: () => 'test',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SingleChildScrollView(
                child: MacInterpretingPanel(
                  model: m,
                  onEnable: (a, b, c) async {},
                  canInstall: () => true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('尚未检测到'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '本场启用'))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
}
