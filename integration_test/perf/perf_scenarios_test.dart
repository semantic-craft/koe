// Automated performance scenarios. Run with `scripts/perf-check`, which drives
// this file in profile mode on macOS and checks the numbers against
// integration_test/perf/thresholds.json.
//
// Every scenario keeps a list scrolling so frames are produced the whole
// time, then applies one workload through the app's real code path:
//
// - ble_slices      audio slices fed through BleService.handleNotification
// - playback        position ticks from a player while 40 controller
//                   watchers and the inline player are on screen
// - first_play      RecorderController.playExported on a long raw .opus
//                   recording without a cached .ogg
// - transcript_save bursts of TranscriptStore.save with a large library
// - ask_rank        question retrieval over a 400k-character corpus
// - recording       a microphone take with its panel on screen: a level
//                   every 100 ms, notes kept as they are typed, highlights
// - take_save       stopping an hour-long microphone take, which hashes the
//                   115 MB file before it joins the library
// - wifi_save       a Wi‑Fi export of a million slice units (about three
//                   hours of audio) from a recorder on this Mac; save_ms runs
//                   from the recorder's last unit to the file being saved
//
// Nothing touches personal data: path_provider points at a temporary folder,
// stores are in memory, BLE never scans and no credential is read.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/platform/calendar_meetings.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/protocol/commands.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/transcript_store.dart';
import 'package:koe/ui/screens/new_recording_sheet.dart';
import 'package:koe/ui/widgets/inline_player.dart';
import 'package:koe/wifi/wifi_export_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import '../../test/support/fake_wifi_recorder.dart';
import 'rank.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  late Directory documents;
  final results = <String, Object?>{};
  final frameWatch = _stopWhenNoFrames(binding);

  setUpAll(() async {
    documents = await Directory.systemTemp.createTemp('koe-perf-');
    PathProviderPlatform.instance = _TempPathProvider(documents.path);
  });
  tearDownAll(() async {
    frameWatch.cancel();
    binding.reportData = {...?binding.reportData, 'perf': results};
    if (await documents.exists()) await documents.delete(recursive: true);
  });

  Future<void> scenario(
    WidgetTester tester,
    String name, {
    required RecorderController controller,
    required Future<void> Function() workload,
    bool inlinePlayer = false,
    bool recordingPanel = false,
    Map<String, Object?> Function()? measured,
  }) async {
    final scroll = ScrollController();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          home: _Workload(
            scroll: scroll,
            documents: documents.path,
            inlinePlayer: inlinePlayer,
            recordingPanel: recordingPanel,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    var notifications = 0;
    void count() => notifications++;
    controller.addListener(count);
    final frames = _FrameRecorder();
    final memory = _MemorySampler();
    final watch = Stopwatch();
    await binding.traceAction(() async {
      frames.start();
      memory.start();
      // Keep frames coming for the whole workload.
      unawaited(_keepScrolling(scroll));
      watch.start();
      await workload();
      watch.stop();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      memory.stop();
      frames.stop();
    }, reportKey: '${name}_timeline');
    scroll.dispose();
    controller.removeListener(count);
    results[name] = {
      ...frames.summary(),
      ...memory.summary(),
      'workload_ms': watch.elapsedMilliseconds,
      'controller_notifications': notifications,
      ...?measured?.call(),
    };
    // ignore: avoid_print
    print('[perf] $name ${results[name]}');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  }

  // The window only produces frames at full rate once it is on screen.
  testWidgets('warm_up', (tester) async {
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: scroll,
            itemCount: 200,
            itemBuilder: (_, i) => ListTile(title: Text('$i')),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    unawaited(_keepScrolling(scroll));
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
  });

  testWidgets('ble_slices', (tester) async {
    final ble = _QuietBle();
    final controller = _controller(ble: ble);
    await scenario(
      tester,
      'ble_slices',
      controller: controller,
      workload: () async {
        // ~250 slices per second, the pace of a BLE file retrieval.
        var sequence = 0;
        final done = Completer<void>();
        final timer = Timer.periodic(const Duration(milliseconds: 20), (t) {
          for (var i = 0; i < 5; i++) {
            ble.handleNotification(_sliceFrame(sequence++));
          }
          if (sequence >= 2000) {
            t.cancel();
            done.complete();
          }
        });
        await done.future;
        timer.cancel();
      },
    );
    controller.dispose();
  });

  testWidgets('playback', (tester) async {
    final player = _PerfPlayer();
    final controller = _controller(player: player);
    controller.playingPath = '${documents.path}/178.wav';
    controller.duration = const Duration(hours: 2);
    await scenario(
      tester,
      'playback',
      controller: controller,
      inlinePlayer: true,
      workload: () async {
        var position = Duration.zero;
        final done = Completer<void>();
        final timer = Timer.periodic(const Duration(milliseconds: 16), (t) {
          position += const Duration(milliseconds: 16);
          player.emitPosition(position);
          if (t.tick >= 400) {
            t.cancel();
            done.complete();
          }
        });
        await done.future;
        timer.cancel();
      },
    );
    controller.dispose();
  });

  testWidgets('first_play', (tester) async {
    // 24 MB of raw 160-byte frames ≈ 50 minutes of recording.
    final raw = File('${documents.path}/1783822462.opus');
    final frame = Uint8List(160);
    for (var i = 0; i < 160; i++) {
      frame[i] = (i * 31 + 7) & 0xFF;
    }
    final sink = raw.openWrite();
    for (var i = 0; i < 150000; i++) {
      sink.add(frame);
    }
    await sink.close();
    final player = _PerfPlayer();
    final controller = _controller(player: player);
    await scenario(
      tester,
      'first_play',
      controller: controller,
      workload: () => controller.playExported(raw.path),
    );
    controller.dispose();
  });

  testWidgets('transcript_save', (tester) async {
    final byPath = <String, String>{};
    final byFileId = <int, String>{};
    final segments = <String, List<TranscriptSegment>>{};
    for (var recording = 0; recording < 120; recording++) {
      final id = 1783000000 + recording;
      final lines = [
        for (var i = 0; i < 600; i++)
          TranscriptSegment(
            text: '第$recording段第$i句：下周和供应商确认报价单，预算控制在十万以内',
            start: Duration(seconds: i * 6),
            end: Duration(seconds: i * 6 + 5),
            speaker: '${i % 3 + 1}',
          ),
      ];
      final text = lines.map((s) => s.text).join('\n');
      byPath['${documents.path}/$id.wav'] = text;
      byFileId[id] = text;
      segments['file:$id'] = lines;
    }
    Future<void> save() => TranscriptStore.save(
      byPath: byPath,
      byFileId: byFileId,
      aliasesByPath: const {},
      aliasesByFileId: const {},
      segments: segments,
    );
    // The app loads transcripts.json at startup, so the store already knows
    // how large the file is before the first edit saves it.
    await save();
    final controller = _controller();
    await scenario(
      tester,
      'transcript_save',
      controller: controller,
      workload: () async {
        // Three bursts, the way edits and retranscriptions save.
        for (var burst = 0; burst < 3; burst++) {
          await Future.wait([for (var i = 0; i < 5; i++) save()]);
        }
      },
    );
    controller.dispose();
  });

  testWidgets('ask_rank', (tester) async {
    final texts = <String>[];
    var chars = 0;
    for (var i = 0; chars < 400000; i++) {
      final line = switch (i % 4) {
        0 => '第$i段：下周和供应商确认报价单，预算控制在十万以内',
        1 => '第$i段：周末去看房，顺便约中介聊聊贷款',
        2 => '第$i段：报价单里的运费要单独列出来',
        _ => '第$i段：今天的会议主要讨论了招聘计划',
      };
      texts.add(line);
      chars += line.length;
    }
    final controller = _controller();
    await scenario(
      tester,
      'ask_rank',
      controller: controller,
      workload: () async {
        for (final question in [
          '供应商的报价单预算是多少？',
          '看房的时候要问中介什么',
          '招聘计划讨论了什么',
          '运费怎么算',
          '下周要做什么',
        ]) {
          await rankForPerf(question, texts);
        }
      },
    );
    controller.dispose();
  });

  testWidgets('recording', (tester) async {
    final mic = _PerfMic();
    final controller = _controller(phoneRecorder: mic);
    await controller.startPhoneRecording();
    await scenario(
      tester,
      'recording',
      controller: controller,
      recordingPanel: true,
      workload: () async {
        // Eight seconds of a conversation's levels, a note keystroke about
        // every 300 ms and two highlights. Only the highlights notify.
        var notes = '';
        for (var tick = 1; tick <= 80; tick++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          mic.emit(tick % 10 < 6 ? -24.0 - tick % 5 : -55.0);
          if (tick % 3 == 0) controller.setPhoneRecordingNotes(notes += '记');
          if (tick % 40 == 0) controller.markPhoneRecordingHighlight();
        }
      },
    );
    await controller.discardPhoneRecording();
    controller.dispose();
  });

  testWidgets('take_save', (tester) async {
    final controller = _controller(phoneRecorder: _HourTakeMic());
    // Launch recovery adopts takes it finds; a take still being written
    // must not be one of them.
    await controller.waitForPhoneTakeRecovery();
    await controller.startPhoneRecording();
    String? saved;
    await scenario(
      tester,
      'take_save',
      controller: controller,
      recordingPanel: true,
      workload: () async => saved = await controller.stopPhoneRecording(),
    );
    // A save that failed early would be fast too.
    expect(controller.library.assetForPath(saved!)?.contentHash, hasLength(64));
    await File(saved!).delete();
    controller.dispose();
  });

  testWidgets('wifi_save', (tester) async {
    const units = 1000000;
    final clock = Stopwatch()..start();
    late Duration lastUnitSent;
    late Duration saved;
    final recorder = await FakeWifiRecorder.start((socket, fileId) async {
      socket.add(FakeWifiRecorder.head(fileId, units: units));
      await socket.addStream(_recorderSlices(units));
      lastUnitSent = clock.elapsed;
      socket.add(FakeWifiRecorder.done());
    });
    final wifi = WifiExportService(
      blePackets: const Stream<DecodedPacket>.empty(),
      bleWrite: (_) async {},
      link: FakeSoftApLink(recorderPort: recorder.port),
      useSsl: false,
    );
    final controller = _controller(wifiExport: wifi);
    var paths = const <String>[];
    await scenario(
      tester,
      'wifi_save',
      controller: controller,
      workload: () async {
        paths = await wifi.transferFiles(
          endpoint: WifiEndpoint(
            ssid: 'WiFi-1761100000000',
            password: '1761100000000',
            ip: '192.0.2.1',
            port: 443,
          ),
          files: [OfflineFileEntry(fileId: 1761100001, sizeBytes: 21600)],
        );
        saved = clock.elapsed;
      },
      measured: () => {'save_ms': (saved - lastUnitSent).inMilliseconds},
    );
    // A transfer that stopped early would save fast too.
    expect(await File(paths.single).length(), units * 160);
    expect(wifi.incompletePaths, isEmpty);
    await File(paths.single).delete();
    await recorder.close();
    controller.dispose();
  });
}

