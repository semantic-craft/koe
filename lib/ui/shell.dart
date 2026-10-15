import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ai/stt_types.dart';
import '../state/recorder_controller.dart';
import '../theme/app_theme.dart';
import 'recording_navigation.dart';
import 'screens/device_screen.dart';
import 'screens/communication_screen.dart';
import 'screens/home_screen.dart';
import 'screens/recording_detail_screen.dart';
import 'screens/settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _navigator = GlobalKey<NavigatorState>();
  late final _routes = _RecordingRouteObserver(_routeChanged);
  int _index = 0;
  bool _wide = false;
  // Keep a visible desktop section visible when the window becomes compact.
  bool _sectionVisible = false;
  int _handledLiveRevision = 0;
  int _handledShortcutRevision = 0;

  void _routeChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  bool _sameRecording(RecordingReference? left, RecordingReference? right) {
    if (left == null || right == null) return false;
    if (left.key == right.key) return true;
    final controller = context.read<RecorderController>();
    final leftData = controller.recordingView(left);
    final rightData = controller.recordingView(right);
    return leftData.reference.key == rightData.reference.key ||
        leftData.reference.fileId != null &&
            leftData.reference.fileId == rightData.reference.fileId ||
        leftData.path != null && leftData.path == rightData.path;
  }

  void _openRecording(RecordingReference reference) {
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    if (_sectionVisible || (_wide && _index != 0)) {
      setState(() {
        _sectionVisible = false;
        if (_wide) _index = 0;
      });
    }
    if (_sameRecording(_routes.visibleReference, reference)) return;
    final existing = _routes.routes
        .where(
          (route) =>
              route.settings.arguments is RecordingReference &&
              _sameRecording(
                route.settings.arguments as RecordingReference,
                reference,
              ),
        )
        .firstOrNull;
    if (existing != null) {
      navigator.popUntil((route) => route == existing);
      return;
    }
    final controller = context.read<RecorderController>();
    final data = controller.recordingView(reference);
    final route = MaterialPageRoute<void>(
      settings: RouteSettings(
        name: 'recording/${reference.key}',
        arguments: reference,
      ),
      builder: (_) => data.mode == SttDisplayMode.conversation && data.live
          ? CommunicationScreen(reference: reference)
          : RecordingDetailScreen(reference: reference),
    );
    if (_wide && _routes.routes.length > 1) {
      navigator.pushReplacement(route);
    } else {
      navigator.push(route);
    }
  }

  void _selectTab(int index) {
    setState(() {
      _index = index;
      _sectionVisible = index != 0 && (_wide || _sectionVisible);
    });
    final c = context.read<RecorderController>();
    if (index == 0) c.refreshFilesOnTabEnter();
    if (index == 1) c.refreshInfoOnDeviceTabEnter();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    _wide =
        MediaQuery.sizeOf(context).width >= 1100 &&
        MediaQuery.textScalerOf(context).scale(14) < 21;
    final current = c.currentRecordingReference;
    final newLive = c.liveSessionRevision != _handledLiveRevision;
    final shortcut = c.shortcutNavigationRevision != _handledShortcutRevision;
    if (newLive || shortcut) {
      _handledLiveRevision = c.liveSessionRevision;
      _handledShortcutRevision = c.shortcutNavigationRevision;
      if (current != null && (newLive || c.isLiveSession)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openRecording(current);
        });
      } else if (shortcut) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _navigator.currentState?.popUntil((route) => route.isFirst);
          setState(() {
            _index = 0;
            _sectionVisible = false;
          });
        });
      }
    }
    final covered = _index != 0 && (_wide || _sectionVisible);
    final visible = covered ? null : _routes.visibleReference;
    final showRecording =
        current != null && c.isLiveSession && !_sameRecording(current, visible);
    final playing = c.playingPath;
    final showPlayer =
        c.hasLoadedTrack &&
        playing != null &&
        (visible == null || c.recordingView(visible).path != playing);
    final detailVisible = _routes.routes.length > 1 && !covered;

    return RecordingNavigation(
      onOpen: _openRecording,
      tabIndex: _index,
      wide: _wide,
      selected: _wide ? visible : null,
      child: PopScope(
        canPop: !detailVisible,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _navigator.currentState?.maybePop();
        },
        child: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_wide) _DesktopSidebar(index: _index, onSelect: _selectTab),
              if (_wide)
                Offstage(
                  offstage: _index != 0,
                  child: const SizedBox(width: 340, child: HomeScreen()),
                ),
              if (_wide && _index == 0) const VerticalDivider(width: 1),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Offstage(
                      offstage: covered,
                      // A modal route blocks earlier semantics within its
                      // container, not the adjacent library and navigation.
                      child: Semantics(
                        container: true,
                        explicitChildNodes: true,
                        child: Navigator(
                          key: _navigator,
                          observers: [_routes],
                          onGenerateRoute: (_) => MaterialPageRoute<void>(
                            settings: const RouteSettings(name: 'library'),
                            builder: (_) => const _ShellPages(),
                          ),
                        ),
                      ),
                    ),
                    if (_wide || _sectionVisible)
                      Offstage(
                        offstage: !covered,
                        child: _DesktopPages(index: _index),
                      ),
                  ],
                ),
              ),
            ],
          ),
          // A non-null empty bar still removes the bottom MediaQuery padding
          // from the nested route. Let detail pages own their safe area when
          // there are no shared controls below them.
          bottomNavigationBar:
              (_wide || detailVisible) && !showRecording && !showPlayer
              ? null
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showRecording)
                      _ActiveRecordingBar(
                        onOpen: () => _openRecording(current),
                      ),
                    if (showPlayer)
                      _CompactPlayer(
                        onOpen: () => _openRecording(
                          RecordingReference(
                            fileId: c.fileIdFromPath(playing),
                            path: playing,
                          ),
                        ),
                      ),
                    if (!_wide && !detailVisible)
                      _NavBar(index: _index, onSelect: _selectTab),
                    if (detailVisible && (showPlayer || showRecording))
                      SizedBox(height: MediaQuery.paddingOf(context).bottom),
                  ],
                ),
        ),
      ),
    );
  }
}

