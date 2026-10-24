import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_identity.dart';
import '../ai/stt_types.dart';
import '../platform/mac_app.dart';
import '../state/recorder_controller.dart';
import '../theme/app_theme.dart';
import 'mac_menu_bar.dart';
import 'recording_navigation.dart';
import 'screens/ask_koe_screen.dart';
import 'screens/device_screen.dart';
import 'screens/communication_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/new_recording_sheet.dart';
import 'screens/projects_screen.dart';
import 'screens/recording_detail_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/text_capture_sheet.dart';
import 'screens/today_screen.dart';
import 'screens/trash_screen.dart';
import 'widgets/koe_icon_button.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _navigator = GlobalKey<NavigatorState>();
  late final _routes = _RecordingRouteObserver(_routeChanged);
  int _index = 0;
  int _mobileIndex = 0;
  bool _wide = false;
  bool _trashOpen = false;
  bool? _renderedWide;
  int? _compactRestoreIndex;
  Route<void>? _compactSettingsRoute;
  // Keep a visible desktop section visible when the window becomes compact.
  bool _sectionVisible = false;
  int _handledLiveRevision = 0;
  int _handledShortcutRevision = 0;
  int _handledShortcutFailureRevision = 0;
  int _handledCalendarMeetingRevision = 0;
  bool _calendarMeetingPromptOpen = false;
  bool _residentOffered = false;
  MacMenuBar? _macMenuBar;
  bool _startedTakeDue = false;

  @override
  void initState() {
    super.initState();
    if (MacApp.shared.enabled) {
      _macMenuBar = MacMenuBar(
        context.read<RecorderController>(),
        onStart: _showStartedTake,
      );
    }
  }

  /// Shows the controls of a take started from the Mac menu bar or ⌃⌥⌘R
  /// (#405) once the window draws: a closed one draws nothing, and the take
  /// may be over by the time it opens.
  void _showStartedTake() {
    if (_startedTakeDue) return;
    _startedTakeDue = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _startedTakeDue = false;
        if (!mounted) return;
        final c = context.read<RecorderController>();
        unawaited(
          c.textCaptureActive || (!c.phoneRecordingActive && c.allDayListening)
              ? showTextCaptureSheet(
                  context,
                  allDay: true,
                  startedElsewhere: true,
                )
              : showPhoneRecordingSheet(context, startedElsewhere: true),
        );
      })
      ..scheduleFrame();
  }

  @override
  void dispose() {
    _macMenuBar?.dispose();
    super.dispose();
  }

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

  void _openRecording(RecordingReference reference, {int? initialParagraph}) {
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    if (_wide && _index != 0) {
      setState(() {
        _sectionVisible = false;
        _index = 0;
      });
    }
    if (initialParagraph == null &&
        _sameRecording(_routes.visibleReference, reference)) {
      return;
    }
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
      if (initialParagraph == null) return;
      navigator.removeRoute(existing);
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
          : RecordingDetailScreen(
              reference: reference,
              initialHighlightedParagraph: initialParagraph,
            ),
    );
    if (_wide && _routes.routes.length > 1) {
      navigator.pushReplacement(route);
    } else {
      navigator.push(route);
    }
  }

  void _selectDesktopTab(int index) {
    if (_trashOpen) {
      _trashOpen = false;
      _navigator.currentState?.pop();
    }
    setState(() {
      _index = index;
      _sectionVisible = index != 0 && (_wide || _sectionVisible);
    });
    final c = context.read<RecorderController>();
    if (index == 0) c.refreshFilesOnTabEnter();
    if (index == 1) c.refreshInfoOnDeviceTabEnter();
  }

  Future<void> _openTrash() async {
    final navigator = _navigator.currentState;
    if (navigator == null || _trashOpen) return;
    _trashOpen = true;
    setState(() {
      _index = 0;
      _sectionVisible = false;
    });
    await navigator.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'trash'),
        builder: (_) => const TrashScreen(),
      ),
    );
    if (mounted) setState(() => _trashOpen = false);
  }

  void _selectMobileTab(int index) {
    if (_mobileIndex == index) return;
    setState(() => _mobileIndex = index);
    final c = context.read<RecorderController>();
    if (index == 2) c.refreshFilesOnTabEnter();
  }

  /// Asks once, after the recorder is bound, whether Koe should stay
  /// resident for it (Android).
  Future<void> _offerResident(RecorderController c) async {
    c.markResidentOffered();
    final on = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('全天常驻'),
        content: const Text(
          '录音豆回到身边时，Koe 自动连上并取回新录音，不用先打开 Koe；'
          '划掉 Koe 或重启手机后也一样。录音豆不在身边时 Koe 不在后台运行。\n\n'
          '接下来 Android 会请你允许 Koe 关联这个录音豆。可随时在设置里关闭。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('以后再说'),
          ),
          FilledButton(
            key: const ValueKey('resident-offer-accept'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('开启'),
          ),
        ],
      ),
    );
    if (on == true) await c.setResident(true);
  }

  /// Shows a start-of-meeting prompt on the phone (#373): asks whether to
  /// record the meeting without auto-starting the microphone.
  Future<void> _promptCalendarMeeting(
    RecorderController c,
    String title,
  ) async {
    if (!mounted ||
        _calendarMeetingPromptOpen ||
        c.phoneRecordingActive ||
        c.textCaptureActive) {
      c.clearCalendarMeetingPrompt();
      return;
    }
    _calendarMeetingPromptOpen = true;
    c.clearCalendarMeetingPrompt();
    final bool? start;
    try {
      start = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('calendar-meeting-reminder-dialog'),
          title: Text('「$title」开始了'),
          content: Text(
            c.allDayListening
                ? '日历里的这场会议已到开始时间，要开始全天监听吗？'
                : '日历里的这场会议已到开始时间，要用手机录音吗？',
          ),
          actions: [
            TextButton(
              key: const ValueKey('calendar-meeting-reminder-dismiss'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('暂不'),
            ),
            FilledButton(
              key: const ValueKey('calendar-meeting-reminder-start'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(c.allDayListening ? '开始全天监听' : '开始录音'),
            ),
          ],
        ),
      );
    } finally {
      _calendarMeetingPromptOpen = false;
    }
    final innerContext = _navigator.currentContext ?? context;
    if (start == true && innerContext.mounted) {
      await handleNewRecordingAction(innerContext, NewRecordingAction.phone);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    _wide =
        MediaQuery.sizeOf(context).width >= 1100 &&
        MediaQuery.textScalerOf(context).scale(14) < 21;
    final previousWide = _renderedWide;
    _renderedWide = _wide;
    if (previousWide == true && !_wide && _index != 0) {
      final restore = _index;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _wide) return;
        setState(() {
          _compactRestoreIndex = restore;
          _index = 0;
          if (restore == 1) _mobileIndex = 2;
        });
        if (restore == 2) {
          final navigator = _navigator.currentState;
          if (navigator != null) {
            final route = MaterialPageRoute<void>(
              settings: const RouteSettings(name: 'settings'),
              builder: (_) => const SettingsScreen(showBack: true),
            );
            _compactSettingsRoute = route;
            navigator.push(route);
          }
        }
      });
    } else if (previousWide == false &&
        _wide &&
        (_compactSettingsRoute != null || _compactRestoreIndex != null)) {
      final route = _compactSettingsRoute;
      final restore = _compactRestoreIndex;
      _compactSettingsRoute = null;
      _compactRestoreIndex = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_wide) return;
        if (route != null && route.isActive) {
          _navigator.currentState?.removeRoute(route);
        }
        setState(() {
          _index = restore ?? 0;
          _sectionVisible = _index != 0;
        });
      });
    }
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
    // Home shows the recorder's status only while it is connected, and the
    // shortcut can fail on any tab.
    final failure = c.recordingShortcutFailure;
    if (c.recordingShortcutFailureRevision != _handledShortcutFailureRevision) {
      _handledShortcutFailureRevision = c.recordingShortcutFailureRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || failure == null) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('快捷录音未开始：$failure')));
      });
    }
    if (c.offersResident && !_residentOffered) {
      _residentOffered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _offerResident(c);
      });
    }
    final meetingTitle = c.pendingCalendarMeetingPrompt;
    if (c.calendarMeetingPromptRevision != _handledCalendarMeetingRevision) {
      _handledCalendarMeetingRevision = c.calendarMeetingPromptRevision;
      if (meetingTitle != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_promptCalendarMeeting(c, meetingTitle));
        });
      }
    }
    final covered = _wide && _sectionVisible;
    final visible = covered ? null : _routes.visibleReference;
    final showRecording =
        current != null && c.isLiveSession && !_sameRecording(current, visible);
    final playing = c.playingPath;
    final showPlayer =
        c.hasLoadedTrack &&
        playing != null &&
        (visible == null || c.recordingView(visible).path != playing);
    final showListening = c.textCaptureActive && c.textCaptureAllDay;
    final detailVisible = _routes.routes.length > 1 && !covered;

    return RecordingNavigation(
      onOpen: _openRecording,
      tabIndex: _mobileIndex,
      wide: _wide,
      selected: _wide ? visible : null,
      onSelectTab: _selectMobileTab,
      child: PopScope(
        canPop: !detailVisible && _routes.popups.isEmpty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _navigator.currentState?.maybePop();
        },
        child: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_wide)
                _DesktopSidebar(
                  index: _index,
                  trashOpen: _trashOpen,
                  onSelect: _selectDesktopTab,
                  onOpenTrash: _openTrash,
                ),
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
                    if (!_wide && !detailVisible && _routes.popups.isEmpty)
                      Positioned(
                        right: 16,
                        bottom: 12,
                        child: _AskKoeButton(
                          onPressed: () => openAskKoe(context),
                        ),
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
              (_wide || detailVisible) &&
                  !showRecording &&
                  !showPlayer &&
                  !showListening
              ? null
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showListening)
                      _AllDayListeningBar(
                        onOpen: () => showTextCaptureSheet(context),
                      ),
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
                      _MobileNavBar(
                        index: _mobileIndex,
                        onSelect: _selectMobileTab,
                      ),
                    if (detailVisible &&
                        (showPlayer || showRecording || showListening))
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
      children: const [TodayScreen(), ProjectsScreen(), LibraryScreen()],
    );
  }
}

