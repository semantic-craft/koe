import '../platform/mac_captions.dart';
import '../state/meeting_end_watch.dart';
import '../state/meeting_minutes.dart';
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../ai/stt_types.dart';
import '../platform/mac_app.dart';
import '../state/meeting_apps.dart';
import '../state/recorder_controller.dart';

/// Shows on Koe's Mac menu bar item what [RecorderController] is doing,
/// keeps the Mac awake meanwhile and asks before quitting then (#403). The
/// take and the text captured so far are saved before Koe quits. ⌃⌥⌘R and
/// ⌃⌥⌘B work from any app (#405). A meeting app taking the microphone asks
/// to start a take, and the meeting being over asks to stop it (#406).
class MacMenuBar {
  MacMenuBar(this._controller, {required this.onStart, MacApp? app})
    : _app = app ?? MacApp.shared {
    _app
      ..onAction = _run
      ..onQuit = _beforeQuit
      ..onHotKey = _hotKey
      ..onMicrophoneUsers = _microphoneUsers
      ..onMicrophoneSnapshot = _microphoneSnapshot
      ..onPromptAction = _promptAction;
    _controller.addListener(_show);
    _controller.addListener(_followTake);
    _controller.modelWorking.addListener(_show);
    _app.hotKeysTaken.addListener(_show);
    _followTake();
    _show();
  }

  final RecorderController _controller;
  final MacApp _app;
  final _captions = MacCaptions();
  String? _captionSnapshot;

  /// Shows the controls of the take, or all-day listening, just started
  /// from the menu or ⌃⌥⌘R, or why it did not start.
  final VoidCallback onStart;

  /// How long quitting waits for the take and text to be saved; the Mac
  /// quits anyway a second later.
  static const quitWait = Duration(seconds: 9);

  String? _titlePath;
  String _title = '';
  bool _starting = false;

  late final _meetingCalls = MeetingAppWatch(
    ask: _askAboutMeeting,
    muted: (app) => _controller.meetingAppPromptsMuted.contains(app),
  );

  /// Whether Koe watches for meeting apps. It watches during all-day
  /// listening too, without asking, so a call under way when listening is
  /// stopped is not asked about again.
  bool get _watching =>
      (_controller.meetingAppPrompts || _controller.phoneRecordingActive) &&
      _controller.phoneRecordingEnabled;

  void _show() {
    unawaited(_app.show(_status()));
    final c = _controller;
    final mode = c.liveMeetingClosing ? 'hidden' : c.liveDisplayMode;
    final entries = c.liveCaptions?.entries ?? c.liveMeetingSegments;
    final original = entries.isEmpty ? '' : entries.last.text;
    final translation = entries.isEmpty ? '' : entries.last.translation ?? '';
    final result = c.liveMinutes?.result;
    final minutes = result == null
        ? '速记尚未生成'
        : MeetingMinutes.parse(
            result.text,
            result.sources.length,
            sourceTexts: result.sources,
          ).export(result);
    final snapshot = '$mode|$original|$translation|$minutes';
    if (snapshot == _captionSnapshot ||
        (_captionSnapshot == null && mode == 'hidden')) {
      return;
    }
    _captionSnapshot = snapshot;
    unawaited(
      _captions
          .show(
            mode: mode,
            original: original,
            translation: translation,
            minutes: minutes,
          )
          .catchError((Object _) {
            if (c.liveMeetingNotice != '此平台的独立字幕窗口暂不可用') {
              c.liveMeetingNotice = '此平台的独立字幕窗口暂不可用';
              c.notifyListeners();
            }
          }),
    );
  }