/// How long a frame may be due without one being drawn before the run stops.
const _noFrameLimit = Duration(seconds: 30);

/// macOS draws nothing for a window that is not on screen (opened behind
/// another app's window, covered, hidden or minimised, or the screen is
/// locked), and every pump then waits forever. When a frame has been due for
/// [_noFrameLimit] without one being drawn, end the run through the driver
/// with the reason, so scripts/perf-check stops early and does not report it
/// as a performance failure.
Timer _stopWhenNoFrames(IntegrationTestWidgetsFlutterBinding binding) {
  var frames = 0;
  binding.addPersistentFrameCallback((_) => frames++);
  var seen = 0;
  final stalled = Stopwatch()..start();
  return Timer.periodic(const Duration(seconds: 1), (timer) {
    // A hidden window turns frames off; otherwise a pump leaves a frame
    // scheduled until one is drawn. Setting up a scenario may go a while
    // without wanting a frame at all.
    final due = !binding.framesEnabled || binding.hasScheduledFrame;
    if (frames != seen || !due) {
      seen = frames;
      stalled.reset();
      return;
    }
    if (stalled.elapsed < _noFrameLimit) return;
    timer.cancel();
    final reason =
        'no frame drawn for ${stalled.elapsed.inSeconds} s '
        '(app lifecycle: ${binding.lifecycleState?.name})';
    // ignore: avoid_print
    print('[perf] $reason');
    binding.reportData = {...?binding.reportData, 'no_frames': reason};
    // The driver waits on this and then reports the run as failed.
    if (!binding.allTestsPassed.isCompleted) {
      binding.allTestsPassed.complete(false);
    }
  });
}

