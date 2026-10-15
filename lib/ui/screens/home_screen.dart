import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/widgets.dart';
import 'files_screen.dart';

/// A stable recording library; live and saved reading happens in detail routes.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loadedFiles = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedFiles) return;
    _loadedFiles = true;
    final c = context.read<RecorderController>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      c.refreshFilesOnTabEnter();
    });
  }

  @override
  Widget build(BuildContext context) {
    return GradientScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ConnectionHeader(onScan: () => showScanDevicesSheet(context)),
          const Expanded(
            child: FilesBody(
              key: ValueKey('files'),
              padding: EdgeInsets.fromLTRB(20, 10, 20, 0),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionHeader extends StatelessWidget {
  const _ConnectionHeader({required this.onScan});

  final VoidCallback onScan;

  /// Prefer real connection/STT status; never keep a stale "正在播放" line.
  static String _idleStatus(RecorderController c) {
    final m = c.statusMessage;
    if (m == null || m.isEmpty) return '已连接';
    if (m.startsWith('正在播放') || m.startsWith('正在准备播放')) {
      return '已连接';
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final tokens = KoeTokens.of(context);
    final online = c.connected;
    final live = c.isLiveSession;
    final name = c.displayDeviceName;

    return Container(
      decoration: BoxDecoration(
        color: tokens.bgCard,
        border: Border(bottom: BorderSide(color: tokens.borderSoft)),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        MediaQuery.paddingOf(context).top + 12,
        20,
        14,
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: online ? tokens.mintSoft : tokens.bgPanel,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                color: online ? tokens.mintBorder : tokens.border,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: online
                ? Image.asset(
                    'assets/product/d3200_device_white.webp',
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.headphones_rounded,
                      color: tokens.mint,
                      size: 20,
                    ),
                  )
                : Icon(
                    Icons.link_off_rounded,
                    color: tokens.textSecondary,
                    size: 20,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: online ? tokens.mint : tokens.textFaint,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        online
                            ? name
                            : (c.displayDevice != null ? name : '未连接设备'),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                          color: tokens.textPrimary,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (!live) ...[
                  const SizedBox(height: 3),
                  Text(
                    online
                        ? (c.isPlaying
                              ? (c.statusMessage?.startsWith('正在播放') == true
                                    ? c.statusMessage!
                                    : '正在播放')
                              : _idleStatus(c))
                        : '点「扫描」查找 soundcore Work',
                    style: TextStyle(
                      fontSize: 12,
                      color: c.isPlaying ? tokens.accent : tokens.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (!online)
            IconButton(
              tooltip: '扫描',
              onPressed: onScan,
              style: IconButton.styleFrom(
                backgroundColor: tokens.accentSoft,
                foregroundColor: tokens.accent,
                minimumSize: const Size(48, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  side: BorderSide(color: tokens.accentBorder),
                ),
              ),
              icon: const Icon(Icons.radar_rounded, size: 22),
            ),
        ],
      ),
    );
  }
}