  MacAppStatus _status() {
    final c = _controller;
    var state = MacAppState.idle;
    String? take;
    final lines = <String>[];
    final actions = <MacMenuAction>[];
    String? keepAwake;
    String? quitMessage;
    final quitInfo = <String>[];
    final saving = c.phoneRecordingSaving || c.textCaptureSaving;

    if (saving) {
      // Stop was pressed, so quitting does not ask again; it waits.
      state = MacAppState.working;
      lines.add(c.phoneRecordingSaving ? '正在保存录音' : '正在保存文字');
    } else if (c.phoneRecordingActive) {
      final paused = c.phoneRecordingPaused;
      state = paused ? MacAppState.paused : MacAppState.recording;
      take = paused ? '录音已暂停' : '录音中';
      if (c.phoneRecordingSpaceNotice case final notice?) lines.add(notice);
      actions.addAll([
        paused
            ? const MacMenuAction('resume', '继续录音')
            : const MacMenuAction('pause', '暂停录音'),
        const MacMenuAction('stop', '停止并保存'),
      ]);
      keepAwake = 'Koe is recording';
      quitMessage = '正在录音，要退出 Koe 吗？';
      quitInfo.add('录音会先保存好再退出。');
    } else if (c.textCaptureActive) {
      final allDay = c.textCaptureAllDay;
      final paused = c.textCapturePaused;
      state = paused ? MacAppState.paused : MacAppState.recording;
      lines.add(
        allDay
            ? (paused ? '全天监听已暂停' : '全天监听中')
            : (paused ? '纯文字记录已暂停' : '纯文字记录中'),
      );
      actions.add(MacMenuAction('stop', allDay ? '停止全天监听' : '停止并保存文字'));
      keepAwake = allDay ? 'Koe is listening all day' : 'Koe is capturing text';
      quitMessage = allDay ? '正在全天监听，要退出 Koe 吗？' : '正在纯文字记录，要退出 Koe 吗？';
      quitInfo.add(allDay ? '已识别的文字会先保存，下次打开 Koe 时接着听。' : '已识别的文字会先保存好再退出。');
    } else if (c.phoneRecordingEnabled) {
      actions.add(
        MacMenuAction('start', c.allDayListening ? '开始全天监听' : '开始录音'),
      );
    }
    // ⌃⌥⌘B is left to other apps while there is nothing to mark.
    if (c.liveMeetingId != null &&
        c.liveMeetingAvailable &&
        !c.liveMeetingClosing) {
      actions.addAll(const [
        MacMenuAction('captions', '切换字幕 / 纪要 / 隐藏'),
        MacMenuAction('captionsHide', '隐藏字幕窗口'),
      ]);
    }
    final hotKeys = [
      if (c.liveMeetingId != null &&
          c.liveMeetingAvailable &&
          !c.liveMeetingClosing) ...[
        'captions',
        'captionsHide',
      ],
      if (c.recordHotKey && c.phoneRecordingEnabled) 'record',
      if (c.highlightHotKey &&
          !saving &&
          (c.phoneRecordingActive || c.textCaptureActive))
        'highlight',
    ];
    if (hotKeys.contains('highlight') &&
        _app.hotKeysTaken.value.contains('highlight')) {
      lines.add('⌃⌥⌘B 被别的应用占用，回到 Koe 标重点');
    }

    if (_app.hotKeysTaken.value.any(
      (key) => key == 'captions' || key == 'captionsHide',
    )) {
      lines.add('字幕快捷键被其它应用占用，可用菜单切换');
    }
    final transcribing = c.transcribing || c.fileProcessingBusy;
    final retrieving =
        c.isExporting || c.autoTransferActive || c.downloadingFileId != null;
    // Transcription runs through the models too.
    final processing = c.modelWorking.value && !transcribing;
    if (transcribing) {
      lines.add(_transcription());
      keepAwake ??= 'Koe is transcribing';
      quitInfo.add('进行中的转写会中断，下次打开 Koe 时接着做或从头重跑。');
    }
    if (retrieving) {
      lines.add('正在从录音豆取回录音');
      keepAwake ??= 'Koe is retrieving recordings';
      quitInfo.add('从录音豆取回录音会中断，下次连上时可以再取。');
    }
    if (processing) {
      lines.add('正在处理录音');
      keepAwake ??= 'Koe is processing recordings';
      quitInfo.add('进行中的处理会中断，之后可以重新生成。');
    }
    if (transcribing || retrieving || processing) {
      if (state == MacAppState.idle) state = MacAppState.working;
      quitMessage ??= 'Koe 还在处理录音，要退出吗？';
    }
    if (take == null && lines.isEmpty) lines.add('没有进行中的工作');

    return MacAppStatus(
      state: state,
      take: take,
      elapsed: c.phoneRecordingElapsed,
      running: state == MacAppState.recording && take != null,
      lines: lines,
      actions: actions,
      keepAwake: keepAwake,
      quitMessage: quitMessage,
      quitInfo: quitInfo.join('\n'),
      saving: saving,
      hotKeys: hotKeys,
      watchMicrophone: _watching,
    );
  }

