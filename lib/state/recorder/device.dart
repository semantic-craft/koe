part of '../recorder_controller.dart';

/// The recorder itself: BLE scan, connect and bound-device reconnect, the
/// encrypted session, device info and battery, record start/pause and the
/// record-status packets, binding, the recording shortcut, and incoming
/// packet dispatch.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderDevice on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  Future<void> _beginNewLiveTranscriptSession();
  // ignore: unused_element_parameter
  void _bindCurrentRecording({int? fileId, String? path});
  abstract final BleService _ble;
  void _cancelStreamSttAfterPause();
  abstract final DeviceCrypto _crypto;
  _RecordingSession? get _currentRecording;
  abstract bool _disposed;
  Future<void> _enqueueDeferredRecording(_RecordingSession owner, String path);
  abstract final DeviceCopies _copies;
  void _handleFileListPage(OfflineFileList list);
  void _kickRealtimeFromFileList(OfflineFileList list);
  void _markInterruptedLiveTake();
  abstract final Future<void> _persistedDeviceLoaded;
  abstract final PersistedDeviceLoader _persistedDeviceLoader;
  // ignore: unused_field
  abstract bool _preferStreamStt;
  abstract final RealtimeBleStream _realtime;
  void _scheduleAutoTransferMissing();
  abstract final Future<void> _settingsLoaded;
  abstract bool _settingsReady;
  void _snapshotLiveText();
  List<OfflineFileEntry> _sortFilesNewestFirst(List<OfflineFileEntry> list);
  Future<void> _startCurrentRecordingTransfer(int fileId);
  abstract SttStreamSession? _sttStream;
  abstract final WifiExportService _wifi;
  Future<void> _yieldAutoTransfer();
  bool get autoTransferActive;
  bool get blocksRecordingControl;
  abstract int? downloadingFileId;
  abstract String? errorMessage;
  bool get isExporting;
  bool get isWifiExportSession;
  Future<void> listFiles();
  bool get needsWifiJoin;
  abstract int pcmFramesDecoded;
  abstract bool allDayListening;
  bool get phoneRecordingEnabled;
  bool get textCaptureActive;
  abstract String? textCaptureError;
  bool get textCaptureFromDevice;
  Future<bool> startTextCapture({bool allDay, bool fromDevice});
  Future<TextCaptureOutcome?> stopTextCapture({
    bool keepAudio,
    bool keepAllDay,
  });
  abstract int? playingFileId;
  abstract String? playingPath;
  abstract RealtimeStreamState realtimeState;
  abstract final Duration recordingShortcutScanTimeout;
  abstract String? statusMessage;
  Future<void> stopPlayback();
  bool get _recorderAway;
  void _residentRecorderConnected();
  abstract bool residentOffered;
  Future<void> _startResident();
  Future<void> _syncResident();
  // END DEPS

  static const _bleScanTimeout = Duration(seconds: 30);
  static const _boundReconnectDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  Future<void> _loadPersistedDevice() async {
    final saved = await _persistedDeviceLoader();
    if (saved.device != null || saved.bound) {
      _explicitDisconnect = saved.manuallyDisconnected;
      residentOffered = saved.residentOffered;
      lastKnownDevice = saved.device;
      lastKnownInfo = saved.info;
      if (saved.bound) bound = true;
      // Surface on Device tab even before this session connects.
      activeDevice ??= lastKnownDevice;
      notifyListeners();
    }
    // Before reconnecting, which waits for a resident recorder only while it
    // is near.
    await _startResident();
    if (!_explicitDisconnect && saved.bound && saved.device != null) {
      unawaited(_startBoundDeviceReconnect());
    }
  }

  Future<void> _startBoundDeviceReconnect() async {
    if (_explicitDisconnect ||
        connected ||
        phase == AppPhase.scanning ||
        phase == AppPhase.connecting ||
        _ble.isConnecting) {
      return;
    }
    statusMessage = '正在自动连接已绑定设备…';
    await startScan();
  }

  /// Handle the one-shot action exposed through the iOS Action Button and
  /// the Android launcher shortcut.
  ///
  /// Repeated invocations coalesce while a request is pending or sending. A
  /// request is never retained beyond its reconnect attempt, preventing a
  /// later unrelated auto-reconnect from unexpectedly starting a recording.
  ///
  /// On Android, with all-day listening switched on, the shortcut enters
  /// all-day listening from the phone instead, as 手机录音 does.
  Future<void> requestRecordingFromShortcut() async {
    shortcutNavigationRevision++;
    notifyListeners();

    if (_recordingShortcutPending || _recordingShortcutStarting) return;
    if (recording) {
      statusMessage = '录音中';
      errorMessage = null;
      notifyListeners();
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android &&
        phoneRecordingEnabled) {
      _recordingShortcutStarting = true;
      try {
        // A cold launch from the shortcut gets here before settings are read.
        if (!_settingsReady) await _settingsLoaded;
        if (allDayListening) {
          await _listenAllDayFromShortcut();
          return;
        }
      } finally {
        _recordingShortcutStarting = false;
      }
    }
    if (isWifiExportSession || isExporting) {
      _failRecordingShortcut('正在导出录音，暂时无法开始新的录音');
      return;
    }

    _recordingShortcutPending = true;
    statusMessage = connected ? '正在开始快捷录音…' : '快捷录音：正在准备连接…';
    errorMessage = null;
    notifyListeners();

    await _persistedDeviceLoaded;
    if (!_recordingShortcutPending) return;

    if (_explicitDisconnect) {
      _failRecordingShortcut('已手动断开，请先在应用中连接录音豆');
      return;
    }

    if (recording) {
      _finishRecordingShortcut();
      statusMessage = '录音中';
      notifyListeners();
      return;
    }

    if (connected && _ble.isConnected) {
      if (blocksRecordingControl) {
        _failRecordingShortcut('设备正忙，请稍后再按一次操作按钮');
        return;
      }
      await _runPendingRecordingShortcutIfReady();
      return;
    }

    if (!bound || lastKnownDevice == null) {
      _failRecordingShortcut('未找到已绑定的录音豆，请先在应用中连接设备');
      return;
    }

    statusMessage = '快捷录音：正在连接 ${lastKnownDevice!.displayName}…';
    _startRecordingShortcutScanTimeout();
    if (phase == AppPhase.connecting || _ble.isConnecting) {
      _recordingShortcutConnecting = true;
      _recordingShortcutTimer?.cancel();
      _recordingShortcutTimer = null;
    }
    notifyListeners();

    if (phase != AppPhase.scanning &&
        phase != AppPhase.connecting &&
        !_ble.isConnecting) {
      await startScan();
      if (_recordingShortcutPending &&
          !connected &&
          phase == AppPhase.idle &&
          errorMessage != null) {
        _failRecordingShortcut(errorMessage!);
      }
    }
  }

  /// The shortcut opened Koe, so the microphone service starts while Koe is
  /// on screen, as Android 14 requires.
  Future<void> _listenAllDayFromShortcut() async {
    if (textCaptureActive) return;
    textCaptureError = null;
    if (await startTextCapture(allDay: true)) return;
    // No reason given: another start is under way, such as listening that
    // resumes at launch, and it reports for itself.
    final reason = textCaptureError;
    if (reason != null) _failRecordingShortcut(reason);
  }

  void _startRecordingShortcutScanTimeout() {
    _recordingShortcutTimer?.cancel();
    _recordingShortcutTimer = Timer(recordingShortcutScanTimeout, () {
      if (!_recordingShortcutPending || _recordingShortcutConnecting) return;
      _failRecordingShortcut('未在 30 秒内找到已绑定的录音豆，请靠近设备后重试');
    });
  }

  void _finishRecordingShortcut() {
    _recordingShortcutPending = false;
    _recordingShortcutConnecting = false;
    _recordingShortcutTimer?.cancel();
    _recordingShortcutTimer = null;
  }

  void _failRecordingShortcut(String message) {
    _finishRecordingShortcut();
    statusMessage = '快捷录音未开始';
    errorMessage = message;
    recordingShortcutFailure = message;
    recordingShortcutFailureRevision++;
    notifyListeners();
  }

  /// Returns null when there was no shortcut request, true for success/no-op,
  /// and false when the BLE start command failed.
  Future<bool?> _runPendingRecordingShortcutIfReady() async {
    if (!_recordingShortcutPending || _recordingShortcutStarting) return null;
    if (recording) {
      _finishRecordingShortcut();
      statusMessage = '录音中';
      notifyListeners();
      return true;
    }
    if (!connected || !_ble.isConnected) return null;
    if (isWifiExportSession || isExporting) {
      _failRecordingShortcut('正在导出录音，暂时无法开始新的录音');
      return false;
    }
    if (blocksRecordingControl) {
      _failRecordingShortcut('设备正忙，请稍后再按一次操作按钮');
      return false;
    }

    _finishRecordingShortcut();
    _recordingShortcutStarting = true;
    try {
      final started = await _startRecordChecked();
      if (!started) _failRecordingShortcut(errorMessage ?? '录音豆没有开始录音');
      return started;
    } finally {
      _recordingShortcutStarting = false;
    }
  }

  Future<void> _tryAutoConnectBoundDevice(List<ScannedDevice> scanned) async {
    if (_explicitDisconnect ||
        !bound ||
        connected ||
        phase == AppPhase.connecting ||
        _ble.isConnecting) {
      return;
    }
    final saved = lastKnownDevice;
    if (saved == null) return;

    ScannedDevice? target;
    for (final candidate in scanned) {
      final sameId = candidate.id == saved.id;
      final sameMac =
          saved.macAddress != null &&
          candidate.macAddress != null &&
          candidate.macAddress == saved.macAddress;
      if (sameId || sameMac) {
        target = candidate;
        break;
      }
    }
    if (target == null) return;

    await connect(target);
  }

  Future<void> _persistDevice() async {
    final d = activeDevice ?? lastKnownDevice;
    if (d == null && !bound) {
      await DeviceStore.clear();
      return;
    }
    await DeviceStore.save(
      bound: bound,
      manuallyDisconnected: _explicitDisconnect,
      residentOffered: residentOffered,
      device: d,
      info: info ?? lastKnownInfo,
    );
  }

  Completer<bool>? _encryptCompleter;
  AppPhase phase = AppPhase.idle;
  bool connected = false;
  List<ScannedDevice> devices = [];
  DeviceInfoModel? info;
  List<OfflineFileEntry> files = [];
  List<String> logs = [];

  bool recording = false;
  bool bound = false;
  ScannedDevice? activeDevice;

  /// Incremented for each shortcut invocation so AppShell can select Home.
  int shortcutNavigationRevision = 0;

  /// Why the latest shortcut did not start; AppShell says it once per
  /// [recordingShortcutFailureRevision].
  String? recordingShortcutFailure;
  int recordingShortcutFailureRevision = 0;
  bool _recordingShortcutPending = false;
  bool _recordingShortcutConnecting = false;
  bool _recordingShortcutStarting = false;
  Timer? _recordingShortcutTimer;
  Timer? _scanTimeoutTimer;
  Timer? _boundReconnectTimer;
  int _boundReconnectAttempt = 0;
  bool get recordingShortcutPending => _recordingShortcutPending;

  /// Persisted user intent; only explicit connection resumes reconnection.
  bool _explicitDisconnect = false;
  bool get manuallyDisconnected => _explicitDisconnect;

  /// Survives disconnect so the Device tab can still show a known/bound unit.
  ScannedDevice? lastKnownDevice;
  DeviceInfoModel? lastKnownInfo;

  /// Multi-select for batch export.
  bool selecting = false;
  final Set<int> selectedFileIds = {};

  /// ECDH session established (needed to decrypt exports).
  bool encryptReady = false;

  int get adsSeen => _ble.adsSeen;

  Future<void> startScan() async {
    await _persistedDeviceLoaded;
    if (connected ||
        phase == AppPhase.scanning ||
        phase == AppPhase.connecting) {
      return;
    }
    _boundReconnectTimer?.cancel();
    _boundReconnectTimer = null;
    _scanTimeoutTimer?.cancel();
    errorMessage = null;
    phase = AppPhase.scanning;
    statusMessage = '正在检查蓝牙…';
    notifyListeners();
    try {
      final saved = bound && !_explicitDisconnect ? lastKnownDevice : null;
      if (saved != null && await _ble.isD3200ConnectedToSystem(saved.id)) {
        statusMessage = '正在恢复 ${saved.displayName} 的连接…';
        notifyListeners();
        await connect(saved);
        if (connected) return;

        // The restored link went stale while being adopted. Fall back to a
        // normal scan without leaving the failed direct-connect error visible.
        errorMessage = null;
        phase = AppPhase.scanning;
        statusMessage = '正在检查蓝牙…';
        notifyListeners();
      }
      await _ble.startScan(timeout: _bleScanTimeout);
      statusMessage = '正在扫描安克录音豆（D3200）…';
      notifyListeners();
      // Android pauses this scan while the screen is off; the system
      // connects the bound recorder once it is back either way. Asked after
      // the scan has settled permissions and Bluetooth, so neither prompts
      // twice.
      if (_awaitsBoundDevice) unawaited(_awaitBoundDevice());
      if (!connected && phase == AppPhase.scanning) {
        // FlutterBluePlus stops its native scan when the timeout elapses, but
        // startScan() returns as soon as scanning begins. Mirror that timeout
        // in controller state so the UI cannot remain stuck on a dead scan.
        _scanTimeoutTimer = Timer(_bleScanTimeout, () {
          if (!connected && phase == AppPhase.scanning) {
            unawaited(_finishTimedOutScan());
          }
        });
      }
    } catch (e) {
      _scanTimeoutTimer?.cancel();
      errorMessage = e.toString().replaceFirst(
        RegExp(r'^(Bad state|Exception|StateError):\s*'),
        '',
      );
      phase = AppPhase.idle;
      statusMessage = null;
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    _boundReconnectTimer?.cancel();
    _boundReconnectTimer = null;
    _scanTimeoutTimer?.cancel();
    await _ble.stopScan();
    if (!connected) phase = AppPhase.idle;
    statusMessage = devices.isEmpty && adsSeen > 0
        ? '已见 $adsSeen 条 BLE 广播，无匹配 D3200 — 请重启录音豆后重试'
        : null;
    notifyListeners();
  }

  Future<void> _finishTimedOutScan() async {
    await stopScan();
    _scheduleBoundReconnect();
  }

  bool get _canRetryBoundConnection =>
      !_explicitDisconnect &&
      bound &&
      lastKnownDevice != null &&
      !connected &&
      phase == AppPhase.idle &&
      !_ble.isConnecting &&
      !isWifiExportSession &&
      !isExporting &&
      !needsWifiJoin;

  void _scheduleBoundReconnect() {
    if (!_canRetryBoundConnection || _boundReconnectTimer != null) return;
    if (_recorderAway) {
      // Android says when it is near again (全天常驻).
      statusMessage = '录音豆不在身边，回来后会自动连上';
      notifyListeners();
      return;
    }
    if (_awaitsBoundDevice && !_systemWaitFailed) {
      // The system connects it once it is back; no more scans.
      statusMessage = '录音豆回到身边后会自动连上';
      notifyListeners();
      unawaited(_awaitBoundDevice());
      return;
    }
    final index = _boundReconnectAttempt < _boundReconnectDelays.length
        ? _boundReconnectAttempt
        : _boundReconnectDelays.length - 1;
    final delay = _boundReconnectDelays[index];
    _boundReconnectAttempt++;
    statusMessage = '未找到已绑定设备，${delay.inSeconds} 秒后自动重试…';
    notifyListeners();
    _boundReconnectTimer = Timer(delay, () {
      _boundReconnectTimer = null;
      if (_canRetryBoundConnection) {
        unawaited(startScan());
      }
    });
  }

  void _resetBoundReconnectBackoff() {
    _boundReconnectTimer?.cancel();
    _boundReconnectTimer = null;
    _boundReconnectAttempt = 0;
  }

  /// Android: the bound recorder comes back through a system connection
  /// request ([BleService.waitForDevice]) rather than through scans, which
  /// Android pauses while the screen is off.
  bool get _awaitsBoundDevice =>
      _ble.canAwaitDevice &&
      bound &&
      !_explicitDisconnect &&
      !_recorderAway &&
      lastKnownDevice != null &&
      !connected &&
      !isWifiExportSession &&
      !isExporting &&
      !needsWifiJoin;

  bool _awaitingBoundDevice = false;

  /// Set when the system request could not be made; reconnecting falls back
  /// to timed scans until the next connection.
  bool _systemWaitFailed = false;

  /// Waits for the system to connect the bound recorder, then connects it
  /// as a scan-found reconnect does (handshake, file list). The foreground
  /// service keeps Koe running meanwhile, so the link is taken while Koe is
  /// off screen; it ends with an explicit disconnect or unbind.
  Future<void> _awaitBoundDevice() async {
    if (_awaitingBoundDevice || !_awaitsBoundDevice) return;
    _awaitingBoundDevice = true;
    final saved = lastKnownDevice!;
    var up = false;
    try {
      await _beginRecorderLink();
      if (!_awaitsBoundDevice) return;
      up = await _ble.waitForDevice(saved.id);
    } catch (e) {
      logs = ['Waiting for ${saved.id} failed: $e', ...logs].take(80).toList();
      _systemWaitFailed = true;
      _scheduleBoundReconnect();
    } finally {
      _awaitingBoundDevice = false;
    }
    if (!up ||
        !_awaitsBoundDevice ||
        phase == AppPhase.connecting ||
        _ble.isConnecting) {
      return;
    }
    await connect(saved);
  }

  Future<void> connect(ScannedDevice d) async {
    await _persistedDeviceLoaded;
    // Single-flight: ignore extra taps while connecting (or BLE layer busy).
    if (phase == AppPhase.connecting || _ble.isConnecting) {
      statusMessage = '正在连接…';
      notifyListeners();
      return;
    }

    _explicitDisconnect = false;
    if (_recordingShortcutPending) {
      _recordingShortcutConnecting = true;
      _recordingShortcutTimer?.cancel();
      _recordingShortcutTimer = null;
    }

    _scanTimeoutTimer?.cancel();
    errorMessage = null;
    activeDevice = d;
    phase = AppPhase.connecting;
    statusMessage = '正在连接 ${d.displayName}…';
    connected = false;
    notifyListeners();
    // Start while the activity is visible. Android 12+ restricts launching a
    // foreground service after the app has already entered the background.
    await _beginRecorderLink();
    bool? shortcutResult;
    String? shortcutFailure;
    try {
      await _persistDevice();
      await _ble.connect(d.id, serviceUuidHint: d.serviceUuid);
      // Retry after GATT is ready in case Android initially rejected the
      // connected-device service before Bluetooth permission settled.
      await _beginRecorderLink();
      connected = true;
      _systemWaitFailed = false;
      phase = AppPhase.ready;
      statusMessage = '已连接';
      lastKnownDevice = d;
      // D3200 treats the first successful GATT connection as ownership: after
      // connecting it stops discoverable advertising to other hosts even when
      // no separate bind command was sent. Persist that observed device state
      // so only this exact recorder is eligible for automatic reconnection.
      bound = true;
      unawaited(_persistDevice());
      _residentRecorderConnected();
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await refreshInfo();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await syncTime();
      // ECDH encrypt handshake so file exports can be decrypted.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await establishEncryptSession();
      shortcutResult = await _runPendingRecordingShortcutIfReady();
      if (shortcutResult == false) shortcutFailure = errorMessage;
      _startBatteryPoll();
      // Home may already be visible before an iOS connection completes, so its
      // initial tab refresh has already returned while disconnected. Always
      // request the device inventory once the GATT session is fully ready.
      await listFiles();
      // If the bean is already recording, start BLE realtime pull automatically.
      if (recording || info?.recording == true) {
        await _maybeStartAutoRealtime(reason: 'connected');
      }
      if (shortcutResult == false) {
        statusMessage = '快捷录音未开始';
        errorMessage = shortcutFailure ?? '无法开始录音';
        notifyListeners();
      } else if (shortcutResult == true && recording) {
        statusMessage = '录音中';
        notifyListeners();
      }
    } catch (e) {
      // Prefer cleaned message from BleService / strip noisy prefixes.
      final connectionError = e.toString().replaceFirst(
        RegExp(r'^(Bad state|Exception|StateError|TimeoutException):\s*'),
        '',
      );
      errorMessage = connectionError;
      phase = AppPhase.idle;
      statusMessage = null;
      // Keep lastKnownDevice if we had one from a prior session.
      activeDevice = lastKnownDevice;
      connected = false;
      _scheduleBoundReconnect();
      // Waiting for the bound recorder keeps the service.
      if (!_ble.isConnected && !_awaitingBoundDevice) {
        await BackgroundSyncService.shared.end(BackgroundWork.recorderLink);
      }
      if (_recordingShortcutPending) {
        _failRecordingShortcut(connectionError);
      } else {
        notifyListeners();
      }
    }
  }

  /// Whether one tap can bring the bound recorder back after a disconnect,
  /// without picking it from a scan.
  bool get canReconnectBoundDevice =>
      !connected && bound && lastKnownDevice != null;

  /// Reconnects the bound recorder, for example after it was handed to the
  /// Mac and back. Clears a manual disconnect, so automatic reconnection
  /// resumes too.
  Future<void> reconnectBoundDevice() async {
    await _persistedDeviceLoaded;
    if (!canReconnectBoundDevice) return;
    _explicitDisconnect = false;
    _resetBoundReconnectBackoff();
    unawaited(_persistDevice());
    unawaited(_syncResident());
    await startScan();
  }

  /// Leaves the recorder bound but lets it go, so another device (the Mac
  /// or the phone) can connect; nothing reconnects until asked.
  Future<void> disconnect() async {
    await _persistedDeviceLoaded;
    _explicitDisconnect = true;
    await _persistDevice();
    // Android need not start Koe for it now.
    unawaited(_syncResident());
    _resetBoundReconnectBackoff();
    _scanTimeoutTimer?.cancel();
    _postBindFileRefreshTimer?.cancel();
    _stopBatteryPoll();
    await _ble.stopScan();
    await _wifi.cancel();
    await stopPlayback();
    if (info != null) lastKnownInfo = info;
    if (activeDevice != null) lastKnownDevice = activeDevice;
    _markInterruptedLiveTake();
    await _ble.disconnect();
    // Keep lastKnownDevice / bound for offline Device tab; clear live session only.
    activeDevice = lastKnownDevice;
    info = null;
    files = [];
    selectedFileIds.clear();
    selecting = false;
    recording = false;
    _snapshotLiveText();
    _currentRecording?.active = false;
    _recordWireStatus = 0;
    encryptReady = false;
    _crypto.resetSession();
    phase = AppPhase.idle;
    statusMessage = null;
    connected = false;
    await BackgroundSyncService.shared.end(BackgroundWork.recorderLink);
    unawaited(_persistDevice());
    notifyListeners();
  }

  /// The notification's line while Koe holds the link with nothing to move.
  String get _recorderLinkText => connected
      ? 'Koe 已连接录音豆'
      : phase == AppPhase.connecting
      ? 'Koe 正在连接录音豆'
      : 'Koe 正在等录音豆回来';

  /// Whether recordings are moving off the recorder: retrieved over
  /// Bluetooth, automatically or on request, exported over Wi‑Fi, or a take
  /// streamed live.
  bool get _movingRecordings =>
      autoTransferActive ||
      downloadingFileId != null ||
      isWifiExportSession ||
      isExporting ||
      realtimeState.active;

  bool _recorderSyncBegun = false;
  String? _recorderLinkTextShown;

  /// Holds the link to the recorder in the foreground service, without
  /// keeping the phone awake.
  Future<void> _beginRecorderLink() {
    final text = _recorderLinkTextShown = _recorderLinkText;
    return BackgroundSyncService.shared.begin(
      BackgroundWork.recorderLink,
      text: text,
    );
  }

  /// Keeps the foreground service in step with the recorder after every
  /// change the controller announces: the phone is kept awake only while
  /// recordings move (#438), and the link's line follows the recorder
  /// (connecting, connected, awaited). Derived from the state rather than
  /// begun and ended at each transfer, so a download that takes over from
  /// the automatic retrieval keeps the phone awake. Only changes are passed
  /// on: while Android withholds a type, every call would ask it again.
  void _syncRecorderWork() {
    final service = BackgroundSyncService.shared;
    final moving = _movingRecordings;
    if (moving != _recorderSyncBegun) {
      _recorderSyncBegun = moving;
      unawaited(
        moving
            ? service.begin(BackgroundWork.recorderSync)
            : service.end(BackgroundWork.recorderSync),
      );
    }
    final text = _recorderLinkText;
    if (text != _recorderLinkTextShown) {
      _recorderLinkTextShown = text;
      unawaited(service.updateText(BackgroundWork.recorderLink, text));
    }
  }

  /// Display name for Device tab (live or last known).
  String get displayDeviceName =>
      activeDevice?.displayName ?? lastKnownDevice?.displayName ?? '设备';

  /// Snapshot used when offline.
  ScannedDevice? get displayDevice => activeDevice ?? lastKnownDevice;

  /// BLE `0x2E/0x01` ECDH handshake (Feishu `notifyEncryptFileData`).
  Future<bool> establishEncryptSession({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (!_ble.isConnected) return false;
    if (encryptReady && _crypto.hasSession) return true;

    final mac =
        activeDevice?.macAddress ??
        info?.boxMac ??
        activeDevice?.id ??
        'unknown';
    statusMessage = '正在准备设备…';
    phase = AppPhase.busy;
    notifyListeners();

    _encryptCompleter = Completer<bool>();
    try {
      final pub = _crypto.ensureKeyPair();
      // Feishu stores MAC on EncryptMessageDispatch for session storage key.
      logs = [
        'ENCRYPT TX pub ${pub.length}B mac=$mac',
        ...logs,
      ].take(80).toList();
      await _ble.writeCommand(DeviceCommands.notifyEncryptPublicKey(pub));
      final ok = await _encryptCompleter!.future.timeout(timeout);
      encryptReady = ok;
      statusMessage = ok ? '设备已就绪' : '设备准备失败，请重新连接';
      phase = AppPhase.ready;
      notifyListeners();
      return ok;
    } on TimeoutException {
      encryptReady = false;
      errorMessage = '设备准备超时，请重新连接';
      statusMessage = '设备准备超时，请重新连接';
      phase = AppPhase.ready;
      notifyListeners();
      return false;
    } catch (e) {
      encryptReady = false;
      errorMessage = e.toString();
      phase = AppPhase.ready;
      notifyListeners();
      return false;
    } finally {
      _encryptCompleter = null;
    }
  }

  Future<bool> _sendChecked(List<int> frame, {String? label}) async {
    if (!_ble.isConnected) {
      errorMessage = '未连接';
      notifyListeners();
      return false;
    }
    phase = AppPhase.busy;
    if (label != null) statusMessage = label;
    notifyListeners();
    try {
      await _ble.writeCommand(frame);
      // A command just went through — any earlier error (e.g. a stale
      // "未连接" from a command that raced a disconnect) is no longer true.
      errorMessage = null;
      return true;
    } catch (e) {
      errorMessage = e.toString();
      return false;
    } finally {
      phase = connected ? AppPhase.ready : AppPhase.idle;
      notifyListeners();
    }
  }

  Future<void> _send(List<int> frame, {String? label}) async {
    await _sendChecked(frame, label: label);
  }

  Future<void> refreshInfo({bool silent = false}) =>
      _send(DeviceCommands.getDeviceInfo(), label: silent ? null : '正在获取设备信息…');

  Timer? _batteryPollTimer;

  /// Poll device info while connected so mic/case battery stay fresh.
  /// Live 0x01/0x03 pushes are also handled, but many firmwares only update on query.
  void _startBatteryPoll() {
    _batteryPollTimer?.cancel();
    if (!connected) return;
    _batteryPollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!connected || !_ble.isConnected) return;
      if (phase == AppPhase.busy || phase == AppPhase.connecting) return;
      if (isWifiExportSession || isExporting) return;
      unawaited(refreshInfo(silent: true));
    });
  }

  void _stopBatteryPoll() {
    _batteryPollTimer?.cancel();
    _batteryPollTimer = null;
  }

  /// Called when Device tab is shown — force a fresh battery snapshot.
  Future<void> refreshInfoOnDeviceTabEnter() async {
    if (!connected || !_ble.isConnected) return;
    if (phase == AppPhase.busy || phase == AppPhase.connecting) return;
    if (isWifiExportSession || isExporting) return;
    await refreshInfo(silent: true);
  }

  Future<void> syncTime() => _send(DeviceCommands.syncTime(), label: '正在同步时钟…');

  Future<void> startRecord() async {
    await _startRecordChecked();
  }

  Future<bool> _startRecordChecked() async {
    await _settingsLoaded;
    if (_disposed) return false;
    await _yieldAutoTransfer();
    final sent = await _sendChecked(
      DeviceCommands.startRecord(),
      label: '正在开始录音…',
    );
    if (!sent) return false;
    // Optimistic; device will confirm via 0x18/0x82 or 1A06.
    _applyRecordStatus(1, source: 'app_start');
    return true;
  }

  Future<void> pauseRecord() async {
    final sent = await _sendChecked(
      DeviceCommands.pauseRecord(),
      label: '正在暂停录音…',
    );
    if (!sent) return;
    // Optimistic; device will confirm via 0x18/0x82 status 0/2.
    _applyRecordStatus(2, source: 'app_pause');
  }

  /// Feishu `onAudioStatusChanged` / device-info recording bit:
  /// status `0` stop, `1` recording, `2` pause.
  /// Last wire status: 0=stop, 1=recording, 2=pause (for resume vs new take).
  int _recordWireStatus = 0;
  bool get recordingPaused =>
      _recordWireStatus == 2 && _currentRecording != null;

  void _applyRecordStatus(
    int status, {
    int? fileId,
    int? durationSec,
    String source = '',
  }) {
    if (!_settingsReady) {
      unawaited(
        _settingsLoaded.then((_) {
          if (!_disposed) {
            _applyRecordStatus(
              status,
              fileId: fileId,
              durationSec: durationSec,
              source: source,
            );
          }
        }),
      );
      return;
    }
    final wasRecording = recording;
    final prevWire = _recordWireStatus;
    final active = status == 1;
    final retargetFile = active && fileId != null && fileId > 0;
    // Skip no-ops; still apply when a new live file id must retarget realtime.
    if (recording == active && !retargetFile && status == prevWire) {
      return;
    }
    recording = active;
    _recordWireStatus = status;
    // Keep DeviceInfoModel bit aligned so later device-info packets don't re-stick UI.
    if (info != null && info!.recordingStatus != status) {
      info = info!.copyWith(recordingStatus: status);
      lastKnownInfo = info;
    }

    if (active) {
      // Continue the existing take regardless of its speech provider. A
      // different device file id is an explicit new take, never a continuation.
      final current = _currentRecording;
      final differentFile =
          fileId != null &&
          current?.fileId != null &&
          current!.fileId != fileId;
      final resuming = prevWire == 2 && current != null && !differentFile;
      if (current == null ||
          differentFile ||
          (prevWire == 0 && !wasRecording) ||
          (source == 'app_start' && !wasRecording && !resuming)) {
        unawaited(_beginNewLiveTranscriptSession());
      }
      if (resuming) {
        // A paused take's settled copy may be playing (#252). Continuing
        // appends to the device file and the next pause rewrites the copy, so
        // playback of it stops here; the new pause plays the longer copy.
        final path = current.path;
        if ((path != null && playingPath == path) ||
            (current.fileId != null && playingFileId == current.fileId)) {
          unawaited(stopPlayback());
        }
      }
      _bindCurrentRecording(fileId: fileId);
      if (allDayListening && !textCaptureActive) {
        // The recorder's key starts all-day listening when it is on (#319).
        unawaited(startTextCapture(allDay: true, fromDevice: true));
      }
      _currentRecording?.active = true;
      _currentRecording?.paused = false;
      // New take: re-enable PCM stream STT (may have fallen back last session).
      _preferStreamStt = true;
      pcmFramesDecoded = 0;
      statusMessage = fileId != null && fileId > 0 ? '录音中 · 文件 $fileId' : '录音中';
      // The current recording always streams live over BLE — transcription
      // depends on it. `autoRealtime` ("自动传输") only gates catching up on
      // already-finished, un-exported recordings (see _autoTransferMissingFiles).
      if (!isWifiExportSession) {
        if (fileId != null && fileId > 0) {
          unawaited(_startCurrentRecordingTransfer(fileId));
        } else if (resuming && current.fileId != null) {
          unawaited(_startCurrentRecordingTransfer(current.fileId!));
        } else {
          unawaited(
            _maybeStartAutoRealtime(
              reason: source.isEmpty ? 'record_status' : source,
            ),
          );
        }
      }
    } else {
      _snapshotLiveText();
      _currentRecording?.active = false;
      _currentRecording?.paused = status == 2;
      if (status == 0 && textCaptureFromDevice) {
        unawaited(stopTextCapture());
      }
      if (status == 0) {
        _currentRecording?.ended = true;
        // The recorder closed its file: it can be pulled now (#253).
        _copies.recorderStopped();
      }
      _currentRecording?.finalizing =
          status == 0 && (realtimeState.active || _sttStream != null);
      final label = status == 2 ? '已暂停' : '已停止录音';
      if (durationSec != null && durationSec > 0) {
        statusMessage = '$label（${durationSec}s）';
      } else {
        statusMessage = label;
      }
      if (wasRecording || realtimeState.active) {
        _realtime.onRecordingStopped();
      }
      if (status == 2) {
        // Pause is a hard boundary: disconnect the speech stream immediately and reject
        // queued callbacks or a batch fallback from the paused take.
        _cancelStreamSttAfterPause();
      } else {
        // A full stop may finish gracefully while realtime audio settles.
        try {
          _sttStream?.finalizeUtterance();
        } catch (_) {}
      }
      if (status == 0 && !realtimeState.active) {
        final owner = _currentRecording;
        if (owner?.path != null) {
          unawaited(_enqueueDeferredRecording(owner!, owner.path!));
        }
      }
      // Refresh inventory after hardware/app stop so Files tab shows the clip.
      if (status == 0 && connected) {
        unawaited(listFiles());
      }
    }
    debugPrint(
      '[Record] status=$status active=$active src=$source '
      'fileId=$fileId was=$wasRecording',
    );
    notifyListeners();
  }

  /// Resolve current recording file id and start BLE realtime stream.
  /// Not gated by `autoRealtime` — the current recording always streams live
  /// so transcription keeps working regardless of the backlog-transfer setting.
  Future<void> _maybeStartAutoRealtime({required String reason}) async {
    if (!connected || !_ble.isConnected) return;
    if (isWifiExportSession) return;
    final recordingNow = recording || info?.recording == true;
    if (recordingNow) await _yieldAutoTransfer();

    if (!encryptReady) {
      await establishEncryptSession();
    }

    // Prefer list-with-end-time: includes currentTransportTimestamp.
    try {
      await _ble.writeCommand(DeviceCommands.listFilesWithEndTime());
    } catch (_) {
      try {
        await _ble.writeCommand(DeviceCommands.listFiles());
      } catch (e) {
        debugPrint('[Realtime] listFiles failed: $e');
      }
    }
    // Packet handler will call _kickRealtimeFromFileList when list arrives.
    statusMessage = recordingNow ? '实时传输：等待当前录音文件…' : '正在检查未导出录音…';
    notifyListeners();
    debugPrint('[Realtime] arm auto stream ($reason)');
  }

  /// Last bind/unbind we sent: true=bind, false=unbind, null=unknown.
  /// Feishu uses the same RX id (0x87) for both; we need this to interpret ACKs.
  bool? _pendingBindRequest;
  Timer? _postBindFileRefreshTimer;

  void _schedulePostBindFileRefresh() {
    _postBindFileRefreshTimer?.cancel();
    _postBindFileRefreshTimer = Timer(const Duration(milliseconds: 700), () {
      if (!connected || !bound || isExporting || needsWifiJoin) return;
      unawaited(listFiles());
    });
  }

  Future<void> bindDevice() async {
    _pendingBindRequest = true;
    await _send(DeviceCommands.bind(), label: '正在绑定…');
  }

  /// Unbind with the stock Feishu payload. This preserves recordings and
  /// disconnects BLE after a successful ACK.
  Future<void> unbindDevice() async {
    _postBindFileRefreshTimer?.cancel();
    _pendingBindRequest = false;
    await _send(DeviceCommands.unbind(), label: '正在解绑…');
  }

  Future<void> resetDevice() =>
      _send(DeviceCommands.resetDevice(), label: '正在恢复出厂…');

  Future<void> setFindMy(bool on) =>
      _send(DeviceCommands.setFindMy(on), label: on ? '正在开启查找…' : '正在关闭查找…');

  void _onPacket(DecodedPacket p) {
    // Audio slices arrive hundreds of times a second during retrieval and
    // live recording. Their consumers (file pull, realtime stream) listen to
    // the packet stream themselves and throttle progress, so they must not
    // rebuild every controller listener here.
    if (BleService.isAudioSlice(p)) return;
    // Device info family (type 0x01)
    if (p.cmdType == RxCmd.deviceInfoType) {
      if (p.cmdId == RxCmd.deviceInfoId) {
        info = DeviceInfoModel.parsePacket(p.raw);
        lastKnownInfo = info;
        if (activeDevice != null) lastKnownDevice = activeDevice;
        unawaited(_persistDevice());
        statusMessage =
            '麦克风 ${info?.battery ?? "—"}% · 充电盒 ${info?.boxBattery ?? "—"}%';
        final hex = info?.rawHex ?? '';
        if (hex.isNotEmpty) {
          logs = [
            'DEVINFO ${hex.length > 120 ? '${hex.substring(0, 120)}…' : hex}',
            ...logs,
          ].take(80).toList();
        }
      } else if (p.cmdId == RxCmd.batteryId && p.payload.length >= 2) {
        // Convert D3200's 0–9 battery buckets to display percentages.
        final micRaw = p.payload[0] & 0xFF;
        final boxRaw = p.payload[1] & 0xFF;
        final mic = DeviceInfoModel.batteryRemaining(micRaw) ?? 0;
        final box = DeviceInfoModel.batteryRemaining(boxRaw) ?? 0;
        info = (info ?? DeviceInfoModel()).copyWith(
          battery: mic,
          boxBattery: box,
        );
        lastKnownInfo = info;
        statusMessage = '麦克风 $mic% · 充电盒 $box%';
        logs = [
          'BATT mic=$mic% (raw $micRaw) box=$box% (raw $boxRaw)',
          ...logs,
        ].take(80).toList();
        debugPrint('[Battery] mic=$mic% raw=$micRaw box=$box% raw=$boxRaw');
      } else if (p.cmdId == RxCmd.chargingId && p.payload.length >= 2) {
        final micChg = (p.payload[0] & 0xFF) == 1;
        final boxChg = (p.payload[1] & 0xFF) == 1;
        info = (info ?? DeviceInfoModel()).copyWith(
          charging: micChg,
          boxCharging: boxChg,
        );
        lastKnownInfo = info;
        statusMessage = micChg || boxChg ? '充电中…' : '未充电';
        // Charging transitions often don't include % — refresh full device info.
        unawaited(
          Future<void>.delayed(
            const Duration(milliseconds: 400),
            () => refreshInfo(silent: true),
          ),
        );
      } else if (p.cmdId == RxCmd.resetId) {
        statusMessage = p.isSuccess ? '设备已重置' : '重置失败';
      } else if (p.cmdId == RxCmd.syncTimeId) {
        statusMessage = p.isSuccess ? '时钟已同步' : '时钟同步失败';
      }
    }

    // File list (newest first — fileId is a unix timestamp for D3200).
    if (p.cmdType == RxCmd.transportType && p.cmdId == RxCmd.fileListId) {
      final list = OfflineFileList.parse(p.payload);
      files = _sortFilesNewestFirst(list.files);
      statusMessage = '${files.length} 条录音';
      _kickRealtimeFromFileList(list);
      _scheduleAutoTransferMissing();
    }
    if (p.cmdType == RxCmd.transportTypeAlt && p.cmdId == RxCmd.fileListId) {
      final list = OfflineFileList.parse(p.payload, withEndTime: true);
      _handleFileListPage(list);
    }

    // 1A06 — new file while recording (Feishu: always status=recording + fileId LE @payload[0]).
    if (p.cmdType == RxCmd.transportType && p.cmdId == RxCmd.recordStatusId) {
      if (p.payload.length >= 4) {
        final fileId = readU32Le(p.payload, 0);
        if (fileId > 0) {
          _applyRecordStatus(1, fileId: fileId, source: '1A06');
        }
      }
    }

    // Delete
    if (p.cmdType == RxCmd.transportType && p.cmdId == RxCmd.deleteId) {
      statusMessage = p.isSuccess ? '文件已删除' : '删除失败';
      if (p.isSuccess) {
        listFiles();
      }
    }

    // 0x18/0x82 — Feishu onReceiveAudioStatusChanged (not cmdId 6 path):
    // payload[0]: 0=stop, 1=resume/record, 2=pause; stop may include duration u32 @1.
    if (p.cmdType == RxCmd.audioType && p.cmdId == RxCmd.audioControlId) {
      if (p.payload.isNotEmpty) {
        final status = p.payload[0] & 0xFF;
        int? durationSec;
        if (status == 0 && p.payload.length >= 5) {
          durationSec = readU32Le(p.payload, 1);
        }
        // Only apply known statuses; ignore empty ACKs without a status byte meaning.
        if (status == 0 || status == 1 || status == 2) {
          _applyRecordStatus(
            status,
            durationSec: durationSec,
            source: '0x18/0x82',
          );
        }
      }
    }

    // Preserve device-info stopped/recording/paused states independently.
    // Always sync UI so hardware mic-off clears the sticky 「录音中」 pill.
    if (p.cmdType == RxCmd.deviceInfoType && p.cmdId == RxCmd.deviceInfoId) {
      final deviceStatus = info?.recordingStatus ?? 0;
      final deviceRecording = deviceStatus == 1;
      if (deviceStatus != _recordWireStatus && deviceStatus <= 2) {
        _applyRecordStatus(deviceStatus, source: 'device_info');
      } else if (deviceRecording &&
          !realtimeState.active &&
          !isWifiExportSession) {
        unawaited(_maybeStartAutoRealtime(reason: 'device_info_recording'));
      }
    }

    // Binding — Feishu BindingMessageDispatch:
    //  0x87 = bind/unbind command result (successFlag low nibble of status)
    //  0x88 = device confirm after bind (not used for unbind)
    if (p.cmdType == RxCmd.bindType) {
      if (p.cmdId == RxCmd.bindResultId) {
        final ok = p.isSuccess;
        if (_pendingBindRequest == false) {
          // Unbind ACK
          if (ok) {
            bound = false;
            // Binding it again asks afresh.
            residentOffered = false;
            statusMessage = '已解绑（可重新扫描连接）';
            unawaited(_persistDevice());
            unawaited(_syncResident());
            // Match Feishu: drop link after successful unbind.
            unawaited(
              Future<void>.delayed(
                const Duration(milliseconds: 400),
                () => disconnect(),
              ),
            );
          } else {
            statusMessage = '解绑失败';
            errorMessage = '解绑失败，请重新连接后重试';
          }
        } else {
          // Bind ACK (or unknown — treat as bind)
          if (ok) {
            bound = true;
            if (activeDevice != null) lastKnownDevice = activeDevice;
            unawaited(_persistDevice());
            statusMessage = '正在绑定…';
            _schedulePostBindFileRefresh();
          } else {
            statusMessage = '绑定失败';
            errorMessage = '绑定失败，请重新连接后重试';
          }
        }
      } else if (p.cmdId == RxCmd.bindConfirmId) {
        if (p.isSuccess) {
          bound = true;
          if (activeDevice != null) lastKnownDevice = activeDevice;
          unawaited(_persistDevice());
          statusMessage = '已绑定';
          _schedulePostBindFileRefresh();
        } else {
          statusMessage = '绑定确认失败';
          errorMessage = '绑定失败，请重新连接后重试';
        }
      }
    }

    // Encrypt handshake RX (type 0x2E id 0x01)
    if (p.cmdType == RxCmd.encryptType && p.cmdId == RxCmd.encryptHandshakeId) {
      _onEncryptResponse(p);
    }

    notifyListeners();
  }

  void _onEncryptResponse(DecodedPacket p) {
    // Feishu EncryptMessageDispatch: need full frame ≥ 106
    // device pubkey @9 (65B), shared @74 (32B)
    final raw = p.raw;
    logs = [
      'ENCRYPT RX ok=${p.isSuccess} len=${raw.length}',
      ...logs,
    ].take(80).toList();
    if (raw.length < 106) {
      if (!(_encryptCompleter?.isCompleted ?? true)) {
        _encryptCompleter!.complete(false);
      }
      return;
    }
    final devPub = Uint8List.fromList(raw.sublist(9, 74));
    final devShared = Uint8List.fromList(raw.sublist(74, 106));
    final ok = _crypto.completeHandshake(
      devicePublicKey: devPub,
      deviceSharedKey: devShared,
    );
    encryptReady = ok;
    if (!(_encryptCompleter?.isCompleted ?? true)) {
      _encryptCompleter!.complete(ok);
    }
  }
}
