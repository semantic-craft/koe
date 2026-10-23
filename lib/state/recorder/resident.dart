part of '../recorder_controller.dart';

/// 全天常驻 on Android: Koe associates the bound recorder through the
/// companion device manager and watches for it with a Bluetooth scan
/// Android runs for Koe ([RecorderPresence]). Android starts Koe when the
/// scan sees the recorder, even after the user swiped Koe away or the phone
/// restarted, and the association lets Koe start its foreground service from
/// behind the lock screen. Koe reconnects as it does on screen, takes the
/// new recordings and transcribes them. While the recorder is away, Koe lets
/// go: no connection request, no foreground service, no notification.
///
/// The recorder's Bluetooth address changes, at least with every Wi‑Fi
/// export, so Koe knows it by its classic address, which its advertisement
/// carries; the scan says where it advertises now. The recorder also stops
/// advertising while connected, so the scan loses it then: a link that drops
/// while the scan has not seen the recorder since is away, and the scan sees
/// it again within seconds if it is near.
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
  abstract ScannedDevice? activeDevice;
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

  /// Koe is associated with the bound recorder.
  bool _associated = false;

  /// The classic address of the recorder Koe watches for.
  String? _residentMac;

  /// Whether Android's scan sees the recorder now.
  bool _recorderPresent = false;

  /// Koe stays resident for the bound recorder.
  bool get resident => _associated;

  /// The recorder is bound and connected, and Koe has not asked yet whether
  /// to stay resident for it. AppShell asks, then calls
  /// [markResidentOffered].
  bool get offersResident =>
      residentSupported && !resident && !residentOffered && bound && connected;

  /// Koe is resident and the scan does not see the recorder, so nothing
  /// waits for it until the scan sees it again.
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
    _associated = state.associated;
    _residentMac = state.mac;
    _recorderPresent = state.present;
    _recorderSeenAt(state.address);
    await _syncResident();
  }

  /// Keeps the association in step with the bound recorder: watched for
  /// while Koe reconnects to it, not after an explicit disconnect, and
  /// dropped once it is unbound or a recorder with another classic address
  /// is bound.
  Future<void> _syncResident() async {
    if (!_associated || _disposed) return;
    final presence = RecorderPresence.shared;
    final device = lastKnownDevice;
    final mac = device?.macAddress;
    if (!bound ||
        device == null ||
        (_residentMac != null && mac != null && mac != _residentMac)) {
      _associated = false;
      _residentMac = null;
      // A recorder bound in its place is asked about afresh.
      residentOffered = false;
      unawaited(_persistDevice());
      notifyListeners();
      await presence.disassociate();
      return;
    }
    // Associations from before Koe watched by the classic address go on
    // with the bound recorder's.
    _residentMac ??= mac;
    await presence.observe(!_explicitDisconnect, _residentMac);
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
        if (_disposed) return false;
        _associated = true;
        _residentMac = device.macAddress;
        await _syncResident();
      }
    } else {
      _associated = false;
      _residentMac = null;
      await presence.disassociate();
      if (_disposed) return false;
      // Koe's own connection request waits for the recorder again.
      _resetBoundReconnectBackoff();
      _scheduleBoundReconnect();
    }
    notifyListeners();
    return resident;
  }

  void _onRecorderPresence(bool near, String? address) {
    if (_disposed) return;
    if (near) _recorderSeenAt(address);
    if (near == _recorderPresent) return;
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

  /// The scan sees the bound recorder at the Bluetooth [address]: Koe
  /// connects it there from now on.
  void _recorderSeenAt(String? address) {
    final device = lastKnownDevice;
    if (address == null || device == null || device.id == address) return;
    lastKnownDevice = device.withId(address);
    if (!connected) activeDevice = lastKnownDevice;
    unawaited(_persistDevice());
  }

  /// The recorder is away: Koe stops waiting for it and lets its foreground
  /// service go, until the scan sees it again.
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