RecorderController _controller({
  BleService? ble,
  AudioPlayer? player,
  PhoneRecorder? phoneRecorder,
  WifiExportService? wifiExport,
}) => RecorderController(
  ble: ble ?? _QuietBle(),
  player: player ?? _PerfPlayer(),
  loadPersistedState: false,
  playbackHistoryStore: PlaybackHistoryStore(inMemory: true),
  persistedDeviceLoader: () async => (
    bound: false,
    manuallyDisconnected: false,
    residentOffered: false,
    device: null,
    info: null,
  ),
  phoneRecorder: phoneRecorder,
  phoneRecordingEnabled: phoneRecorder != null,
  placeCapture: _NoPlace(),
  calendarMeetings: _NoCalendar(),
  wifiExport: wifiExport,
);

/// [units] slice units as the recorder streams them, one full frame at a
/// time, without holding the whole recording.
Stream<List<int>> _recorderSlices(int units) async* {
  const unitsPerFrame = 390;
  final audio = recorderAudio(0, units: unitsPerFrame);
  for (var first = 0; first < units; first += unitsPerFrame) {
    final count = math.min(unitsPerFrame, units - first);
    yield FakeWifiRecorder.slices(
      count == unitsPerFrame ? audio : audio.sublist(0, count * 160),
      sequence: first,
    );
    // The recorder runs in this isolate: let Koe receive and draw between
    // frames, as it does when they come over the air.
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _keepScrolling(ScrollController scroll) async {
  var down = true;
  while (scroll.hasClients) {
    final target = down ? scroll.position.maxScrollExtent : 0.0;
    down = !down;
    try {
      await scroll.animateTo(
        target,
        duration: const Duration(seconds: 2),
        curve: Curves.linear,
      );
    } catch (_) {
      return;
    }
  }
}

/// 40 rows that watch the controller, like the app's screens do, plus an
/// optional inline player or recording panel.
class _Workload extends StatelessWidget {
  const _Workload({
    required this.scroll,
    required this.documents,
    required this.inlinePlayer,
    required this.recordingPanel,
  });

  final ScrollController scroll;
  final String documents;
  final bool inlinePlayer;
  final bool recordingPanel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          if (inlinePlayer) InlinePlayer(path: '$documents/178.wav'),
          if (recordingPanel)
            const SizedBox(height: 420, child: PhoneRecordingPanel()),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: 200,
              itemBuilder: (context, index) =>
                  _WatcherRow(index: index, documents: documents),
            ),
          ),
        ],
      ),
    );
  }
}

