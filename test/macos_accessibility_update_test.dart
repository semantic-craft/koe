import 'dart:ui' as ui;

import 'package:koe/state/recorder_controller.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/macos_accessibility_app.dart' show PreviewController;

// Check the serialized incremental updates, not just the final SemanticsNode
// tree. AXTree rejects a serialized node that no reachable parent claims.
class _AXUpdateBinding extends AutomatedTestWidgetsFlutterBinding {
  final nodes = <int, List<int>>{};
  final orphans = <int>[];

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() => _AXUpdate(this);
}

class _AXUpdate implements ui.SemanticsUpdateBuilder {
  _AXUpdate(this.binding);
  final _AXUpdateBinding binding;
  final _delegate = ui.SemanticsUpdateBuilder();
  final _updated = <int>{};

  // Forward every SDK parameter unchanged while recording the actual serialized
  // child edges. This keeps the probe compatible with added engine fields.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final args = invocation.namedArguments;
      final id = args[#id] as int;
      binding.nodes[id] = List<int>.of(
        args[#childrenInTraversalOrder] as Iterable<int>,
      );
      _updated.add(id);
      return Function.apply(_delegate.updateNode, [], args);
    }
    return super.noSuchMethod(invocation);
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) => _delegate.updateCustomAction(
    id: id,
    label: label,
    hint: hint,
    overrideId: overrideId,
  );

  @override
  ui.SemanticsUpdate build() {
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final child in binding.nodes[id] ?? <int>[]) {
        visit(child);
      }
    }

    visit(0);
    binding.orphans.addAll(_updated.difference(reachable));
    binding.nodes.removeWhere((id, _) => !reachable.contains(id));
    return _delegate.build();
  }
}

void main() {
  final binding = _AXUpdateBinding();

  // The warm shell switches tiers at 1100 logical px (lib/ui/shell.dart):
  // at or above that width the desktop sidebar sits beside the reader;
  // below it the pages stack over a bottom navigation bar and detail pushes
  // as a full route with its own back button. Both tiers must serialize
  // only nodes the native root can reach.
  Future<void> exerciseShell(
    WidgetTester tester, {
    required Size window,
    required bool wide,
  }) async {
    final semantics = tester.ensureSemantics();
    final controller = PreviewController();
    binding.nodes.clear();
    binding.orphans.clear();
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: MaterialApp(
          theme: AppTheme.light.copyWith(platform: TargetPlatform.macOS),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Tier sanity: the shell must actually have switched layout, not just
    // resized by a few pixels.
    expect(
      find.byKey(
        ValueKey(wide ? 'desktop-navigation' : 'bottom-navigation-bar'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        ValueKey(wide ? 'bottom-navigation-bar' : 'desktop-navigation'),
      ),
      findsNothing,
    );
    if (!wide) {
      // The compact shell opens on Today; the recording rows live under the
      // Materials tab (#131).
      await tester.tap(find.byKey(const ValueKey('nav-library')));
      await tester.pumpAndSettle();
    }
    Future<void> transitionFrames() async {
      // Inspect each transition frame: the settled tree alone stays clean
      // even when the native bridge has already rejected an earlier update.
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    for (final id in [100, 101, 102]) {
      final row = find.byKey(ValueKey('recording-row-/tmp/ui-preview-$id.wav'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await transitionFrames();
      // Narrow tier: the detail route covers the rows, so walk back to the
      // library before opening the next recording.
      if (!wide) {
        await tester.pageBack();
        await transitionFrames();
      }
    }
    if (wide) {
      for (final tab in ['settings', 'device', 'home']) {
        await tester.tap(find.byKey(ValueKey('nav-$tab')));
        await tester.pumpAndSettle();
      }
    } else {
      // Compact tier: settings opens from the header, the device section is a
      // pushed route from settings, and Today is the bottom navigation entry.
      // The library header scrolls away with the rows (#236); bring it back.
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('nav-settings')),
        find.byKey(const ValueKey('local-recordings-refresh')),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('device-entry')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('device-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('device-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-today')));
      await tester.pumpAndSettle();
    }
    final failures = List<int>.of(binding.orphans);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
    controller.dispose();
    expect(
      failures,
      isEmpty,
      reason: 'Every serialized node must be reachable in the native AXTree.',
    );
  }

  testWidgets('wide window serializes no orphan accessibility nodes', (
    tester,
  ) async {
    await exerciseShell(tester, window: const Size(1280, 900), wide: true);
  });

  testWidgets('narrow window serializes no orphan accessibility nodes', (
    tester,
  ) async {
    await exerciseShell(tester, window: const Size(390, 844), wide: false);
  });
}