class _RecordingRouteObserver extends NavigatorObserver {
  _RecordingRouteObserver(this.changed);
  final VoidCallback changed;
  final List<Route<dynamic>> routes = [];
  // Sheets and dialogs open inside this navigator, below the shell's
  // floating Ask Koe button; the shell hides the button while one is up.
  final List<Route<dynamic>> popups = [];
  RecordingReference? get visibleReference {
    final value = routes.lastOrNull?.settings.arguments;
    return value is RecordingReference ? value : null;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      routes.add(route);
      changed();
    } else if (route is PopupRoute) {
      popups.add(route);
      changed();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    popups.remove(route);
    changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    popups.remove(route);
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

/// Stays up while all-day listening runs, so it is always one tap from
/// its controls.
class _AllDayListeningBar extends StatelessWidget {
  const _AllDayListeningBar({required this.onOpen});
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final label = c.textCapturePaused
        ? '全天监听已暂停 · 打开'
        : c.textCaptureResting
        ? '全天监听中 · 安静'
        : '全天监听中 · 打开';
    return Material(
      color: AppColors.bgCard,
      child: Container(
        key: const ValueKey('all-day-listening-bar'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: TextButton.icon(
          onPressed: onOpen,
          icon: const _RecordingDot(),
          label: Align(alignment: Alignment.centerLeft, child: Text(label)),
        ),
      ),
    );
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
          border: Border(top: BorderSide(color: AppColors.border, width: 0)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: onOpen,
                // A still dot: this bar can stay up for hours of recording,
                // so only the recording sheet itself breathes.
                icon: c.recording
                    ? const _RecordingDot()
                    : const Icon(Icons.mic_rounded, color: AppColors.textMuted),
                label: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(c.recording ? '录音中 · 打开' : '录音已暂停 · 打开'),
                ),
              ),
            ),
            if (c.recording)
              KoeIconButton(
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

class _RecordingDot extends StatelessWidget {
  const _RecordingDot();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 24,
    child: Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.accent,
          shape: BoxShape.circle,
        ),
        child: SizedBox.square(dimension: 10),
      ),
    ),
  );
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
          border: Border(top: BorderSide(color: AppColors.border, width: 0)),
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
            KoeIconButton(
              tooltip: c.isPlaying ? '暂停播放' : '继续播放',
              onPressed: c.togglePlayPause,
              icon: Icon(
                c.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            ),
            KoeIconButton(
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

class _MobileNavBar extends StatelessWidget {
  const _MobileNavBar({required this.index, required this.onSelect});

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
            border: Border(top: BorderSide(color: AppColors.border, width: 0)),
          ),
          child: Row(
            children: [
              _NavItem(
                key: const ValueKey('nav-today'),
                icon: Icons.today_outlined,
                label: '今日',
                selected: index == 0,
                onTap: () => onSelect(0),
              ),
              _NavItem(
                key: const ValueKey('nav-projects'),
                icon: Icons.workspaces_outline,
                label: '项目',
                selected: index == 1,
                onTap: () => onSelect(1),
              ),
              _NavItem(
                key: const ValueKey('nav-library'),
                icon: Icons.library_music_outlined,
                label: '资料',
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
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        // Excluding the child's semantics also drops its tap; restore it so
        // VoiceOver and Voice Control can activate the tab.
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppMotion.snap),
            curve: AppMotion.snappy,
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
                  duration: AppMotion.duration(context, AppMotion.snap),
                  curve: AppMotion.snappy,
                  width: selected ? 22 : 0,
                  height: 2,
                  color: selected ? AppColors.accent : Colors.transparent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AskKoeButton extends StatelessWidget {
  const _AskKoeButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      key: const ValueKey('ask-koe'),
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
      label: const Text('问 Koe'),
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
  const _DesktopSidebar({
    required this.index,
    required this.trashOpen,
    required this.onSelect,
    required this.onOpenTrash,
  });
  final int index;
  final bool trashOpen;
  final ValueChanged<int> onSelect;
  final VoidCallback onOpenTrash;
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
                      AppIdentity.name,
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
                  label: Text(
                    c.recording
                        ? '录音中'
                        : c.recordingPaused
                        ? '继续录音'
                        : '开始录音',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // One click to hand the recorder to the phone and back; it
              // stays bound either way.
              if (c.connected)
                OutlinedButton.icon(
                  key: const ValueKey('sidebar-disconnect'),
                  onPressed: c.disconnect,
                  icon: const Icon(Icons.link_off_rounded, size: 18),
                  label: const Text('断开录音豆'),
                )
              else if (c.canReconnectBoundDevice)
                OutlinedButton.icon(
                  key: const ValueKey('sidebar-connect'),
                  onPressed:
                      c.phase == AppPhase.scanning ||
                          c.phase == AppPhase.connecting
                      ? null
                      : c.reconnectBoundDevice,
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: Text(
                    c.phase == AppPhase.connecting ||
                            c.phase == AppPhase.scanning
                        ? '正在连接…'
                        : '连接录音豆',
                  ),
                ),
              const SizedBox(height: 24),
              for (final (i, icon, label) in [
                (0, Icons.library_music_outlined, '录音库'),
                (1, Icons.devices_outlined, '设备'),
                (2, Icons.tune_rounded, '设置'),
              ]) ...[
                Semantics(
                  button: true,
                  selected: !trashOpen && index == i,
                  label: label,
                  onTap: () => onSelect(i),
                  excludeSemantics: true,
                  child: TextButton.icon(
                    key: ValueKey('nav-${['home', 'device', 'settings'][i]}'),
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      backgroundColor: !trashOpen && index == i
                          ? AppColors.bgCardHover
                          : null,
                      foregroundColor: !trashOpen && index == i
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
              Semantics(
                button: true,
                selected: trashOpen,
                label: '回收站',
                onTap: onOpenTrash,
                excludeSemantics: true,
                child: TextButton.icon(
                  key: const ValueKey('nav-trash'),
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    backgroundColor: trashOpen ? AppColors.bgCardHover : null,
                    foregroundColor: trashOpen
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 16,
                    ),
                  ),
                  onPressed: onOpenTrash,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  label: const Text('回收站'),
                ),
              ),
              const SizedBox(height: 6),
              const Spacer(),
              const Text(
                AppIdentity.subtitle,
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