  String _transcription() {
    final path = _controller.transcribingPath;
    if (path == null) return '正在转写';
    // Reading the title touches the disk; it is read once per recording.
    if (path != _titlePath) {
      _titlePath = path;
      final title = _controller
          .recordingView(RecordingReference(path: path))
          .title
          .characters;
      _title = title.length > 24 ? '${title.take(23)}…' : '$title';
    }
    final progress = _controller.fileTranscriptionProgress;
    final stage = switch (progress?.stage) {
      SttFileStage.preparing => '准备音频',
      SttFileStage.uploading => switch (progress?.fraction) {
        final fraction? => '上传 ${(fraction * 100).floor()}%',
        null => '上传中',
      },
      SttFileStage.queued => '等待处理',
      SttFileStage.fetching => '获取结果',
      SttFileStage.processing || null => '处理中',
    };
    return '正在转写「$_title」· $stage';
  }

  void _run(String action) {
    final c = _controller;
    switch (action) {
      case 'captions':
        c.cycleLiveDisplay();
      case 'captionsHide':
        c.setLiveDisplayMode('hidden');
      case 'start':
        unawaited(_start());
      case 'pause':
        unawaited(c.pausePhoneRecording());
      case 'resume':
        unawaited(c.resumePhoneRecording());
      case 'stop':
        if (c.phoneRecordingActive) {
          unawaited(c.stopPhoneRecording());
        } else if (c.textCaptureActive) {
          unawaited(c.stopTextCapture());
        }
    }
  }

  /// Starts a take, or all-day listening when it is on, here rather than
  /// from the sheet, which starts its take once drawn: a closed window
  /// draws nothing. True when it runs.
  Future<bool> _start() async {
    final c = _controller;
    if (_starting) return false;
    _starting = true;
    try {
      if (c.allDayListening) {
        await c.startTextCapture(allDay: true);
      } else {
        await c.startPhoneRecording();
      }
    } finally {
      _starting = false;
    }
    onStart();
    return c.phoneRecordingActive || c.textCaptureActive;
  }

  /// Stops the take, or text capture, and answers as [MacApp.onHotKey]
  /// does once it is saved, so a save that failed is told too.
  Future<String?> _stop() async {
    final c = _controller;
    if (c.phoneRecordingActive) {
      return await c.stopPhoneRecording() != null ? 'stopped' : 'failed';
    }
    if (c.textCaptureActive) {
      return await c.stopTextCapture() != null ? 'stopped' : 'failed';
    }
    return null;
  }

  /// A global hot key pressed in any app; see [MacApp.onHotKey].
  Future<String?> _hotKey(String key) async {
    final c = _controller;
    if (_starting || c.phoneRecordingSaving || c.textCaptureSaving) {
      return null;
    }
    switch (key) {
      case 'captions':
        c.cycleLiveDisplay();
        return 'shown';
      case 'captionsHide':
        c.setLiveDisplayMode('hidden');
        return 'hidden';
      case 'record':
        if (c.phoneRecordingActive || c.textCaptureActive) return _stop();
        if (!c.phoneRecordingEnabled) return null;
        return await _start() ? 'started' : 'failed';
      case 'highlight':
        final marked =
            c.markPhoneRecordingHighlight() != null ||
            c.markTextCaptureHighlight();
        return marked ? 'marked' : null;
    }
    return null;
  }

