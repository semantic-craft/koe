import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import 'widgets.dart';

/// Settings surface for direct Mac original-audio archiving.
///
/// Pairing material is only built when the user expands the panel, so ordinary
/// screenshots never contain the pairing secret.
class MacArchiveSettings extends StatelessWidget {
  const MacArchiveSettings({super.key, required this.controller});

  final RecorderController controller;

  bool get _isMac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    final archive = controller.archive;
    return Column(
      key: const ValueKey('mac-archive-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_isMac) ...[
          _SettingsGroup(
            // One node, so the switch is announced (and found by
            // scripts/mac-ax) by its title rather than as an unnamed checkbox.
            child: MergeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '这台 Mac 接收原件',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          '只在同一局域网直连；需要手机配对后才能传输',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    key: const ValueKey('mac-receive-switch'),
                    value: archive.deskReceivingEnabled,
                    onChanged: (value) async {
                      try {
                        await archive.setDeskReceiving(value);
                      } on ArchiveException catch (error) {
                        if (!context.mounted) return;
                        _snack(context, error.message);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _MacReceiveStatus(controller: controller),
          const SizedBox(height: 14),
        ],
        const _SettingsGroup(
          child: Text(
            '手机原件归档',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
        ),
        const SizedBox(height: 4),
        if (archive.pairing == null)
          ListTile(
            key: const ValueKey('phone-archive-pair'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.laptop_mac_rounded),
            title: const Text('配对 Mac'),
            subtitle: const Text('直连传输并校验原件；不使用云库，不自动删除手机原件'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _openPairingDialog(context),
          )
        else ...[
          SwitchListTile.adaptive(
            key: const ValueKey('phone-archive-auto'),
            contentPadding: EdgeInsets.zero,
            title: const Text('新原件自动归档'),
            subtitle: const Text('Mac 不在线时排队等待，不影响手机录音、查看和回放'),
            value: archive.autoArchive,
            onChanged: (value) async {
              try {
                await archive.setAutoArchive(value);
              } on ArchiveException catch (error) {
                if (!context.mounted) return;
                _snack(context, error.message);
              }
            },
          ),
          ListTile(
            key: const ValueKey('phone-archive-link'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              archive.connected ? Icons.link_rounded : Icons.link_off_rounded,
              color: archive.authorizationFailed
                  ? AppColors.coral
                  : AppColors.textSecondary,
            ),
            title: Text(archive.linkLabel),
            subtitle: Text(archive.linkDetail),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                key: const ValueKey('phone-archive-connect'),
                onPressed: archive.manualPaused || !archive.connected
                    ? () async {
                        try {
                          await archive.connectNow();
                          if (!context.mounted) return;
                          _snack(context, '已连接 Mac');
                        } on ArchiveException catch (error) {
                          if (!context.mounted) return;
                          _snack(context, error.message);
                        }
                      }
                    : null,
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('连接'),
              ),
              TextButton.icon(
                key: const ValueKey('phone-archive-disconnect'),
                onPressed: archive.manualPaused && archive.phoneError == null
                    ? null
                    : () async {
                        try {
                          await archive.disconnect();
                          if (!context.mounted) return;
                          _snack(context, '已断开 Mac；已排队原件会保留');
                        } on ArchiveException catch (error) {
                          if (!context.mounted) return;
                          _snack(context, error.message);
                        }
                      },
                icon: const Icon(Icons.link_off_rounded, size: 18),
                label: const Text('断开'),
              ),
              TextButton.icon(
                key: const ValueKey('phone-archive-queue-existing'),
                onPressed: () async {
                  try {
                    final count = await archive.queueAllExisting();
                    if (!context.mounted) return;
                    _snack(
                      context,
                      count == 0 ? '现有资料都已归档' : '已加入队列 $count 个原件',
                    );
                  } on ArchiveException catch (error) {
                    if (!context.mounted) return;
                    _snack(context, error.message);
                  }
                },
                icon: const Icon(Icons.playlist_add_rounded, size: 18),
                label: const Text('归档现有资料'),
              ),
              TextButton.icon(
                key: const ValueKey('phone-archive-unpair'),
                onPressed: () async {
                  try {
                    await archive.unpair();
                    if (!context.mounted) return;
                    _snack(context, '已取消本机配对；Mac 原件保留');
                  } on ArchiveException catch (error) {
                    if (!context.mounted) return;
                    _snack(context, error.message);
                  }
                },
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('取消配对'),
              ),
            ],
          ),
          const Text(
            '取消配对仅清除本机保存的连接。要撤销旧设备，请在 Mac 重置配对凭据。',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11),
          ),
        ],
        if (archive.phoneError != null) ...[
          const SizedBox(height: 6),
          Text(
            archive.phoneError!,
            key: const ValueKey('phone-archive-error'),
            style: const TextStyle(color: AppColors.coral, fontSize: 12),
          ),
        ],
        if (archive.records.any(
          (record) => record.phase == MacArchivePhase.failed,
        ))
          TextButton(
            key: const ValueKey('phone-archive-retry-failed'),
            onPressed: () async {
              for (final record in archive.records) {
                if (record.phase != MacArchivePhase.failed) continue;
                try {
                  await archive.retry(record.localPath);
                } on ArchiveException catch (error) {
                  if (!context.mounted) return;
                  _snack(context, error.message);
                }
              }
            },
            child: const Text('重试失败的归档'),
          ),
      ],
    );
  }

