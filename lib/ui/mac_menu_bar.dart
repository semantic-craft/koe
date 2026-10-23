import 'dart:async';

import 'package:flutter/widgets.dart';

import '../ai/stt_types.dart';
import '../platform/mac_app.dart';
import '../state/recorder_controller.dart';

/// Shows on Koe's Mac menu bar item what [RecorderController] is doing,
/// keeps the Mac awake meanwhile and asks before quitting then (#403). The
/// take and the text captured so far are saved before Koe quits.
class MacMenuBar {
  MacMenuBar(this._controller, {required this.onStart, MacApp? app})
    : _app = app ?? MacApp.shared {
    _app
      ..onAction = _run
      ..onQuit = _beforeQuit;
    _controller.addListener(_show);
    _controller.modelWorking.addListener(_show);
    _show();
  }

  final RecorderController _controller;
  final MacApp _app;

  /// Opens the recording sheet, as 新录音 does.
  final VoidCallback onStart;

  /// How long quitting waits for the take and text to be saved; the Mac
  /// quits anyway a second later.
  static const quitWait = Duration(seconds: 9);

  String? _titlePath;
  String _title = '';

  void _show() => unawaited(_app.show(_status()));

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
      case 'start':
        onStart();
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
    _controller.modelWorking.removeListener(_show);
    _app
      ..onAction = null
      ..onQuit = null;
  }
}