  /// Tells the meeting-app calls what Koe records, or forgets them while
  /// Koe does not watch.
  void _followTake() {
    final c = _controller;
    if (!_watching) {
      _meetingCalls.reset();
      return;
    }
    _meetingCalls.recording = c.phoneRecordingActive || c.textCaptureActive;
  }

  void _microphoneUsers(List<String> bundleIds) {
    if (_controller.meetingAppPrompts) _meetingCalls.microphoneUsers(bundleIds);
  }

  void _microphoneSnapshot(MicrophoneSnapshot snapshot) {
    _controller.meetingEndWatch.observe(snapshot);
    if (!snapshot.available) _meetingCalls.reset();
  }

  void _askAboutMeeting(MeetingAppAsk ask, String app) {
    final c = _controller;
    // All-day listening goes on through meetings and after them.
    if (c.textCaptureActive && c.textCaptureAllDay) return;
    switch (ask) {
      case MeetingAppAsk.start:
        final take = c.allDayListening ? '全天监听' : '录音';
        final name = meetingAppName(app);
        unawaited(
          _app.prompt(
            meetingBrowsers.containsKey(app)
                ? '$name 正在用麦克风，可能在开 Google Meet。要开始$take吗？'
                : '$name 正在用麦克风，要开始$take吗？',
            [
              MacMenuAction('mute:$app', '不再提醒'),
              const MacMenuAction('dismiss', '不用'),
              MacMenuAction('start', '开始$take'),
            ],
          ),
        );
      case MeetingAppAsk.stop:
        if (c.meetingEndWatch.enabled || !c.meetingAppPrompts) return;
        final take = c.phoneRecordingActive;
        unawaited(
          _app.prompt(take ? '会议好像结束了，要停止录音吗？' : '会议好像结束了，要停止纯文字记录吗？', [
            const MacMenuAction('dismiss', '继续'),
            MacMenuAction('stop', take ? '停止并保存' : '停止并保存文字'),
          ]),
        );
    }
  }

  /// A button pressed on a meeting prompt; see [MacApp.onPromptAction].
  Future<String?> _promptAction(String action) async {
    final c = _controller;
    if (action.startsWith('mute:')) {
      c.muteMeetingApp(action.substring('mute:'.length));
      return null;
    }
    if (_starting || c.phoneRecordingSaving || c.textCaptureSaving) {
      return null;
    }
    switch (action) {
      case 'start':
        if (c.phoneRecordingActive || c.textCaptureActive) return null;
        return await _start() ? 'started' : 'failed';
      case 'stop':
        // Asked about a take that has since been stopped another way.
        if (!_meetingCalls.stopAsked) return null;
        return _stop();
    }
    return null;
  }

  /// Saves the take, and the text with all-day listening kept for the next
  /// launch; a save under way is waited for. Transcription is left to its
  /// journal.
  Future<void> _beforeQuit() async {
    final c = _controller;
    await Future.wait<Object?>([
      c.stopPhoneRecording(),
      c.stopTextCapture(keepAllDay: true),
    ]).timeout(quitWait, onTimeout: () => const []);
  }

  void dispose() {
    _controller.removeListener(_show);
    _controller.removeListener(_followTake);
    _controller.modelWorking.removeListener(_show);
    _app.hotKeysTaken.removeListener(_show);
    _meetingCalls.reset();
    unawaited(_captions.hide().catchError((Object _) {}));
    _app
      ..onAction = null
      ..onQuit = null
      ..onHotKey = null
      ..onMicrophoneUsers = null
      ..onMicrophoneSnapshot = null
      ..onPromptAction = null;
  }
}
