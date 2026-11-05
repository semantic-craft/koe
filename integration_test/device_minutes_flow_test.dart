import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/ble/uuids.dart';
import 'package:koe/platform/credential_store.dart';
import 'package:koe/protocol/commands.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/state/live_minutes_store.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import '../test/support/wav_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final Directory directory;
  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;
  @override
  Future<String?> getApplicationSupportPath() async => directory.path;
  @override
  Future<String?> getTemporaryPath() async => directory.path;
}

class _IdleBle extends BleService {
  @override
  Stream<DecodedPacket> get packets => const Stream.empty();
  @override
  Stream<List<ScannedDevice>> get scanResults => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Stream<String> get logs => const Stream.empty();
  @override
  bool get isConnected => false;
  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 30),
  }) async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {}
}

const _spokenChunks = <String>[
  '今天我们先核对客户资料，因为旧版本的收货地址可能有误。比如上周五发出的确认邮件里，把园区门牌号写错了。',
  '原先计划本周五提交最终核对表，现在统一改为下周一上午十点提交。另外本次更新不采用自动发布流程，全部改为人工审核后上线。',
  '至于正式上线日期目前还没有确定，需要等法务复核后再定。请大家注意，不要把暂定计划写成已经完成的工作，下周一提交前会在群里同步核对结果。',
];

Future<void> _until(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 45),
  Duration step = const Duration(milliseconds: 200),
  Future<void> Function()? onTick,
  String Function()? detail,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    if (onTick != null) await onTick();
    if (predicate()) return;
    await Future<void>.delayed(step);
  }
  fail('Timed out waiting for condition: ${detail?.call() ?? ''}');
}

Future<Map<String, dynamic>> _postDriver(
  int port,
  String path,
  Map<String, dynamic> payload,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(payload)));
    final response = await request.close().timeout(const Duration(seconds: 60));
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('Driver $path failed (${response.statusCode}): $body');
    }
    return body.isEmpty
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(body) as Map);
  } finally {
    client.close(force: true);
  }
}

