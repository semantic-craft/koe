import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/recording_shortcut_service.dart';
import 'package:quick_actions/quick_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('on Android the Koe icon offers 开始录音, and a cold launch from it '
      'asks for one recording', () async {
    final launcher = _Launcher(coldLaunch: 'start_recording');
    var requests = 0;

    await RecordingShortcutService(quickActions: launcher).initialize(
      onStartRecording: () async => requests++,
    );

    expect(launcher.items.map((item) => (item.type, item.localizedTitle)), [
      ('start_recording', '开始录音'),
    ]);
    expect(requests, 1, reason: 'the launch is reported twice');

    // Chosen again while Koe is open.
    launcher.choose('start_recording');
    expect(requests, 2);
  });
}

/// quick_actions on Android: a cold launch's shortcut comes once from the
/// launching intent as soon as a handler is set, then again from
/// getLaunchAction.
class _Launcher implements QuickActions {
  _Launcher({this.coldLaunch});

  final String? coldLaunch;
  late QuickActionHandler _handler;
  List<ShortcutItem> items = [];

  void choose(String type) => _handler(type);

  @override
  Future<void> initialize(QuickActionHandler handler) async {
    _handler = handler;
    final launch = coldLaunch;
    if (launch == null) return;
    handler(launch);
    await Future<void>.delayed(Duration.zero);
    handler(launch);
  }

  @override
  Future<void> setShortcutItems(List<ShortcutItem> items) async {
    this.items = items;
  }

  @override
  Future<void> clearShortcutItems() async => items = [];
}
