part of '../recorder_controller.dart';

/// 全天常驻 on Android: Koe associates the bound recorder through the
/// companion device manager ([RecorderPresence]). Android then starts Koe
/// when the recorder comes near, even after the user swiped Koe away or the
/// phone restarted, and lets Koe start its foreground service from behind
/// the lock screen. Koe reconnects as it does on screen, takes the new
/// recordings and transcribes them. While the recorder is away, Koe lets go:
/// no connection request, no foreground service, no notification.
///
/// Without it, Koe holds a connection request and the foreground service for
/// the recorder all along ([_RecorderDevice._awaitBoundDevice]), and all of
/// it ends when the user swipes Koe away.
///
/// Apple platforms bring the recorder back through Core Bluetooth state
/// restoration instead; there [residentSupported] stays false.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderResident on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract final BleService _ble;
  abstract bool _disposed;
  abstract bool _explicitDisconnect;
  abstract bool _systemWaitFailed;
  abstract bool bound;
  abstract bool connected;
  abstract ScannedDevice? lastKnownDevice;
  abstract AppPhase phase;
  abstract String? statusMessage;
  bool get _awaitsBoundDevice;
  Future<void> _awaitBoundDevice();
  Future<void> _persistDevice();
  void _resetBoundReconnectBackoff();
  void _scheduleBoundReconnect();
  bool get isExporting;
  bool get isWifiExportSession;
  bool get needsWifiJoin;
  Future<void> stopScan();
  // END DEPS

  /// This phone can associate devices, so Koe can stay resident.
  bool residentSupported = false;

  /// Koe has asked once whether to stay resident for the bound recorder;
  /// persisted with it.
  bool residentOffered = false;

  /// The address of the recorder Koe is associated with.
  String? _residentAddress;

  /// Whether Android last said the recorder is near. A connection counts as
  /// near until Android says otherwise.
  bool _recorderPresent = false;

  /// Koe stays resident for the bound recorder.
  bool get resident => _residentAddress != null;

  /// The recorder is bound and connected, and Koe has not asked yet whether
  /// to stay resident for it. AppShell asks, then calls
  /// [markResidentOffered].
  bool get offersResident =>
      residentSupported && !resident && !residentOffered && bound && connected;

  /// Koe is resident and Android says the recorder is away, so nothing waits
  /// for it until Android says it is near again.
  bool get _recorderAway => resident && !_recorderPresent;

  /// Reads whether Koe can stay resident and whether it does. Runs once the
  /// persisted device is read, before Koe reconnects to it. Used by other
  /// parts through their abstract declarations.
  // ignore: unused_element
  Future<void> _startResident() async {
    final presence = RecorderPresence.shared;
    if (!presence.enabled) return;
    presence.onPresence = _onRecorderPresence;
    final state = await presence.state();
    if (_disposed) return;
    residentSupported = state.supported;
    _residentAddress = state.address;
    _recorderPresent = state.present;
    await _syncResident();
  }

  /// Keeps the association in step with the bound recorder: observed while
  /// Koe reconnects to it, not after an explicit disconnect, and dropped
  /// once it is unbound or another recorder is bound.
  Future<void> _syncResident() async {
    final address = _residentAddress;
    if (address == null || _disposed) return;
    final presence = RecorderPresence.shared;
    final device = lastKnownDevice;
    if (!bound || device == null || device.id.toUpperCase() != address) {
      _residentAddress = null;
      // A recorder bound in its place is asked about afresh.
      residentOffered = false;
      unawaited(_persistDevice());
      notifyListeners();
      await presence.disassociate();
      return;
    }
    await presence.observe(!_explicitDisconnect);
  }

  /// The recorder is connected, so it is near whatever Android said last.
  // ignore: unused_element
  void _residentRecorderConnected() {
    _recorderPresent = true;
    unawaited(_syncResident());
  }

  void markResidentOffered() {
    if (residentOffered) return;
    residentOffered = true;
    unawaited(_persistDevice());
    notifyListeners();
  }

  /// Switches 全天常驻 on or off for the bound recorder. Switching on asks
  /// Android, which shows its own dialog and needs Koe on screen; returns
  /// whether Koe is resident now.
  Future<bool> setResident(bool on) async {
    if (!residentSupported || on == resident) return resident;
    final presence = RecorderPresence.shared;
    if (on) {
      final device = lastKnownDevice;
      if (!bound || device == null) return false;
      residentOffered = true;
      unawaited(_persistDevice());
      // Android's Bluetooth address, which the association matches.
      if (await presence.associate(device.id)) {
        final state = await presence.state();
        if (_disposed) return false;
        _residentAddress = state.address;
        _recorderPresent = connected || state.present;
        await _syncResident();
      }
    } else {
      _residentAddress = null;
      await presence.disassociate();
      if (_disposed) return false;
      // Koe's own connection request waits for the recorder again.
      _resetBoundReconnectBackoff();
      _scheduleBoundReconnect();
    }
    notifyListeners();
    return resident;
  }

  void _onRecorderPresence(bool near) {
    if (_disposed || near == _recorderPresent) return;
    _recorderPresent = near;
    if (!resident ||
        !bound ||
        _explicitDisconnect ||
        connected ||
        phase == AppPhase.connecting ||
        _ble.isConnecting ||
        isWifiExportSession ||
        isExporting ||
        needsWifiJoin) {
      return;
    }
    _resetBoundReconnectBackoff();
    if (near) {
      if (_awaitsBoundDevice && !_systemWaitFailed) {
        unawaited(_awaitBoundDevice());
      } else {
        _scheduleBoundReconnect();
      }
      return;
    }
    unawaited(_letRecorderGo());
  }

  /// The recorder is away: Koe stops waiting for it and lets its foreground
  /// service go, until Android says it is near again.
  Future<void> _letRecorderGo() async {
    if (phase == AppPhase.scanning) await stopScan();
    // Back already: the new wait must stay.
    if (_disposed || !_recorderAway) return;
    await _ble.withdrawWait();
    if (_disposed || !_recorderAway) return;
    statusMessage = '录音豆不在身边，回来后会自动连上';
    notifyListeners();
    await BackgroundSyncService.shared.end(BackgroundWork.recorderLink);
  }

  void _disposeResident() {
    final presence = RecorderPresence.shared;
    if (presence.onPresence == _onRecorderPresence) presence.onPresence = null;
  }
}