Future<ScannedDevice?> _findSystemD3200() async {
  try {
    final connected = <BluetoothDevice>[
      ...FlutterBluePlus.connectedDevices,
      ...await FlutterBluePlus.systemDevices([AnkerUuids.d3200Service]),
    ];
    for (final device in connected) {
      final name = device.platformName.trim();
      return ScannedDevice(
        id: device.remoteId.str,
        name: name.isEmpty ? 'soundcore Work' : name,
        rssi: -50,
        advName: name.isEmpty ? 'soundcore Work' : name,
        serviceUuid: AnkerUuids.d3200Service.str128,
        isD3200: true,
        isBoundAdvertised: true,
      );
    }
  } catch (_) {}
  return null;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'D3200 BLE recording streams live ASR and stage summary then finalizes and survives restart',
    (tester) async {
      final oldPaths = PathProviderPlatform.instance;
      late Directory directory;
      Directory? cleanupDirectory;
      final activeControllers = <RecorderController>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(CredentialStore.channel, (call) async {
        if (call.method == 'mode') return 'isolated';
        if (call.method == 'read') return null;
        return null;
      });
      addTearDown(() async {
        for (final controller in activeControllers) {
          try {
            await controller.waitForOrganize();
            await controller.organizeStore.idle;
          } catch (_) {}
          controller.dispose();
        }
        final folder = cleanupDirectory;
        if (folder != null && await folder.exists()) {
          await folder.delete(recursive: true);
        }
        PathProviderPlatform.instance = oldPaths;
        messenger.setMockMethodCallHandler(CredentialStore.channel, null);
      });

      final driverPort =
          int.tryParse(
            Platform.environment['KOE_MINUTES_DRIVER_PORT'] ?? '',
          ) ??
          const int.fromEnvironment('KOE_MINUTES_DRIVER_PORT');
      expect(
        driverPort,
        greaterThan(0),
        reason: 'KOE_MINUTES_DRIVER_PORT is required for host speech driver',
      );

      late RecorderController restored;
      late RecordingReference reference;
      late RecordingReference crashDraftReference;
      late Map<String, dynamic> proof;

      await tester.runAsync(() async {
        var apiKey = (Platform.environment['DASHSCOPE_API_KEY'] ?? '').trim();
        var baseUrl = (Platform.environment['DASHSCOPE_HTTP_BASE_URL'] ?? '')
            .trim();
        if (apiKey.isEmpty) {
          final cfg = await _postDriver(driverPort, '/config', const {});
          apiKey = (cfg['apiKey'] as String? ?? '').trim();
          baseUrl = (cfg['baseUrl'] as String? ?? '').trim();
        }
        expect(
          apiKey.isNotEmpty,
          isTrue,
          reason: 'DASHSCOPE_API_KEY is required for device acceptance',
        );

        directory = await Directory.systemTemp.createTemp(
          'koe-device-minutes-',
        );
        cleanupDirectory = directory;
        PathProviderPlatform.instance = _Paths(directory);
        AppSettingsStore.resetForTesting();

        final ble = BleService();
        var physicalButtonObserved = false;
        var hostStopTriggered = false;
        final packetSub = ble.packets.listen((packet) {
          if (packet.cmdType == RxCmd.audioType &&
              packet.cmdId == RxCmd.audioControlId &&
              packet.payload.isNotEmpty &&
              (packet.payload[0] & 0xFF) == 0 &&
              !hostStopTriggered) {
            physicalButtonObserved = true;
          }
          if (packet.cmdType == RxCmd.transportType &&
              packet.cmdId == RxCmd.fileSliceMarkId) {
            physicalButtonObserved = true;
          }
        });

        Future<RecorderController> build({
          required BleService bleService,
        }) async {
          final qwen = QwenSttService(
            taskTimeout: const Duration(minutes: 10),
          );
          final analysisService = QwenAnalysisService(
            origin: () =>
                baseUrl.isNotEmpty ? baseUrl : QwenSttService.defaultBaseUrl,
          );
          final controller = RecorderController(
            ble: bleService,
            loadPersistedState: true,
            meetingLocalOnly: false,
            phoneRecordingEnabled: false,
            topicsEnabled: false,
            libraryDirectory: Directory('${directory.path}/imports'),
            qwenSpeech: qwen,
            analysisController: RecordingAnalysis(
              service: analysisService,
              file: File('${directory.path}/analysis.json'),
            ),
            contextAnalysisService: analysisService,
            liveMeetingStore: LiveMinutesStore(
              file: File('${directory.path}/live_minutes.json'),
            ),
          );
          activeControllers.add(controller);
          await controller.waitForOrganize();
          qwen.apiKeyOverride = apiKey;
          if (baseUrl.isNotEmpty) {
            qwen.baseUrlOverride = baseUrl;
          }
          controller.autoRealtime = false;
          controller.speechProvider = SttProvider.qwen;
          controller.analysisBackend = AnalysisBackendKind.qwen;
          controller.setMeetingLocalOnly(false);
          await controller.settingsSaved;
          return controller;
        }

        final first = await build(bleService: ble);
        await first.setAutoOrganize(true);

        if (!first.connected) {
          final systemDevice = await _findSystemD3200();
          if (systemDevice != null) {
            await first.connect(systemDevice);
          }
        }
        if (!first.connected) {
          await first.startScan();
          await _until(
            () =>
                first.connected ||
                first.devices.any((d) => d.isD3200 || d.looksLikeSoundcore),
            timeout: const Duration(seconds: 25),
            detail: () =>
                'connected=${first.connected} phase=${first.phase} ads=${first.adsSeen} err=${first.errorMessage}',
          );
          if (!first.connected) {
            final target = first.devices.firstWhere(
              (d) => d.isD3200 || d.looksLikeSoundcore,
            );
            await first.connect(target);
          }
        }

        await _until(
          () => first.connected && first.encryptReady,
          timeout: const Duration(seconds: 20),
          detail: () =>
              'connected=${first.connected} encryptReady=${first.encryptReady} err=${first.errorMessage}',
        );

        if (!first.recording) {
          await first.startRecord();
        }
        if (!first.liveMinutesEnabled || first.liveMinutes == null) {
          await first.setLiveMinutesEnabled(true);
        }

        await _until(
          () =>
              first.recording &&
              first.realtimeState.active &&
              first.realtimeState.bytesReceived > 0 &&
              first.pcmFramesDecoded > 0,
          timeout: const Duration(seconds: 25),
          detail: () =>
              'recording=${first.recording} rtActive=${first.realtimeState.active} '
              'bytes=${first.realtimeState.bytesReceived} pcm=${first.pcmFramesDecoded} '
              'status=${first.statusMessage} err=${first.errorMessage}',
        );

        await _until(
          () => first.streamingSttActive,
          timeout: const Duration(seconds: 15),
          detail: () =>
              'streamingSttActive=${first.streamingSttActive} transcriptError=${first.transcriptError}',
        );

        final liveFileId = first.realtimeState.fileId!;
        final liveSessionId = first.liveMeetingId!;
        final spokenDigests = <String>[];
        String authorizedAudioSha = '';

        try {
          final played = await _postDriver(
            driverPort,
            '/play-authorized-audio',
            const {},
          );
          authorizedAudioSha = (played['sha256'] as String? ?? '').trim();
          await Future<void>.delayed(const Duration(milliseconds: 900));
          await first.liveMinutes?.tick();
        } catch (_) {}

        for (final chunk in _spokenChunks) {
          if (!first.recording) break;
          final spoken = await _postDriver(driverPort, '/speak', {
            'text': chunk,
          });
          final digest = spoken['sha256'] as String? ?? '';
          if (digest.isNotEmpty) spokenDigests.add(digest);
          await Future<void>.delayed(const Duration(milliseconds: 900));
          await first.liveMinutes?.tick();
        }

        await _until(
          () =>
              first.transcript.trim().isNotEmpty &&
              first.liveMeetingSegments.isNotEmpty &&
              first.liveMinutes?.active != null &&
              first.liveMinutes!.active!.trim().isNotEmpty,
          timeout: const Duration(seconds: 45),
          step: const Duration(seconds: 1),
          onTick: () async {
            await first.liveMinutes?.tick();
          },
          detail: () =>
              'transcriptLen=${first.transcript.length} '
              'segments=${first.liveMeetingSegments.length} '
              'liveActive=${first.liveMinutes?.active != null} '
              'liveErr=${first.liveMinutes?.error} '
              'liveStatus=${first.liveMinutes?.requestStatus}',
        );

        final liveStageSummary = first.liveMinutes!.active!;
        final liveJournal = await LiveMinutesStore(
          file: File('${directory.path}/live_minutes.json'),
        ).read(liveSessionId);
        expect(liveJournal, isNotNull);
        expect(liveJournal!['active'], isNotEmpty);
        final peakBytesReceived = first.realtimeState.bytesReceived;
        final peakPcmFrames = first.pcmFramesDecoded;

        if (first.recording) {
          await _postDriver(driverPort, '/prompt', {
            'text': '实时阶段摘要已生成，请长按录音豆按键两秒结束录音。',
          });
          final stopDeadline = DateTime.now().add(const Duration(seconds: 22));
          while (first.recording && DateTime.now().isBefore(stopDeadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }

        if (first.recording) {
          hostStopTriggered = true;
          await first.finalizeLiveRecordingAfterHostStopForTesting();
        }

        await _until(
          () => !first.recording && !first.realtimeState.active,
          timeout: const Duration(seconds: 15),
          detail: () =>
              'recording=${first.recording} rtActive=${first.realtimeState.active}',
        );

        await _until(
          () {
            final path = first.localPathFor(liveFileId);
            return path != null &&
                path.endsWith('.wav') &&
                File(path).existsSync();
          },
          timeout: const Duration(seconds: 20),
          detail: () => 'localPath=${first.localPathFor(liveFileId)}',
        );

        final wavPath = first.localPathFor(liveFileId)!;
        reference = RecordingReference(path: wavPath, fileId: liveFileId);

        await _until(
          () {
            final stage = first.organizeStatusFor(wavPath).stage;
            return stage == OrganizeStage.done || stage == OrganizeStage.failed;
          },
          timeout: const Duration(seconds: 90),
          step: const Duration(milliseconds: 500),
          detail: () =>
              'stage=${first.organizeStatusFor(wavPath).stage} '
              'msg=${first.organizeStatusFor(wavPath).message} '
              'errors=${first.analysis.errors}',
        );

        if (first.organizeStatusFor(wavPath).stage == OrganizeStage.failed) {
          await first.retryOrganize(wavPath);
          await _until(
            () => first.organizeStatusFor(wavPath).stage == OrganizeStage.done,
            timeout: const Duration(seconds: 90),
            step: const Duration(milliseconds: 500),
            detail: () =>
                'retry stage=${first.organizeStatusFor(wavPath).stage} '
                'msg=${first.organizeStatusFor(wavPath).message}',
          );
        }

        var formalResult = first.currentMinutesFor(reference);
        expect(formalResult, isNotNull);
        expect(formalResult!.isDraft, isFalse);
        var parsedMinutes = MeetingMinutes.parse(
          formalResult.text,
          formalResult.sources.length,
          sourceTexts: formalResult.sources,
        );
        if (parsedMinutes.topics.isEmpty) {
          final currentTranscript = first.recordingView(reference).text.trim();
          await first.analysis.run(
            recording: first.analysisKey(reference),
            source: currentTranscript,
            apiKey: first.analysisApiKey,
            custom: true,
            templateId: minutesTemplateId,
            resultSlot: 'minutes',
            instruction: '$defaultMinutesPrompt\ntopics 必须至少包含 1 个按原话分章的议题。',
            validateResult: validateMinutes,
            avoidDuplicateCharges: false,
            confirmedRestart: true,
            currentSource: () => currentTranscript,
          );
          formalResult = first.currentMinutesFor(reference);
          expect(formalResult, isNotNull);
          expect(formalResult!.isDraft, isFalse);
          parsedMinutes = MeetingMinutes.parse(
            formalResult.text,
            formalResult.sources.length,
            sourceTexts: formalResult.sources,
          );
        }
        expect(parsedMinutes.schemaVersion, 2);
        expect(parsedMinutes.topics.isNotEmpty, isTrue);
        final finalTranscript = first.recordingView(reference).text.trim();
        expect(finalTranscript.isNotEmpty, isTrue);

        final deviceId = first.activeDevice?.id ?? first.lastKnownDevice?.id;
        final deviceMac =
            first.activeDevice?.macAddress ??
            first.info?.boxMac ??
            first.lastKnownDevice?.macAddress;

        await packetSub.cancel();
        await first.disconnect();

        // Also seed an unclosed crash-draft recording to verify crash recovery
        // alongside formal-minutes protection on process restart.
        final crashInput = File('${directory.path}/crash_draft_seed.wav');
        await crashInput.writeAsBytes(wavBytes(List.filled(16000, 64)));
        await first.setAutoOrganize(false);
        final crashImported = await first.importLocalAudio(crashInput.path);
        crashDraftReference = RecordingReference(
          path: crashImported.path,
          fileId: first.fileIdFromPath(crashImported.path),
        );
        await LiveMinutesStore(
          file: File('${directory.path}/live_minutes.json'),
        ).write('session:crash-device', {
          ...liveJournal,
          'id': 'session:crash-device',
          'kind': 'minutes',
          'recordingKey': 'audio:${crashImported.path}',
          'closed': false,
          'requestStatus': 'unknown',
          'error': '上次请求结果未知，未自动重发',
        });
        await LiveMinutesStore(
          file: File('${directory.path}/live_minutes.json'),
        ).write('session:stale-draft-on-formal', {
          ...liveJournal,
          'id': 'session:stale-draft-on-formal',
          'kind': 'minutes',
          'recordingKey': 'audio:$wavPath',
          'closed': false,
        });

        await first.waitForOrganize();
        await first.organizeStore.idle;
        first.dispose();
        activeControllers.remove(first);

        restored = await build(bleService: _IdleBle());

        expect(restored.recordingView(reference).text.trim(), finalTranscript);
        final restoredFormal = restored.currentMinutesFor(reference);
        expect(restoredFormal, isNotNull);
        expect(restoredFormal!.isDraft, isFalse);
        expect(restoredFormal.text, formalResult.text);
        expect(restoredFormal.fingerprint, formalResult.fingerprint);

        final crashRecovered =
            restored.analysis.results['${restored.analysisKey(crashDraftReference)}/minutes'];
        expect(crashRecovered, isNotNull);
        expect(crashRecovered!.isDraft, isTrue);
        expect(
          restored.liveMinutesNoticeFor(crashDraftReference),
          contains('未自动重发'),
        );

        final inputSha = authorizedAudioSha.isNotEmpty
            ? authorizedAudioSha
            : analysisFingerprint(spokenDigests.join(':'));
        proof = {
          'd3200_input': peakBytesReceived > 0 && peakPcmFrames > 0,
          'real_asr': finalTranscript.isNotEmpty,
          'recording_updates': liveStageSummary.isNotEmpty,
          'stop_finalization':
              !formalResult.isDraft && parsedMinutes.topics.isNotEmpty,
          'process_restart_readback':
              restoredFormal.text == formalResult.text &&
              !restoredFormal.isDraft &&
              crashRecovered.isDraft,
          'physical_button': physicalButtonObserved,
          'file_id': liveFileId,
          'bytes_received': peakBytesReceived,
          'pcm_frames_decoded': peakPcmFrames,
          'chapter_count': parsedMinutes.topics.length,
          'revision': formalResult.fingerprint,
          'input_sha256': inputSha,
          'device_id': deviceId,
          'device_mac': deviceMac,
          'asr_model': 'qwen-audio-3.1-asr-flash-streaming',
          'llm_model': formalResult.model,
        };
        await _postDriver(driverPort, '/foreground', {'pid': pid});
      });

      final screenshotKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: screenshotKey,
          child: ChangeNotifierProvider<RecorderController>.value(
            value: restored,
            child: MaterialApp(
              home: RecordingDetailScreen(reference: reference),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final analysisButton = find.byTooltip('摘要与分析');
      expect(analysisButton, findsOneWidget);
      await tester.tap(analysisButton);
      await tester.pumpAndSettle();
      final minutesTab = find.descendant(
        of: find.byType(AppBar),
        matching: find.text('结构化纪要'),
      );
      expect(minutesTab, findsOneWidget);
      await tester.tap(minutesTab);
      await tester.pumpAndSettle();
      expect(find.byType(MinutesPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            screenshotKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        expect(byteData, isNotNull);
        await _postDriver(driverPort, '/screenshot', {
          'name': 'device_minutes_reopened',
          'pngBase64': base64Encode(byteData!.buffer.asUint8List()),
        });
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      binding.reportData = {
        ...?binding.reportData,
        'device_minutes_flow': proof,
      };
    },
  );
}