// The shell route reads the inherited index because Navigator retains its route
// builder while tabs change. IndexedStack keeps each page and scroll position.
class _ShellPages extends StatelessWidget {
  const _ShellPages();
  @override
  Widget build(BuildContext context) {
    final navigation = context
        .dependOnInheritedWidgetOfExactType<RecordingNavigation>()!;
    if (navigation.wide) return const _ReaderPlaceholder();
    return IndexedStack(
      index: navigation.tabIndex,
      children: const [HomeScreen(), DeviceScreen(), SettingsScreen()],
    );
  }
}

class _RecordingRouteObserver extends NavigatorObserver {
  _RecordingRouteObserver(this.changed);
  final VoidCallback changed;
  final List<Route<dynamic>> routes = [];
  RecordingReference? get visibleReference {
    final value = routes.lastOrNull?.settings.arguments;
    return value is RecordingReference ? value : null;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      routes.add(route);
      changed();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        routes.removeAt(index);
      } else {
        routes[index] = newRoute;
      }
    }
    changed();
  }
}

class _ActiveRecordingBar extends StatelessWidget {
  const _ActiveRecordingBar({required this.onOpen});
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    return Material(
      color: AppColors.bgCard,
      child: Container(
        key: const ValueKey('active-recording-bar'),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: onOpen,
                icon: Icon(
                  Icons.mic_rounded,
                  color: c.recording ? AppColors.coral : AppColors.textMuted,
                ),
                label: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(c.recording ? '录音中 · 打开' : '录音已暂停 · 打开'),
                ),
              ),
            ),
            if (c.recording)
              IconButton(
                tooltip: '暂停录音',
                onPressed: c.phase == AppPhase.busy ? null : c.pauseRecord,
                icon: const Icon(Icons.pause_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

class _CompactPlayer extends StatelessWidget {
  const _CompactPlayer({required this.onOpen});
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final path = c.playingPath;
    final title = path == null
        ? '录音'
        : c
              .recordingView(
                RecordingReference(fileId: c.fileIdFromPath(path), path: path),
              )
              .title;
    return Material(
      color: AppColors.bgCard,
      child: Container(
        key: const ValueKey('compact-player'),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: onOpen,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: c.isPlaying ? '暂停播放' : '继续播放',
              onPressed: c.togglePlayPause,
              icon: Icon(
                c.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            ),
            IconButton(
              tooltip: '关闭播放器',
              onPressed: c.stopPlayback,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.bgCard,
      child: SafeArea(
        top: false,
        child: Container(
          key: const ValueKey('bottom-navigation-bar'),
          padding: const EdgeInsets.fromLTRB(12, 5, 12, 3),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              _NavItem(
                key: const ValueKey('nav-home'),
                icon: Icons.home_rounded,
                label: '首页',
                selected: index == 0,
                onTap: () => onSelect(0),
              ),
              _NavItem(
                key: const ValueKey('nav-device'),
                icon: Icons.devices_rounded,
                label: '设备',
                selected: index == 1,
                onTap: () => onSelect(1),
              ),
              _NavItem(
                key: const ValueKey('nav-settings'),
                icon: Icons.settings_rounded,
                label: '设置',
                selected: index == 2,
                onTap: () => onSelect(2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              AnimatedContainer(
                key: selected ? const ValueKey('active-tab-indicator') : null,
                duration: const Duration(milliseconds: 180),
                width: selected ? 22 : 0,
                height: 2,
                color: selected ? AppColors.accent : Colors.transparent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReaderPlaceholder extends StatelessWidget {
  const _ReaderPlaceholder();
  @override
  Widget build(BuildContext context) => const ColoredBox(
    key: ValueKey('reader-placeholder'),
    color: AppColors.bgElevated,
    child: Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notes_rounded, size: 36, color: AppColors.textMuted),
            SizedBox(height: 20),
            Text(
              '从一段录音开始',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w500),
            ),
            SizedBox(height: 12),
            Text(
              '在左侧选择录音，阅读文字或回听声音。',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DesktopPages extends StatelessWidget {
  const _DesktopPages({required this.index});
  final int index;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppColors.bg,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: IndexedStack(
          index: index == 2 ? 1 : 0,
          children: const [DeviceScreen(), SettingsScreen()],
        ),
      ),
    ),
  );
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({required this.index, required this.onSelect});
  final int index;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    return Container(
      key: const ValueKey('desktop-navigation'),
      width: 184,
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.graphic_eq_rounded, color: AppColors.accent),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Soundcore',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              Tooltip(
                message: c.connected ? '在录音豆上开始录音' : '请先连接录音豆',
                child: FilledButton.icon(
                  onPressed:
                      !c.connected || c.recording || c.blocksRecordingControl
                      ? null
                      : c.startRecord,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(c.recording ? '录音中' : '开始录音'),
                ),
              ),
              const SizedBox(height: 24),
              for (final (i, icon, label) in [
                (0, Icons.library_music_outlined, '录音库'),
                (1, Icons.devices_outlined, '设备'),
                (2, Icons.tune_rounded, '设置'),
              ]) ...[
                Semantics(
                  selected: index == i,
                  child: TextButton.icon(
                    key: ValueKey('nav-${['home', 'device', 'settings'][i]}'),
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      backgroundColor: index == i
                          ? AppColors.bgCardHover
                          : null,
                      foregroundColor: index == i
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                    ),
                    onPressed: () => onSelect(i),
                    icon: Icon(icon, size: 20),
                    label: Text(label),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              const Spacer(),
              const Text(
                'Soundcore Manager',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              const Text(
                '声音与文字，留在一起。',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
