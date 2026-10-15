import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/widgets.dart';

class DeviceScreen extends StatelessWidget {
  const DeviceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final tokens = KoeTokens.of(context);
    if (!c.connected) {
      return _OfflineDeviceView(controller: c);
    }

    final info = c.info;
    final micBat = info?.battery;
    final caseBat = info?.boxBattery;
    final transcribing = c.transcribing || c.streamingSttActive;
    final paused = c.isLiveSession && !c.recording;

    return GradientScaffold(
      appBar: AppBar(
        backgroundColor: tokens.bgCard,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: tokens.borderSoft),
        ),
        title: Row(
          children: [
            Image.asset(
              'assets/product/d3200_device_connected_white.webp',
              width: 36,
              height: 36,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Image.asset(
                'assets/product/hero_connected_white.png',
                width: 36,
                height: 36,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Icon(
                  Icons.headphones_rounded,
                  size: 24,
                  color: tokens.textMuted,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                info?.hasIdentity == true ? 'soundcore Work' : '已连接',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: c.phase == AppPhase.busy ? null : c.refreshInfo,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '断开连接',
            onPressed: c.disconnect,
            icon: Icon(Icons.link_off_rounded, color: tokens.coral),
          ),
        ],
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 100),
          children: [
            const SectionLabel('电量'),
            _DeviceSection(
              key: const ValueKey('device-battery-section'),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(
                    children: [
                      Image.asset(
                        'assets/product/d3200_device_white.webp',
                        height: 28,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 6),
                      BatteryRing(
                        percent: micBat ?? 0,
                        charging: info?.charging ?? false,
                        size: 74,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '麦克风',
                        style: TextStyle(
                          color: tokens.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  Container(width: 1, height: 84, color: tokens.borderSoft),
                  Column(
                    children: [
                      Image.asset(
                        'assets/product/d3200_chargebox_white.webp',
                        height: 28,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 6),
                      BatteryRing(
                        percent: caseBat ?? 0,
                        charging: info?.boxCharging ?? false,
                        size: 74,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '充电盒',
                        style: TextStyle(
                          color: tokens.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('录音控制'),
            _DeviceSection(
              key: const ValueKey('device-recording-section'),
              borderColor: c.recording
                  ? tokens.coralBorder
                  : paused
                  ? tokens.amberBorder
                  : tokens.border,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: c.recording
                          ? tokens.coralSoft
                          : paused
                          ? tokens.amberSoft
                          : transcribing
                          ? tokens.accentSoft
                          : tokens.bgPanel,
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      border: Border.all(
                        color: c.recording
                            ? tokens.coralBorder
                            : paused
                            ? tokens.amberBorder
                            : transcribing
                            ? tokens.accentBorder
                            : tokens.borderSoft,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: c.recording
                                ? tokens.coral
                                : paused
                                ? tokens.amber
                                : transcribing
                                ? tokens.accent
                                : tokens.mint,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            c.recording
                                ? (transcribing
                                      ? '正在录音并实时转写'
                                      : '录音进行中')
                                : paused
                                ? '录音已暂停'
                                : transcribing
                                ? '正在转写音频…'
                                : '设备就绪 · 可随时开始录音',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: tokens.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: AccentButton(
                          label: c.recording ? '录音中…' : '开始',
                          icon: Icons.mic_rounded,
                          color: tokens.coral,
                          onPressed: c.recording || c.blocksRecordingControl
                              ? null
                              : c.startRecord,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: AccentButton(
                          label: '暂停',
                          icon: Icons.pause_rounded,
                          filled: false,
                          color: tokens.amber,
                          onPressed: !c.recording || c.phase == AppPhase.busy
                              ? null
                              : c.pauseRecord,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  AccentButton(
                    label: '同步设备时钟',
                    icon: Icons.schedule_rounded,
                    filled: false,
                    color: tokens.textPrimary,
                    onPressed: c.phase == AppPhase.busy ? null : c.syncTime,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('配对绑定'),
            _DeviceSection(
              key: const ValueKey('device-pairing-section'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: AccentButton(
                          label: c.bound ? '已绑定' : '绑定',
                          icon: Icons.link_rounded,
                          onPressed: c.bound || c.phase == AppPhase.busy
                              ? null
                              : () => c.bindDevice(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: AccentButton(
                          label: '解绑',
                          icon: Icons.link_off_rounded,
                          filled: false,
                          color: tokens.textSecondary,
                          onPressed: !c.bound || c.phase == AppPhase.busy
                              ? null
                              : () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      backgroundColor: tokens.bgCard,
                                      title: const Text('确认解绑？'),
                                      content: Text(
                                        '将向设备发送解绑指令（与飞书相同，payload 00）。\n'
                                        '• 不会清空录音或恢复出厂\n'
                                        '• 成功后会断开连接\n'
                                        '• 之后可再扫描、连接并重新绑定',
                                        style: TextStyle(
                                          color: tokens.textSecondary,
                                          height: 1.4,
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('取消'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text('解绑'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) await c.unbindDevice();
                                },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('设备信息'),
            _DeviceSection(
              key: const ValueKey('device-info-section'),
              child: Column(
                children: [
                  const _DeviceInfoRow(label: '产品', value: 'D3200'),
                  const Divider(height: 16),
                  _DeviceInfoRow(
                    label: '序列号',
                    value: info?.serialNumber.isNotEmpty == true
                        ? info!.serialNumber
                        : '—',
                  ),
                  const Divider(height: 16),
                  _DeviceInfoRow(
                    label: '固件版本',
                    value: info?.firmwareVersion.isNotEmpty == true
                        ? info!.firmwareVersion
                        : '—',
                  ),
                  const Divider(height: 16),
                  _DeviceInfoRow(label: '存储', value: info?.storageLabel ?? '—'),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('危险操作'),
            _DeviceSection(
              key: const ValueKey('device-danger-section'),
              borderColor: tokens.coralBorder,
              child: AccentButton(
                label: '恢复出厂设置',
                icon: Icons.restart_alt_rounded,
                color: tokens.coral,
                filled: false,
                onPressed: c.phase == AppPhase.busy
                    ? null
                    : () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: tokens.bgCard,
                            title: const Text('确定恢复出厂？'),
                            content: Text(
                              '将发送重置指令（0x01/0xB8）。'
                              '设备将恢复默认设置。',
                              style: TextStyle(color: tokens.textSecondary),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: Text(
                                  '重置',
                                  style: TextStyle(color: tokens.coral),
                                ),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) await c.resetDevice();
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceSection extends StatelessWidget {
  const _DeviceSection({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tokens.bgCard,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: borderColor ?? tokens.border),
        boxShadow: tokens.cardShadow,
      ),
      child: child,
    );
  }
}

class _DeviceInfoRow extends StatelessWidget {
  const _DeviceInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: tokens.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tokens.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Disconnected Device tab: still show last known / bound unit.
class _OfflineDeviceView extends StatelessWidget {
  const _OfflineDeviceView({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final d = c.displayDevice;
    final tokens = KoeTokens.of(context);

    return GradientScaffold(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          children: [
            if (d != null) ...[
              SurfaceCard(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: _OfflineProductImage()),
                    const SizedBox(height: 12),
                    Text(
                      d.displayName,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    if (c.bound || d.isBoundAdvertised) ...[
                      const SizedBox(height: 10),
                      Center(
                        child: StatusPill(
                          label: c.bound ? '已绑定' : '广告已绑定',
                          color: tokens.accent,
                        ),
                      ),
                    ],
                    if (d.macAddress != null && d.macAddress!.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        d.macAddress!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: tokens.textMuted,
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Text(
                      '设备已断开。点下方按钮扫描并重新连接。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: tokens.textSecondary,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 16),
                    AccentButton(
                      label: '扫描并连接',
                      icon: Icons.radar_rounded,
                      onPressed: () => showScanDevicesSheet(context),
                    ),
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 48),
              SurfaceCard(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    IconBadge(
                      icon: Icons.devices_other_rounded,
                      size: 52,
                      iconSize: 26,
                      radius: 14,
                      color: tokens.textSecondary,
                      backgroundColor: tokens.bgPanel,
                      borderColor: tokens.border,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '尚未连接设备',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '扫描附近的 soundcore Work（D3200）并连接。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: tokens.textSecondary,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 18),
                    AccentButton(
                      label: '扫描设备',
                      icon: Icons.radar_rounded,
                      onPressed: () => showScanDevicesSheet(context),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OfflineProductImage extends StatelessWidget {
  const _OfflineProductImage();

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Semantics(
      image: true,
      label: '设备离线，蓝牙连接已断开',
      child: SizedBox(
        width: 220,
        height: 142,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: 0.62,
              child: ColorFiltered(
                colorFilter: const ColorFilter.matrix([
                  0.2126,
                  0.7152,
                  0.0722,
                  0,
                  0,
                  0.2126,
                  0.7152,
                  0.0722,
                  0,
                  0,
                  0.2126,
                  0.7152,
                  0.0722,
                  0,
                  0,
                  0,
                  0,
                  0,
                  1,
                  0,
                ]),
                child: Image.asset(
                  'assets/product/d3200_device_connected_white.webp',
                  height: 132,
                  fit: BoxFit.contain,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.headphones_rounded,
                    size: 64,
                    color: tokens.textMuted,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 7,
              right: 27,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: tokens.coralSoft,
                  shape: BoxShape.circle,
                  border: Border.all(color: tokens.coralBorder),
                ),
                child: Icon(
                  Icons.bluetooth_disabled_rounded,
                  size: 22,
                  color: tokens.coral,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