class _WatcherRow extends StatelessWidget {
  const _WatcherRow({required this.index, required this.documents});

  final int index;
  final String documents;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final path = '$documents/${1783000000 + index}.wav';
    return ListTile(
      title: Text('录音 $index · ${c.isPlaying ? '播放中' : '未播放'}'),
      subtitle: Text(
        '${c.logs.length} 条日志 · ${File(path).existsSync() ? '在本机' : '原件缺失'}',
      ),
      trailing: Text('${c.files.length}'),
    );
  }
}

class _FrameRecorder {
  final _timings = <FrameTiming>[];

  void _onTimings(List<FrameTiming> timings) => _timings.addAll(timings);

  void start() => SchedulerBinding.instance.addTimingsCallback(_onTimings);

  void stop() => SchedulerBinding.instance.removeTimingsCallback(_onTimings);

  Map<String, Object?> summary() {
    double ms(Duration d) => d.inMicroseconds / 1000;
    final build = [for (final t in _timings) ms(t.buildDuration)]..sort();
    final raster = [for (final t in _timings) ms(t.rasterDuration)]..sort();
    final starts = [
      for (final t in _timings)
        t.timestampInMicroseconds(FramePhase.vsyncStart),
    ]..sort();
    var longestGap = 0.0;
    for (var i = 1; i < starts.length; i++) {
      longestGap = math.max(longestGap, (starts[i] - starts[i - 1]) / 1000);
    }
    double pct(List<double> v, double p) =>
        v.isEmpty ? 0 : v[((v.length - 1) * p).round()];
    double round(double v) => (v * 100).roundToDouble() / 100;
    return {
      'frames': _timings.length,
      'build_p90_ms': round(pct(build, 0.9)),
      'build_p99_ms': round(pct(build, 0.99)),
      'raster_p90_ms': round(pct(raster, 0.9)),
      'raster_p99_ms': round(pct(raster, 0.99)),
      'janky_frames': _timings
          .where((t) => t.totalSpan > const Duration(microseconds: 16667))
          .length,
      'longest_frame_gap_ms': round(longestGap),
    };
  }
}

