import 'dart:async';

/// The meeting apps Koe watches on the Mac (#406), by bundle ID, and the
/// name a prompt shows: Shiyin's (`Services/MeetingDetector.swift`) and
/// those used for meetings in China.
const meetingApps = {
  'us.zoom.xos': 'Zoom',
  'com.microsoft.teams2': 'Microsoft Teams',
  'com.microsoft.teams': 'Microsoft Teams',
  'Cisco-Systems.Spark': 'Webex',
  'com.cisco.webexmeetingsapp': 'Webex',
  'com.apple.FaceTime': 'FaceTime',
  'com.tinyspeck.slackmacgap': 'Slack',
  'jp.naver.line.mac': 'LINE',
  'com.hnc.Discord': 'Discord',
  'com.tencent.meeting': '腾讯会议',
  'com.electron.lark': '飞书',
  'com.alibaba.DingTalkMac': '钉钉',
  'com.tencent.WeWorkMac': '企业微信',
};

/// Browsers, which may be in a Google Meet call.
const meetingBrowsers = {
  'com.google.Chrome': 'Chrome',
  'com.apple.Safari': 'Safari',
  'com.microsoft.edgemac': 'Edge',
  'company.thebrowser.Browser': 'Arc',
  'org.mozilla.firefox': 'Firefox',
  'com.brave.Browser': 'Brave',
};

/// The name of a listed app, by its bundle ID.
String meetingAppName(String app) =>
    meetingApps[app] ?? meetingBrowsers[app] ?? app;

enum MeetingAppAsk { start, stop }

/// Watches the meeting apps using the microphone and says when to ask
/// about recording (#406), as Shiyin does: a call that has used the
/// microphone for [startAfter] while Koe records nothing asks once to
/// start, and once every call that used it during the take has let go of
/// it for [endAfter], Koe asks once to stop. It only asks.
///
/// Unlike Shiyin, a call is asked about at its [startAfter] mark only: one
/// Koe was recording then does not ask to start again when the take is
/// stopped before hanging up.
class MeetingAppWatch {
  MeetingAppWatch({required this.ask, required this.muted});

  static const startAfter = Duration(seconds: 5);
  static const endAfter = Duration(seconds: 10);

  final void Function(MeetingAppAsk ask, String app) ask;

  /// Whether the user chose 不再提醒 for an app.
  final bool Function(String app) muted;

  final _calls = <String, _Call>{};
  Set<String> _using = const {};
  final _usedDuringTake = <String>{};
  bool _recording = false;
  bool _stopAsked = false;

  /// The listed app [bundleId] is, or is a helper of
  /// (`com.google.Chrome.helper`); null when none is.
  static String? listed(String bundleId) {
    for (final app in [...meetingApps.keys, ...meetingBrowsers.keys]) {
      if (bundleId == app || bundleId.startsWith('$app.')) return app;
    }
    return null;
  }

  /// Takes the bundle IDs of the processes using the microphone, which the
  /// Mac sends whenever they change.
  void microphoneUsers(Iterable<String> bundleIds) {
    final using = {for (final id in bundleIds) ?listed(id)};
    for (final app in using) {
      final call = _calls[app] ??= _Call(Timer(startAfter, () => _due(app)));
      call.ending?.cancel();
      call.ending = null;
    }
    for (final MapEntry(key: app, value: call) in _calls.entries) {
      if (!using.contains(app)) {
        call.ending ??= Timer(endAfter, () => _ended(app));
      }
    }
    _using = using;
    if (_recording) _usedDuringTake.addAll(using);
    // Due while the app had let go of the microphone for a moment.
    for (final app in using) {
      final call = _calls[app]!;
      if (call.starting == null && !call.decided) _decide(app, call);
    }
  }

  /// Whether Koe records: a take or text capture, all-day listening
  /// included.
  set recording(bool value) {
    if (value == _recording) return;
    _recording = value;
    _stopAsked = false;
    _usedDuringTake.clear();
    if (value) _usedDuringTake.addAll(_using);
  }

  /// Whether Koe has asked to stop the take under way; a take started
  /// after the question was put does not answer it.
  bool get stopAsked => _stopAsked;

  void _due(String app) {
    final call = _calls[app]!..starting = null;
    if (_using.contains(app)) _decide(app, call);
  }

  void _decide(String app, _Call call) {
    call.decided = true;
    if (!_recording && !muted(app)) ask(MeetingAppAsk.start, app);
  }

  void _ended(String app) {
    _calls.remove(app)!.starting?.cancel();
    if (!_recording || _stopAsked || !_usedDuringTake.contains(app)) return;
    if (_usedDuringTake.any(_calls.containsKey)) return;
    _stopAsked = true;
    ask(MeetingAppAsk.stop, app);
  }

  /// Forgets every call, as when Koe stops watching.
  void reset() {
    for (final call in _calls.values) {
      call.starting?.cancel();
      call.ending?.cancel();
    }
    _calls.clear();
    _using = const {};
    _usedDuringTake.clear();
    _stopAsked = false;
  }
}

/// A listed app's call: from when it takes the microphone until it has let
/// go of it for [MeetingAppWatch.endAfter].
class _Call {
  _Call(this.starting);

  /// Runs at the [MeetingAppWatch.startAfter] mark; null after.
  Timer? starting;
  Timer? ending;

  /// Whether the call was asked about, or not asked about because Koe was
  /// recording or the app was muted.
  bool decided = false;
}