  Future<void> _openPairingDialog(BuildContext context) async {
    final paired = await showDialog<bool>(
      context: context,
      builder: (_) => _PairingDialog(controller: controller),
    );
    if (paired == true && context.mounted) {
      _snack(context, '已配对 Mac');
    }
  }

  void _snack(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _MacReceiveStatus extends StatelessWidget {
  const _MacReceiveStatus({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final archive = controller.archive;
    if (!archive.deskReceivingEnabled) {
      return Column(
        key: const ValueKey('mac-receive-off'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '接收已关闭。打开后手机才能配对和归档；重置配对凭据后，开启接收才会显示新信息。',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          _ResetPairingButton(controller: controller),
        ],
      );
    }
    final pairing = archive.deskPairing;
    return Column(
      key: const ValueKey('mac-receive-status'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          archive.deskRunning
              ? '接收服务已开启 · 端口 ${archive.deskPort ?? '--'}'
              : '接收服务正在启动',
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        if (archive.deskError != null)
          Text(
            archive.deskError!,
            key: const ValueKey('mac-receive-error'),
            style: const TextStyle(color: AppColors.coral, fontSize: 12),
          ),
        Text(
          '已接收 ${archive.receivedCount} 条资料'
          '${archive.lastReceivedAt == null ? '' : ' · 最近 ${_format(archive.lastReceivedAt!)}'}',
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        if (pairing != null) ...[
          const SizedBox(height: 6),
          ExpansionTile(
            key: const ValueKey('mac-pairing-expand'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: const Text(
              '显示配对信息（含密钥）',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              '在手机上粘贴这串信息即可配对。不要截图公开分享。',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            children: [
              SurfaceCard(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(
                      pairing.encode(),
                      key: const ValueKey('mac-pair-code'),
                      style: const TextStyle(fontSize: 11, height: 1.35),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        key: const ValueKey('mac-pair-copy'),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: pairing.encode()),
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('配对信息已复制')),
                          );
                        },
                        icon: const Icon(Icons.copy_outlined, size: 16),
                        label: const Text('复制'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Text(
            '手机与 Mac 需在同一局域网；只接受持有这串配对信息的设备。',
            style: const TextStyle(
              fontSize: 12,
              height: 1.35,
              color: AppColors.textSecondary,
            ),
          ),
        ],
        _ResetPairingButton(controller: controller),
      ],
    );
  }

  String _format(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _ResetPairingButton extends StatelessWidget {
  const _ResetPairingButton({required this.controller});

  final RecorderController controller;

  Future<void> _reset(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置 Mac 配对凭据？'),
        content: const Text(
          '旧配对信息会立即失效，所有已连接设备会断开。'
          '已归档原件会保留，接收开关保持原设置；其他设备需要使用新配对信息重新连接。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('mac-reset-pairing-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重置凭据'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await controller.archive.resetDeskPairing();
      if (!messenger.mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(content: Text('配对凭据已重置；旧配对信息失效，已归档原件保留')),
      );
    } on ArchiveException catch (error) {
      if (!messenger.mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('mac-reset-pairing'),
        onPressed: () => _reset(context),
        icon: const Icon(Icons.key_off_rounded, size: 18),
        label: const Text('重置配对凭据'),
      ),
    );
  }
}

class _PairingDialog extends StatefulWidget {
  const _PairingDialog({required this.controller});

  final RecorderController controller;

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.archive.pairWithCode(_code.text);
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ArchiveException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '配对失败，请检查配对信息';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('配对 Mac'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '在 Mac 的“设置 → Mac 原件归档”里展开配对信息，然后把整串内容粘贴到这里。',
            style: TextStyle(fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('phone-archive-code-field'),
            controller: _code,
            minLines: 2,
            maxLines: 5,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '配对信息',
              hintText: 'KOE1.…',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              key: const ValueKey('phone-archive-pair-error'),
              style: const TextStyle(color: AppColors.coral, fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('phone-archive-pair-confirm'),
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? '正在验证…' : '配对'),
        ),
      ],
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 16),
        child: child,
      ),
    );
  }
}
