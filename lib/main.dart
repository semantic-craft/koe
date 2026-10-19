import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'app_identity.dart';
import 'state/container_paths.dart';
import 'state/recorder_controller.dart';
import 'platform/recording_shortcut_service.dart';
import 'theme/app_theme.dart';
import 'ui/localization.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.semanticcraft.soundcore.audio',
      androidNotificationChannelName: '回听',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    );
  }
  LicenseRegistry.addLicense(() async* {
    for (final name in ['meetily', 'ownscribe']) {
      yield LicenseEntryWithLineBreaks([
        name,
      ], await rootBundle.loadString('assets/licenses/$name.txt'));
    }
  });
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    try {
      // Must be set before RecorderController creates BleService. This lets
      // Core Bluetooth restore active connections after background eviction.
      await FlutterBluePlus.setOptions(restoreState: true);
    } catch (error) {
      debugPrint('[BLE] State restoration setup failed: $error');
    }
  }
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    // Before any store loads: saved absolute paths may name the container
    // of a previous install.
    try {
      final docs = await getApplicationDocumentsDirectory();
      await relocateStoredPaths(
        Directory(p.join(docs.path, 'AnkerRecorder')),
        docs.path,
      );
    } catch (error) {
      debugPrint('[ContainerPaths] relocation skipped: $error');
    }
  }
  final controller = RecorderController();
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android) {
    unawaited(_watchAudioInterruptions(controller));
  }
  runApp(KoeApp(controller: controller));
  unawaited(
    RecordingShortcutService.instance.initialize(
      onStartRecording: controller.requestRecordingFromShortcut,
    ),
  );
}

Future<void> _watchAudioInterruptions(RecorderController controller) async {
  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        unawaited(controller.pauseForInterruption(message: '系统中断了播放'));
      }
    });
    session.becomingNoisyEventStream.listen((_) {
      unawaited(controller.pauseForInterruption(message: '耳机已断开，播放已暂停'));
    });
  } catch (error) {
    debugPrint('[AudioSession] setup failed: $error');
  }
}

class KoeApp extends StatelessWidget {
  const KoeApp({super.key, this.controller});

  final RecorderController? controller;

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      title: AppIdentity.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.light,
      locale: koeLocale,
      supportedLocales: const [koeLocale],
      localizationsDelegates: koeLocalizationsDelegates,
      builder: (context, child) {
        // iOS「减弱动态效果」only reaches Flutter as `reduceMotion`; fold it
        // into `disableAnimations` so AppMotion and every widget below honour
        // it the same way as Android's「移除动画」.
        final media = MediaQuery.of(context);
        final reduceMotion = View.of(
          context,
        ).platformDispatcher.accessibilityFeatures.reduceMotion;
        if (!reduceMotion || media.disableAnimations) return child!;
        return MediaQuery(
          data: media.copyWith(disableAnimations: true),
          child: child!,
        );
      },
      home: const AppShell(),
    );
    final controller = this.controller;
    if (controller != null) {
      return ChangeNotifierProvider.value(value: controller, child: app);
    }
    return ChangeNotifierProvider(
      create: (_) => RecorderController(),
      child: app,
    );
  }
}