class _MemorySampler {
  Timer? _timer;
  int _start = 0;
  int _peak = 0;
  int _end = 0;

  void start() {
    _start = _peak = ProcessInfo.currentRss;
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _peak = math.max(_peak, ProcessInfo.currentRss);
    });
  }

  void stop() {
    _timer?.cancel();
    _end = ProcessInfo.currentRss;
    _peak = math.max(_peak, _end);
  }

  Map<String, Object?> summary() {
    int mb(int bytes) => (bytes / (1024 * 1024)).round();
    return {
      'rss_start_mb': mb(_start),
      'rss_peak_mb': mb(_peak),
      'rss_growth_mb': mb(_peak - _start),
    };
  }
}

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getLibraryPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;
}

class _NoPlace implements PlaceCapture {
  @override
  Future<RecordingPlace?> capture() async => null;
}

/// Keeps the takes from asking for the calendar, which would put a system
/// prompt in front of the unattended run.
class _NoCalendar implements CalendarMeetings {
  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<RecordingMeeting?> meetingAt(DateTime at) async => null;
}

/// A microphone that reports the levels it is given.
class _PerfMic implements PhoneRecorder, PhoneMicLevels {
  final _levels = StreamController<double>.broadcast();

  void emit(double db) => _levels.add(db);

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<PhoneMicState> get states => const Stream.empty();

  @override
  Stream<double> levels(Duration interval) => _levels.stream;

  @override
  Future<void> start(String path) => File(path).writeAsBytes(Uint8List(44));

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() => _levels.close();
}

/// A microphone whose take is an hour of 16 kHz mono audio by the time it
/// is stopped, with the sizes left for the save to fill in as a recorder
/// cut off mid-take leaves them.
class _HourTakeMic extends _PerfMic {
  @override
  Future<void> start(String path) async {
    final header = ByteData(44);
    void tag(int at, String value) {
      for (var i = 0; i < 4; i++) {
        header.setUint8(at + i, value.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    header
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, 16000, Endian.little)
      ..setUint32(28, 32000, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little);
    tag(36, 'data');
    final second = Uint8List(32000);
    for (var i = 0; i < second.length; i++) {
      second[i] = (i * 31 + 7) & 0xFF;
    }
    final sink = File(path).openWrite()..add(header.buffer.asUint8List());
    for (var s = 0; s < 3600; s++) {
      sink.add(second);
    }
    await sink.close();
  }
}

/// Real packet decoding and logging, but never scans or connects.
class _QuietBle extends BleService {
  @override
  bool get isConnected => false;

  @override
  bool get isConnecting => false;

  @override
  Future<bool> isD3200ConnectedToSystem(String remoteId) async => false;

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 30),
  }) async {}

  @override
  Future<void> stopScan() async {}
}

class _PerfPlayer extends AudioPlayer {
  final _positions = StreamController<Duration>.broadcast();

  void emitPosition(Duration value) => _positions.add(value);

  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration?> get durationStream => const Stream.empty();

  @override
  Stream<ProcessingState> get processingStateStream => const Stream.empty();

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Duration? get duration => const Duration(hours: 1);

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async => const Duration(hours: 1);

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _positions.close();
  }
}

Uint8List _sliceFrame(int sequence) {
  final slice = Uint8List(166);
  ByteData.sublistView(slice).setUint32(0, sequence, Endian.little);
  for (var i = 4; i < slice.length; i++) {
    slice[i] = (i * 13 + sequence) & 0xFF;
  }
  return _frame(RxCmd.fileSliceId, slice);
}

Uint8List _frame(int cmdId, List<int> payload) {
  final length = 9 + payload.length + 1;
  final body = [
    0x09, 0xFF, 0x00, 0x00, 0x01, RxCmd.transportType, cmdId, //
    length & 0xFF, (length >> 8) & 0xFF,
    ...payload,
  ];
  return Uint8List.fromList([...body, ProtocolFrame.checksum(body)]);
}
