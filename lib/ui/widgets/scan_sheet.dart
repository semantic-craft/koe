import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../protocol/models.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import 'connect_onboarding.dart';
import 'widgets.dart';

/// Feishu-style connect sheet: scan nearby D3200 devices and let the user pick
/// one. Persisted bound devices may still reconnect through the controller.
Future<void> showScanDevicesSheet(BuildContext context) {
  final c = context.read<RecorderController>();
  final tokens = KoeTokens.of(context);
  if (c.phase != AppPhase.scanning && c.phase != AppPhase.connecting) {
    unawaited(c.startScan());
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: tokens.bgCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.xl)),
    ),
    builder: (ctx) => const ScanDevicesSheet(),
  );
}

class ScanDevicesSheet extends StatefulWidget {
  const ScanDevicesSheet({super.key});

  @override
  State<ScanDevicesSheet> createState() => _ScanDevicesSheetState();
}

class _ScanDevicesSheetState extends State<ScanDevicesSheet> {
  String? _connectingId;

  /// After GATT success, show Feishu success + tips carousel.
  bool _showOnboarding = false;

  // A previously bound device should just reconnect — only an unrecognized
  // device needs the user to pick it and go through bind onboarding.
  bool _autoConnectTried = false;

  @override
  void initState() {
    super.initState();
    // Retry scan if list stays empty (device may only advertise after case button).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = context.read<RecorderController>();
      if (c.phase != AppPhase.scanning && c.phase != AppPhase.connecting) {
        unawaited(c.startScan());
      }
    });
  }

  void _enterOnboarding() {
    // Pull a fresh battery snapshot for the success screen.
    final c = context.read<RecorderController>();
    unawaited(c.refreshInfo(silent: true));
    setState(() => _showOnboarding = true);
  }

  bool _isBoundMatch(RecorderController c, ScannedDevice d) {
    if (d.isBoundAdvertised) return true;
    if (!c.bound) return false;
    final saved = c.lastKnownDevice;
    if (saved == null) return false;
    if (d.id == saved.id) return true;
    return saved.macAddress != null && d.macAddress == saved.macAddress;
  }

  Future<void> _connectDevice(ScannedDevice d) async {
    final c = context.read<RecorderController>();
    _connectingId = d.id;
    setState(() {});
    await c.connect(d);
    if (!mounted) return;
    if (c.connected) {
      _enterOnboarding();
    } else {
      _connectingId = null;
      setState(() {});
    }
  }

  void _maybeAutoConnectBound(RecorderController c) {
    if (_autoConnectTried || _showOnboarding) return;
    if (c.connected || c.phase == AppPhase.connecting) return;
    for (final d in c.devices) {
      if (_isBoundMatch(c, d)) {
        _autoConnectTried = true;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => unawaited(_connectDevice(d)),
        );
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final tokens = KoeTokens.of(context);
    final scanning = c.phase == AppPhase.scanning;
    final connecting = c.phase == AppPhase.connecting;
    final height = MediaQuery.sizeOf(context).height * 0.82;

    final showDeviceList = c.devices.isNotEmpty || connecting;
    _maybeAutoConnectBound(c);

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: tokens.border,
                borderRadius: BorderRadius.circular(AppRadii.pill),
              ),
            ),
          ),
          if (!_showOnboarding) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Text(
              '扫描设备',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: tokens.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: _showOnboarding
                ? ConnectOnboarding(
                    onDone: () {
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    onClose: () {
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  )
                : showDeviceList
                ? _FoundDevicesPanel(
                    devices: c.devices,
                    connecting: connecting,
                    connectingId: _connectingId ?? c.activeDevice?.id,
                    busy: connecting || c.phase == AppPhase.busy,
                    scanning: scanning,
                    error: c.errorMessage,
                    onRescan: () {
                      _connectingId = null;
                      unawaited(c.startScan());
                    },
                    onTapDevice: _connectDevice,
                  )
                : _ConnectGuidePanel(
                    scanning: scanning,
                    connecting: connecting,
                    adsSeen: c.adsSeen,
                    error: c.errorMessage,
                    onRescan: () => unawaited(c.startScan()),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Feishu-style guide: seat mic in case, short-press bottom button.
class _ConnectGuidePanel extends StatefulWidget {
  const _ConnectGuidePanel({
    required this.scanning,
    required this.connecting,
    required this.adsSeen,
    required this.onRescan,
    this.error,
  });

  final bool scanning;
  final bool connecting;
  final int adsSeen;
  final VoidCallback onRescan;
  final String? error;

  @override
  State<_ConnectGuidePanel> createState() => _ConnectGuidePanelState();
}

class _ConnectGuidePanelState extends State<_ConnectGuidePanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 32),
      child: Column(
        children: [
          const SizedBox(height: 12),
          // Product + soft pulse (Feishu points at case button).
          SizedBox(
            height: 220,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) {
                    final t = Curves.easeInOut.transform(_pulse.value);
                    return Container(
                      width: 120 + 40 * t,
                      height: 120 + 40 * t,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tokens.accent.withValues(
                          alpha: 0.07 + 0.05 * t,
                        ),
                      ),
                    );
                  },
                ),
                Image.asset(
                  'assets/product/guide_connect_case.webp',
                  height: 180,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Image.asset(
                    'assets/product/d3200_chargebox_white.webp',
                    height: 180,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.headphones_battery_rounded,
                      size: 96,
                      color: tokens.textMuted,
                    ),
                  ),
                ),
                // Hint ring near case button area (bottom-left of product).
                Positioned(
                  left: 48,
                  bottom: 36,
                  child: AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, child) {
                      final t = Curves.easeInOut.transform(_pulse.value);
                      return Container(
                        width: 18 + 6 * t,
                        height: 18 + 6 * t,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: tokens.accent.withValues(
                            alpha: 0.35 + 0.25 * t,
                          ),
                          border: Border.all(
                            color: tokens.accent.withValues(alpha: 0.6),
                            width: 2,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text(
            '将麦克风放入充电仓',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: tokens.textPrimary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '短按充电仓下方按钮完成连接',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: tokens.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          if (widget.scanning || widget.connecting)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: widget.connecting ? tokens.mint : tokens.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  widget.connecting ? '正在连接设备…' : '正在等待设备广播…',
                  style: TextStyle(
                    fontSize: 13,
                    color: widget.connecting ? tokens.mint : tokens.textMuted,
                  ),
                ),
              ],
            )
          else
            TextButton.icon(
              onPressed: widget.onRescan,
              icon: Icon(
                Icons.radar_rounded,
                size: 20,
                color: tokens.accent,
              ),
              label: const Text('重新扫描'),
            ),
          if (widget.adsSeen > 0) ...[
            const SizedBox(height: 10),
            Text(
              '已见 ${widget.adsSeen} 条 BLE 广播',
              style: TextStyle(
                fontSize: 11,
                color: tokens.textMuted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (widget.error != null) ...[
            const SizedBox(height: 12),
            Text(
              widget.error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: tokens.coral,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FoundDevicesPanel extends StatelessWidget {
  const _FoundDevicesPanel({
    required this.devices,
    required this.connecting,
    required this.busy,
    required this.scanning,
    required this.onTapDevice,
    required this.onRescan,
    this.connectingId,
    this.error,
  });

  final List<ScannedDevice> devices;
  final bool connecting;
  final bool busy;
  final bool scanning;
  final String? connectingId;
  final ValueChanged<ScannedDevice> onTapDevice;
  final VoidCallback onRescan;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
          child: Column(
            children: [
              Image.asset(
                'assets/product/white_03_device_connect.webp',
                height: 96,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Image.asset(
                  'assets/product/d3200_device_white.webp',
                  height: 72,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                connecting ? '正在连接…' : '发现设备，点选连接',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: connecting ? tokens.accent : tokens.textPrimary,
                ),
              ),
              if (scanning)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '继续扫描中…',
                    style: TextStyle(fontSize: 12, color: tokens.textMuted),
                  ),
                ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              error!,
              style: TextStyle(color: tokens.coral, fontSize: 12),
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            itemCount: devices.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final d = devices[i];
              final isConnecting = connecting && connectingId == d.id;
              return _SheetDeviceTile(
                device: d,
                connecting: isConnecting,
                busy: busy,
                onTap: () => onTapDevice(d),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: TextButton(
            onPressed: busy ? null : onRescan,
            child: const Text('重新扫描'),
          ),
        ),
      ],
    );
  }
}

class _SheetDeviceTile extends StatelessWidget {
  const _SheetDeviceTile({
    required this.device,
    required this.onTap,
    required this.busy,
    this.connecting = false,
  });

  final ScannedDevice device;
  final VoidCallback onTap;
  final bool busy;
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final match = device.looksLikeSoundcore;
    return SurfaceCard(
      onTap: busy ? null : onTap,
      borderColor: connecting
          ? tokens.accent
          : match
          ? tokens.accentBorder
          : tokens.border,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: match ? tokens.accentSoft : tokens.bgPanel,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                color: match ? tokens.accentBorder : tokens.borderSoft,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: connecting
                ? Padding(
                    padding: const EdgeInsets.all(11),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: tokens.accent,
                    ),
                  )
                : match
                ? Image.asset(
                    'assets/product/d3200_device_white.webp',
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.mic_external_on_rounded,
                      color: tokens.accent,
                    ),
                  )
                : Icon(
                    Icons.bluetooth_rounded,
                    color: tokens.textMuted,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.displayName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14.5,
                    color: tokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  connecting ? '正在连接…' : device.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: connecting ? tokens.accent : tokens.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (connecting)
            StatusPill(label: '连接中', color: tokens.accent)
          else if (device.isD3200)
            StatusPill(label: 'D3200', color: tokens.mint)
          else
            StatusPill(label: '${device.rssi} dBm', color: tokens.textMuted),
        ],
      ),
    );
  }
}
