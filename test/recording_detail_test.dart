import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:koe/ai/apple_speech.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/recording_navigation.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:koe/ui/shell.dart';
import 'package:koe/ui/widgets/inline_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  const previewDirectory = String.fromEnvironment('RECORDING_PREVIEW_DIR');
  final previewBoundary = GlobalKey();
  Future<void> savePreview(WidgetTester tester, String name) async {
    if (previewDirectory.isEmpty) return;
    await tester.runAsync(() async {
      final boundary =
          previewBoundary.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(previewDirectory).create(recursive: true);
      await File(
        '$previewDirectory/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  setUpAll(() async {
    if (previewDirectory.isEmpty) return;
    const fontPath = String.fromEnvironment(
      'RECORDING_PREVIEW_FONT',
      defaultValue: '/System/Library/Fonts/STHeiti Light.ttc',
    );
    for (final family in ['RecordingPreview', 'Roboto', 'Ahem']) {
      final loader = FontLoader(family);
      loader.addFont(
        File(
          fontPath,
        ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  Future<void> pump(
    WidgetTester tester,
    RecorderController controller,
    Widget child, {
    Size size = const Size(390, 844),
    double scale = 1,
    EdgeInsets safeInsets = EdgeInsets.zero,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: MaterialApp(
          theme: previewDirectory.isEmpty
              ? AppTheme.light
              : AppTheme.light.copyWith(
                  textTheme: AppTheme.light.textTheme.apply(
                    fontFamily: 'RecordingPreview',
                  ),
                  primaryTextTheme: AppTheme.light.primaryTextTheme.apply(
                    fontFamily: 'RecordingPreview',
                  ),
                  filledButtonTheme: FilledButtonThemeData(
                    style: AppTheme.light.filledButtonTheme.style!.copyWith(
                      textStyle: const WidgetStatePropertyAll(
                        TextStyle(fontFamily: 'RecordingPreview', fontSize: 14),
                      ),
                    ),
                  ),
                  segmentedButtonTheme: SegmentedButtonThemeData(
                    style: AppTheme.light.segmentedButtonTheme.style!.copyWith(
                      textStyle: const WidgetStatePropertyAll(
                        TextStyle(fontFamily: 'RecordingPreview', fontSize: 14),
                      ),
                    ),
                  ),
                  dialogTheme: AppTheme.light.dialogTheme.copyWith(
                    titleTextStyle: const TextStyle(
                      fontFamily: 'RecordingPreview',
                      color: AppColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
          builder: (context, child) => RepaintBoundary(
            key: previewBoundary,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                padding: safeInsets,
                viewPadding: safeInsets,
              ),
              child: child!,
            ),
          ),
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder readerScroll(String key) => find
      .descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Scrollable),
      )
      .first;

  testWidgets('Koe about is readable in the phone preview', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'legacy name',
      packageName: 'legacy.identity',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final c = _RecordingController();
    addTearDown(c.dispose);
    await pump(tester, c, const SettingsScreen());
    await tester.scrollUntilVisible(
      find.text('关于 Koe'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('关于 Koe'));
    await tester.pumpAndSettle();
    expect(find.text('Koe'), findsOneWidget);
    expect(find.text('适配设备：安克录音豆（soundcore Work / D3200）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await savePreview(tester, 'koe-about-phone');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('detail playback stays above the iPhone gesture safe area', (
    tester,
  ) async {
    const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
    final c = _RecordingController()..exportedPaths = [reference.path!];
    c.views[reference.key] = const RecordingViewData(
      reference: reference,
      path: '/tmp/100.wav',
      title: '录音',
      text: 'Test recording',
    );
    addTearDown(c.dispose);
    const size = Size(393, 852);
    const safeInsets = EdgeInsets.only(top: 59, bottom: 34);
    await pump(tester, c, const AppShell(), size: size, safeInsets: safeInsets);
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('recording-row-${reference.path}')));
    await tester.pumpAndSettle();
    expect(
      tester.getBottomRight(find.byType(InlinePlayer)).dy,
      lessThanOrEqualTo(size.height - safeInsets.bottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long live text follows until user scrolls up, then Latest resumes',
    (tester) async {
      final c = _RecordingController();
      addTearDown(c.dispose);
      final text = ValueNotifier(
        List.generate(
          100,
          (i) => 'Paragraph $i: a sentence with enough text to read.',
        ).join('\n'),
      );
      addTearDown(text.dispose);
      await pump(
        tester,
        c,
        Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: text,
            builder: (_, value, _) => RecordingTextReader(
              key: const ValueKey('reader'),
              text: value,
              live: true,
            ),
          ),
        ),
      );
      final scroll = tester
          .state<ScrollableState>(readerScroll('reader'))
          .position;
      expect(scroll.extentAfter, lessThan(2));
      await tester.drag(
        find.byKey(const ValueKey('reader')),
        const Offset(0, 360),
      );
      await tester.pumpAndSettle();
      final previous = scroll.pixels;
      expect(find.text('最新内容'), findsOneWidget);
      text.value += '\nA new finalized paragraph';
      await tester.pumpAndSettle();
      expect(scroll.pixels, closeTo(previous, 1));
      await tester.tap(find.text('最新内容'));
      await tester.pumpAndSettle();
      expect(scroll.extentAfter, lessThan(2));
      expect(find.text('最新内容'), findsNothing);
    },
  );

  testWidgets('source and translation retain their own reading positions', (
    tester,
  ) async {
    const reference = RecordingReference(fileId: 100);
    final c = _RecordingController();
    c.views[reference.key] = RecordingViewData(
      reference: reference,
      title: 'Interview',
      path: '/tmp/100.wav',
      text: List.generate(90, (i) => 'Source paragraph $i').join('\n'),
      translation: RecordingTranslation(
        text: List.generate(90, (i) => '译文第 $i 段').join('\n'),
        sourceLanguage: 'en',
        targetLanguage: 'zh',
        provider: SttProvider.apple,
        sourceRevision: 1,
      ),
    );
    addTearDown(c.dispose);
    await pump(tester, c, const RecordingDetailScreen(reference: reference));
    await tester.drag(
      find.byKey(const ValueKey('source-reader')),
      const Offset(0, -320),
    );
    await tester.pumpAndSettle();
    final sourcePosition = tester
        .state<ScrollableState>(readerScroll('source-reader'))
        .position
        .pixels;
    await tester.tap(find.text('译文'));
    await tester.pumpAndSettle();
    final translationScroll = tester
        .state<ScrollableState>(readerScroll('translation-reader'))
        .position;
    expect(translationScroll.pixels, 0);
    await tester.drag(
      find.byKey(const ValueKey('translation-reader')),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    final translatedPosition = translationScroll.pixels;
    await tester.tap(find.text('原文'));
    await tester.pumpAndSettle();
    expect(
      tester
          .state<ScrollableState>(readerScroll('source-reader'))
          .position
          .pixels,
      sourcePosition,
    );
    await tester.tap(find.text('译文'));
    await tester.pumpAndSettle();
    expect(translationScroll.pixels, translatedPosition);
  });

  testWidgets(
    'live navigation opens once, permits Back, deduplicates shortcuts, and keeps paused detail',
    (tester) async {
      final c = _RecordingController();
      addTearDown(c.dispose);
      await pump(tester, c, const AppShell());
      c.start('first', 'First recording');
      await tester.pumpAndSettle();
      expect(find.byType(RecordingDetailScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(c.recording, isTrue);
      expect(
        find.byKey(const ValueKey('active-recording-bar')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      c.updateText('New words should not reopen detail');
      await tester.pumpAndSettle();
      expect(find.byType(RecordingDetailScreen), findsNothing);
      c.shortcut();
      await tester.pumpAndSettle();
      c.shortcut();
      await tester.pumpAndSettle();
      expect(
        find.byType(RecordingDetailScreen, skipOffstage: false),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('pause-recording')));
      await tester.pumpAndSettle();
      expect(c.recording, isFalse);
      expect(find.byType(RecordingDetailScreen), findsOneWidget);
      expect(find.text('New words should not reopen detail'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    },
  );

  testWidgets(
    'a shortcut without a current recording opens connection recovery on Home',
    (tester) async {
      final c = _RecordingController();
      addTearDown(c.dispose);
      await pump(tester, c, const AppShell());
      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      c.shortcut();
      await tester.pumpAndSettle();
      expect(find.text('未连接设备'), findsOneWidget);
      expect(find.byType(SettingsScreen), findsNothing);
    },
  );

  testWidgets('paused current detail offers continue without hiding its text', (
    tester,
  ) async {
    final c = _RecordingController()..connected = true;
    addTearDown(c.dispose);
    c.start('continuation', 'First section');
    final ref = c.currentRecordingReference!;
    c.recording = false;
    c.views[ref.key] = RecordingViewData(
      reference: ref,
      title: 'Current take',
      text: 'First section',
      paused: true,
    );
    await pump(tester, c, RecordingDetailScreen(reference: ref));
    expect(find.text('First section'), findsOneWidget);
    expect(find.byKey(const ValueKey('resume-recording')), findsOneWidget);
    expect(find.text('正在保存录音'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('resume-recording')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('an older detail keeps its own text across a newer session', (
    tester,
  ) async {
    final c = _RecordingController();
    addTearDown(c.dispose);
    await pump(tester, c, const AppShell());
    c.start('first', 'First recording');
    await tester.pumpAndSettle();
    await c.pauseRecord();
    c.start('second', 'Second recording');
    await tester.pumpAndSettle();
    expect(find.text('Second recording'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('First recording'), findsOneWidget);
    expect(find.text('Second recording'), findsNothing);
    expect(find.byKey(const ValueKey('active-recording-bar')), findsOneWidget);
  });

  testWidgets(
    'compact playback remains accessible outside its recording detail',
    (tester) async {
      final c = _RecordingController()
        ..playingPath = '/tmp/100.wav'
        ..isPlaying = true;
      c.views['file:100'] = const RecordingViewData(
        reference: RecordingReference(fileId: 100),
        path: '/tmp/100.wav',
        title: 'Playback recording',
        text: 'Saved transcript',
      );
      addTearDown(c.dispose);
      await pump(tester, c, const AppShell());
      expect(find.byKey(const ValueKey('compact-player')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('compact-player')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('compact-player')), findsNothing);
      expect(find.byTooltip('播放录音'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('compact-player')), findsOneWidget);
    },
  );

  testWidgets(
    'device-only transcript keeps download and readable text together',
    (tester) async {
      const reference = RecordingReference(fileId: 100);
      final c = _RecordingController();
      c.views[reference.key] = const RecordingViewData(
        reference: reference,
        title: 'Device recording',
        text: 'Saved transcript without local audio',
      );
      addTearDown(c.dispose);
      await pump(tester, c, const RecordingDetailScreen(reference: reference));
      expect(find.text('Saved transcript without local audio'), findsOneWidget);
      expect(find.text('连接设备'), findsOneWidget);
    },
  );

  testWidgets('live detail permits pause before audio identity arrives', (
    tester,
  ) async {
    const reference = RecordingReference(sessionId: 'awaiting-id');
    final c = _RecordingController()..recording = true;
    c.views[reference.key] = const RecordingViewData(
      reference: reference,
      title: '当前录音',
      text: '',
      live: true,
    );
    addTearDown(c.dispose);
    await pump(tester, c, const RecordingDetailScreen(reference: reference));
    expect(find.byKey(const ValueKey('pause-recording')), findsOneWidget);
  });

  testWidgets(
    'live translation opens on translated text and preserves the reader choice',
    (tester) async {
      const reference = RecordingReference(sessionId: 'translated');
      final c = _RecordingController()..recording = true;
      c.views[reference.key] = const RecordingViewData(
        reference: reference,
        title: '翻译录音',
        text: 'Source words',
        live: true,
        mode: SttDisplayMode.translation,
        translation: RecordingTranslation(
          text: '译文内容',
          sourceLanguage: 'en',
          targetLanguage: 'zh',
          provider: SttProvider.apple,
          sourceRevision: 1,
        ),
      );
      addTearDown(c.dispose);
      await pump(tester, c, const RecordingDetailScreen(reference: reference));
      expect(find.byTooltip('复制译文'), findsOneWidget);
      await tester.tap(find.text('原文'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('复制原文'), findsOneWidget);
    },
  );

  testWidgets(
    'translation preserves an exact script and requires explicit download consent',
    (tester) async {
      const reference = RecordingReference(fileId: 100);
      final c = _RecordingController();
      c.views[reference.key] = const RecordingViewData(
        reference: reference,
        title: '中文录音',
        text: '繁體中文',
        path: '/tmp/100.wav',
        sourceLanguage: 'zh-Hant',
      );
      c.translationTargetLanguage = 'en-US';
      addTearDown(c.dispose);
      await pump(tester, c, const RecordingDetailScreen(reference: reference));
      await tester.tap(find.text('翻译'));
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<DropdownButton<String>>(
            find.byType(DropdownButton<String>),
          )
          .toList();
      expect(fields.first.value, 'zh-Hant');
      expect(c.preparedTranslation, isNull);
      await tester.tap(find.widgetWithText(FilledButton, '下载并翻译'));
      await tester.pumpAndSettle();
      expect(c.preparedTranslation, ('zh-Hant', 'en-US'));
    },
  );

  for (final size in [const Size(320, 740), const Size(1024, 900)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'provider settings show only supported controls $size $scale',
        (tester) async {
          final c = _RecordingController();
          addTearDown(c.dispose);
          await pump(
            tester,
            c,
            const SettingsScreen(),
            size: size,
            scale: scale,
          );
          expect(find.text('交流'), findsNothing);
          c.setSpeechProvider(SttProvider.doubao);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('apikey-doubao')), findsOneWidget);
          expect(find.text('连接录音时实时转写，取回独立录音后自动处理'), findsOneWidget);
          expect(find.text('实时模式'), findsNothing);
          expect(find.text('语言提示'), findsOneWidget);
          expect(find.text('交流'), findsNothing);
          expect(find.text('Soniox API Key'), findsNothing);
          await savePreview(
            tester,
            'doubao-settings-${size.width.toInt()}-$scale',
          );
          await tester.ensureVisible(find.text('保存'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          c.setSpeechProvider(SttProvider.apple);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('apikey-doubao')), findsNothing);
          final mode = tester.widget<SegmentedButton<SttDisplayMode>>(
            find.byKey(const ValueKey('stt-display-mode-selector')),
          );
          expect(mode.segments.map((s) => s.value), [
            SttDisplayMode.transcription,
            SttDisplayMode.translation,
          ]);
          expect(find.text('交流'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final size in [const Size(320, 740), const Size(1024, 900)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('detail and Apple setup fit $size at text scale $scale', (
        tester,
      ) async {
        const reference = RecordingReference(fileId: 100);
        final c = _RecordingController();
        c.views[reference.key] = const RecordingViewData(
          reference: reference,
          path: '/tmp/100.wav',
          title: 'A long recording title that stays within the toolbar',
          text: 'A long transcript\nSecond paragraph',
          translation: RecordingTranslation(
            text: '一段很长的转写文本\n第二段',
            sourceLanguage: 'en',
            targetLanguage: 'zh',
            provider: SttProvider.apple,
            sourceRevision: 1,
          ),
        );
        addTearDown(c.dispose);
        await pump(
          tester,
          c,
          const RecordingDetailScreen(reference: reference),
          size: size,
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        c.setSpeechProvider(SttProvider.apple);
        await pump(tester, c, const SettingsScreen(), size: size, scale: scale);
        expect(find.text('原文语言'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const ValueKey('prepare-apple-languages')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('prepare-apple-languages')));
        await tester.pumpAndSettle();
        expect(c.languagePreparationCalls, 1);
        await tester.ensureVisible(
          find.byKey(const ValueKey('stt-display-mode-selector')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
  _RecordingController appleRecording({
    String text = '',
    String? sourceLanguage,
  }) {
    final c = _RecordingController()..globallyConfigured = false;
    c.setSpeechProvider(SttProvider.apple);
    c.appleSourceLanguage = 'en-US';
    const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
    c.views[reference.key] = RecordingViewData(
      reference: reference,
      title: '录音',
      path: reference.path,
      text: text,
      sourceLanguage: sourceLanguage,
      provider: SttProvider.apple,
    );
    addTearDown(c.dispose);
    return c;
  }

  DropdownButton<String> languageDropdown(
    WidgetTester tester, {
    bool retranscribing = false,
  }) => tester.widget<DropdownButton<String>>(
    find.descendant(
      of: find.byKey(
        ValueKey(
          'recording-language-${retranscribing ? 'retranscribe' : 'transcribe'}',
        ),
      ),
      matching: find.byType(DropdownButton<String>),
    ),
  );

  testWidgets(
    'Apple file transcription requires recording language and ignores global English',
    (tester) async {
      final c = appleRecording();
      const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
      await pump(tester, c, const RecordingDetailScreen(reference: reference));
      expect(languageDropdown(tester).value, isNull);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('apple-transcribe')),
            )
            .onPressed,
        isNull,
      );
      expect(c.languageChecks, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('recording-language-transcribe')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('简体中文').last);
      await tester.pumpAndSettle();
      expect(languageDropdown(tester).value, 'zh-CN');
      expect(c.languageChecks, ['zh-CN']);
      await tester.tap(find.byKey(const ValueKey('apple-transcribe')));
      await tester.pumpAndSettle();
      expect(c.transcriptionRequests, [('zh-CN', false)]);
      expect(c.appleSourceLanguage, 'en-US');
      expect(c.globallyConfigured, isFalse);
    },
  );

  testWidgets(
    'Apple download is explicit and a failed attempt keeps the chosen language',
    (tester) async {
      final c = appleRecording()..transcriptionFailure = '转写未完成，请重试';
      c.languageStatuses['zh-CN'] = SpeechResourceStatus.needsDownload;
      const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
      await pump(tester, c, const RecordingDetailScreen(reference: reference));
      languageDropdown(tester).onChanged!('zh-CN');
      await tester.pumpAndSettle();
      expect(find.text('下载语言并转写'), findsOneWidget);
      expect(c.transcriptionRequests, isEmpty);
      await tester.tap(find.text('下载语言并转写'));
      await tester.pumpAndSettle();
      expect(c.transcriptionRequests, [('zh-CN', true)]);
      expect(languageDropdown(tester).value, 'zh-CN');
      expect(find.text('转写未完成，请重试'), findsOneWidget);
      expect(find.text('转写录音'), findsOneWidget);
      expect(c.languageChecks, ['zh-CN', 'zh-CN']);
    },
  );

  testWidgets('Apple recording language ignores stale availability responses', (
    tester,
  ) async {
    final c = appleRecording();
    final english = Completer<SpeechResourceStatus>();
    final chinese = Completer<SpeechResourceStatus>();
    c.languageStatusResolvers['en-US'] = () => english.future;
    c.languageStatusResolvers['zh-CN'] = () => chinese.future;
    const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
    await pump(tester, c, const RecordingDetailScreen(reference: reference));
    languageDropdown(tester).onChanged!('en-US');
    await tester.pump();
    languageDropdown(tester).onChanged!('zh-CN');
    await tester.pump();
    expect(find.text('正在检查语言…'), findsOneWidget);
    chinese.complete(SpeechResourceStatus.ready);
    await tester.pumpAndSettle();
    english.complete(SpeechResourceStatus.unsupported);
    await tester.pumpAndSettle();
    expect(languageDropdown(tester).value, 'zh-CN');
    expect(find.text('不支持此录音语言，请选择其他语言'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('apple-transcribe')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'Apple recording language check can retry without changing settings',
    (tester) async {
      final c = appleRecording();
      c.languageStatusResolvers['zh-CN'] = () =>
          Future.error(StateError('check failed'));
      const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
      await pump(tester, c, const RecordingDetailScreen(reference: reference));
      languageDropdown(tester).onChanged!('zh-CN');
      await tester.pumpAndSettle();
      expect(find.text('无法检查语言，请重试'), findsOneWidget);
      c.languageStatusResolvers.remove('zh-CN');
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('无法检查语言，请重试'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('apple-transcribe')),
            )
            .onPressed,
        isNotNull,
      );
      expect(c.appleSourceLanguage, 'en-US');
    },
  );

  testWidgets(
    'Apple transcription rejects unsupported languages and disables during other work',
    (tester) async {
      final c = appleRecording(sourceLanguage: 'zh-CN');
      c.languageStatuses['zh-CN'] = SpeechResourceStatus.unsupported;
      const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
      await pump(tester, c, const RecordingDetailScreen(reference: reference));
      expect(find.text('不支持此录音语言，请选择其他语言'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('apple-transcribe')),
            )
            .onPressed,
        isNull,
      );
      languageDropdown(tester).onChanged!('en-US');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('apple-transcribe')),
            )
            .onPressed,
        isNotNull,
      );
      c.setProcessingBusy(true);
      await tester.pumpAndSettle();
      expect(languageDropdown(tester).onChanged, isNull);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('apple-transcribe')),
            )
            .onPressed,
        isNull,
      );
      expect(c.transcriptionRequests, isEmpty);
    },
  );

  testWidgets(
    'Apple preselection requires an exact supported recording locale',
    (tester) async {
      const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
      final unknown = appleRecording(sourceLanguage: 'zh');
      await pump(
        tester,
        unknown,
        const RecordingDetailScreen(reference: reference),
      );
      expect(languageDropdown(tester).value, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      final known = appleRecording(sourceLanguage: 'ZH_cn');
      await pump(
        tester,
        known,
        const RecordingDetailScreen(reference: reference),
      );
      expect(languageDropdown(tester).value, 'zh-CN');
      expect(known.languageChecks, ['zh-CN']);
    },
  );

  testWidgets(
    'Apple retranscription lets the user change language before confirming',
    (tester) async {
      final c = appleRecording(text: '已有转写文本', sourceLanguage: 'en-US')
        ..transcriptionFailure = '转写未完成，请重试';
      const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
      await pump(tester, c, const RecordingDetailScreen(reference: reference));
      expect(find.text('录音语言'), findsNothing);
      Future<void> openDialog() async {
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('重新转写'));
        await tester.pumpAndSettle();
      }

      await openDialog();
      expect(languageDropdown(tester, retranscribing: true).value, 'en-US');
      languageDropdown(tester, retranscribing: true).onChanged!('zh-CN');
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.transcriptionRequests, isEmpty);
      expect(c.recordingView(reference).text, '已有转写文本');
      await openDialog();
      expect(languageDropdown(tester, retranscribing: true).value, 'zh-CN');
      await tester.tap(find.byKey(const ValueKey('apple-retranscribe')));
      await tester.pumpAndSettle();
      expect(c.transcriptionRequests, [('zh-CN', false)]);
      expect(c.recordingView(reference).text, '已有转写文本');
      await openDialog();
      expect(languageDropdown(tester, retranscribing: true).value, 'zh-CN');
    },
  );

  testWidgets(
    'Apple recording language form and retranscription dialog fit 200% text',
    (tester) async {
      const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
      final c = appleRecording(sourceLanguage: 'zh-CN');
      c.languageStatuses['zh-CN'] = SpeechResourceStatus.needsDownload;
      await pump(
        tester,
        c,
        const RecordingDetailScreen(reference: reference),
        size: const Size(320, 740),
        scale: 2,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('apple-transcribe')),
      );
      await tester.pumpAndSettle();
      expect(find.text('下载语言并转写'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      final saved = appleRecording(text: '已有文本', sourceLanguage: 'zh-CN');
      saved.languageStatuses['zh-CN'] = SpeechResourceStatus.needsDownload;
      await pump(
        tester,
        saved,
        const RecordingDetailScreen(reference: reference),
        size: const Size(320, 740),
        scale: 2,
      );
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新转写'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('apple-retranscribe')),
      );
      await tester.pumpAndSettle();
      expect(languageDropdown(tester, retranscribing: true).value, 'zh-CN');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop keeps library beside reader and returns to the selected recording',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final c = _RecordingController();
      addTearDown(c.dispose);
      for (final id in [100, 101]) {
        final ref = RecordingReference(fileId: id, path: '/tmp/$id.wav');
        c.exportedPaths.add(ref.path!);
        c.views[ref.key] = RecordingViewData(
          reference: ref,
          path: ref.path,
          title: 'Recording $id',
          text: 'Transcript $id',
        );
      }
      await pump(tester, c, const AppShell(), size: const Size(1280, 900));
      expect(find.byKey(const ValueKey('desktop-navigation')), findsOneWidget);
      expect(find.byKey(const ValueKey('bottom-navigation-bar')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('recording-row-/tmp/100.wav')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Transcript 100'), findsWidgets);
      expect(find.bySemanticsLabel('录音库'), findsWidgets);
      expect(
        find.byKey(const ValueKey('recording-row-/tmp/101.wav')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('recording-row-/tmp/101.wav')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(RecordingDetailScreen, skipOffstage: false),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(RecordingDetailScreen), findsNothing);
      tester.view.physicalSize = const Size(1280, 900);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-home')));
      await tester.pumpAndSettle();
      expect(find.byType(RecordingDetailScreen), findsOneWidget);
      expect(
        tester
            .widget<RecordingDetailScreen>(find.byType(RecordingDetailScreen))
            .reference
            .fileId,
        101,
      );
      // Resize the same navigator; retain the detail and recover normal Back.
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(find.byType(RecordingDetailScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('bottom-navigation-bar')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('nav-library')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recording-row-/tmp/101.wav')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'desktop live session stays accessible from settings without duplicate detail',
    (tester) async {
      final c = _RecordingController();
      addTearDown(c.dispose);
      await pump(tester, c, const AppShell(), size: const Size(1280, 900));
      c.start('desktop-live', 'Live text');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('active-recording-bar')),
        findsOneWidget,
      );
      c.updateText('More live text');
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      c.shortcut();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('active-recording-bar')), findsNothing);
      expect(
        find.byType(RecordingDetailScreen, skipOffstage: false),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('pause-recording')));
      await tester.pumpAndSettle();
      expect(c.recording, isFalse);
      expect(find.byType(RecordingDetailScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  if (previewDirectory.isNotEmpty) {
    testWidgets('render recording UI previews', (tester) async {
      final c = _RecordingController();
      addTearDown(c.dispose);
      const paragraphs = [
        '今天的讨论先回顾了用户访谈。大家希望录音结束后，能快速找到重点，也能完整阅读较长的转写。',
        '我们决定把录音列表与阅读分开。首页保留清晰的标题和简短预览，点进录音后，再展开原文、译文和播放控制。',
        '接下来会在通勤、会议和面对面交流时试用。阅读旧内容时，新文字不会把页面拉回底部。需要跟上实时内容时，再点“最新内容”。',
        '语言下载完成后，可以在支持的 iPhone 上使用设备端转写与翻译。每段录音保留开始时选定的语言。',
      ];
      for (var i = 0; i < 8; i++) {
        final path = '/tmp/${1783917051 + i}_访谈记录.wav';
        final reference = RecordingReference(
          fileId: 1783917051 + i,
          path: path,
        );
        c.exportedPaths.add(path);
        c.views[reference.key] = RecordingViewData(
          reference: reference,
          path: path,
          title: ['产品讨论', '访谈记录', '本周计划'][i % 3],
          text: paragraphs.join('\n\n'),
          sourceLanguage: 'zh-CN',
          translation: const RecordingTranslation(
            text:
                'We reviewed the interviews and agreed to separate the recording library from the reading experience.',
            sourceLanguage: 'zh-CN',
            targetLanguage: 'en-US',
            provider: SttProvider.apple,
            sourceRevision: 1,
          ),
        );
      }
      for (final variant in [
        ('phone', const Size(390, 844), 1.0),
        ('wide', const Size(1280, 900), 1.0),
        ('large-text', const Size(320, 740), 2.0),
      ]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await pump(
          tester,
          c,
          const AppShell(),
          size: variant.$2,
          scale: variant.$3,
        );
        await savePreview(tester, 'home-${variant.$1}');
        await tester.longPress(
          find.byKey(ValueKey('recording-row-${c.exportedPaths.first}')),
        );
        await tester.pumpAndSettle();
        await savePreview(tester, 'home-selection-${variant.$1}');
        await tester.tap(find.byTooltip('取消选择'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(ValueKey('recording-row-${c.exportedPaths.first}')),
        );
        await tester.pumpAndSettle();
        await savePreview(tester, 'detail-${variant.$1}');
        expect(tester.takeException(), isNull);
      }
      const shortReference = RecordingReference(
        fileId: 129,
        path: '/tmp/129.wav',
      );
      c.views[shortReference.key] = const RecordingViewData(
        reference: shortReference,
        path: '/tmp/129.wav',
        title: '2026/09/11 19:34',
        text:
            'The profile app launched successfully on iRocky and reconnected to this device.',
      );
      c.exportedPaths.insert(0, shortReference.path!);
      await tester.pumpWidget(const SizedBox.shrink());
      await pump(
        tester,
        c,
        const AppShell(),
        size: const Size(393, 852),
        safeInsets: const EdgeInsets.only(top: 59, bottom: 34),
      );
      await tester.tap(
        find.byKey(ValueKey('recording-row-${shortReference.path}')),
      );
      await tester.pumpAndSettle();
      await savePreview(tester, 'detail-short-source');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await pump(
        tester,
        c,
        const AppShell(),
        size: const Size(320, 740),
        scale: 2,
      );
      await tester.tap(
        find.byKey(ValueKey('recording-row-${c.exportedPaths.first}')),
      );
      await tester.pumpAndSettle();
      c.playingPath = c.exportedPaths[1];
      c.isPlaying = true;
      c.start('current-live', '现在开始一段新的录音。');
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await savePreview(tester, 'detail-live-player-large-text');
      final previous = c.views['file:1783917051']!;
      c.views['file:1783917051'] = RecordingViewData(
        reference: previous.reference,
        path: previous.path,
        title: previous.title,
        text: previous.text,
        translation: previous.translation,
        processing: true,
        error: '上次翻译未完成，原文已保留。语言准备完成后，可重新尝试翻译。',
      );
      c.updateText('现在开始一段新的录音。');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await savePreview(tester, 'detail-processing-large-text');

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.recording = false;
      c.setSpeechProvider(SttProvider.apple);
      await pump(
        tester,
        c,
        const SettingsScreen(),
        size: const Size(320, 740),
        scale: 2,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('prepare-apple-languages')),
      );
      await tester.pumpAndSettle();
      await savePreview(tester, 'apple-settings-large-text');
      await tester.pumpWidget(const SizedBox.shrink());
      const manualRef = RecordingReference(fileId: 100, path: '/tmp/100.wav');
      c.views[manualRef.key] = const RecordingViewData(
        reference: manualRef,
        title: '访谈录音',
        path: '/tmp/100.wav',
        text: '',
      );
      await pump(tester, c, const RecordingDetailScreen(reference: manualRef));
      languageDropdown(tester).onChanged!('zh-CN');
      await tester.pumpAndSettle();
      await savePreview(tester, 'apple-recording-language-phone');
      await tester.pumpWidget(const SizedBox.shrink());
      c.views[manualRef.key] = const RecordingViewData(
        reference: manualRef,
        title: '访谈录音',
        path: '/tmp/100.wav',
        text: '已有的转写文本会保留，直到新的转写完成。',
        sourceLanguage: 'zh-CN',
      );
      await pump(tester, c, const RecordingDetailScreen(reference: manualRef));
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新转写'));
      await tester.pumpAndSettle();
      await savePreview(tester, 'apple-retranscription-language-phone');

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tapping a sentence plays the original from its timecode', (
    tester,
  ) async {
    const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
    const segments = [
      TranscriptSegment(
        text: '第一句',
        start: Duration.zero,
        end: Duration(seconds: 5),
        speaker: '1',
        speakerChanged: true,
      ),
      TranscriptSegment(
        text: '第二句',
        start: Duration(seconds: 12),
        end: Duration(seconds: 20),
        speaker: '1',
      ),
      TranscriptSegment(
        text: '第三句',
        start: Duration(seconds: 25),
        end: Duration(seconds: 31),
        speaker: '2',
        speakerChanged: true,
      ),
    ];
    final c = _RecordingController();
    c.views[reference.key] = const RecordingViewData(
      reference: reference,
      title: '访谈录音',
      path: '/tmp/100.wav',
      text: '第一句第二句第三句',
      segments: segments,
    );
    addTearDown(c.dispose);
    await pump(tester, c, const RecordingDetailScreen(reference: reference));

    expect(find.text('说话人 1：第一句'), findsOneWidget);
    expect(find.text('说话人 2：第三句'), findsOneWidget);
    String segmentTime(int index) =>
        tester.widget<Text>(find.byKey(ValueKey('segment-time-$index'))).data!;
    expect(segmentTime(0), '00:00');
    expect(segmentTime(1), '00:12');
    expect(segmentTime(2), '00:25');

    await tester.tap(
      find
          .ancestor(
            of: find.byKey(const ValueKey('segment-1')),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(c.playbackRequests, [
      ('/tmp/100.wav', const Duration(seconds: 12), 100),
    ]);
  });

  testWidgets('chapter list starts playback at a timed segment', (
    tester,
  ) async {
    const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
    const segments = [
      TranscriptSegment(
        text: '第一句',
        start: Duration.zero,
        end: Duration(seconds: 5),
        speaker: '1',
        speakerChanged: true,
      ),
      TranscriptSegment(
        text: '第二句',
        start: Duration(seconds: 12),
        end: Duration(seconds: 20),
        speaker: '1',
      ),
      TranscriptSegment(
        text: '第三句',
        start: Duration(seconds: 25),
        end: Duration(seconds: 31),
        speaker: '2',
        speakerChanged: true,
      ),
    ];
    final c = _RecordingController();
    c.views[reference.key] = const RecordingViewData(
      reference: reference,
      title: '访谈录音',
      path: '/tmp/100.wav',
      text: '第一句第二句第三句',
      segments: segments,
    );
    addTearDown(c.dispose);
    await pump(tester, c, const RecordingDetailScreen(reference: reference));

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('章节'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chapter-2')), findsOneWidget);
    expect(find.text('第三句'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('chapter-2')));
    await tester.pumpAndSettle();

    expect(c.playbackRequests.last, (
      '/tmp/100.wav',
      const Duration(seconds: 25),
      100,
    ));
    expect(find.byKey(const ValueKey('highlighted-segment-2')), findsOneWidget);
  });

  testWidgets('chapter action is hidden without reliable timecodes', (
    tester,
  ) async {
    const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
    final c = _RecordingController();
    c.views[reference.key] = const RecordingViewData(
      reference: reference,
      title: '没有时码',
      path: '/tmp/100.wav',
      text: '第一句第二句',
      segments: [
        TranscriptSegment(
          text: '第一句',
          start: Duration.zero,
          end: Duration(seconds: 5),
        ),
        TranscriptSegment(
          text: '第二句',
          start: Duration.zero,
          end: Duration(seconds: 9),
        ),
      ],
    );
    addTearDown(c.dispose);
    await pump(tester, c, const RecordingDetailScreen(reference: reference));

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('章节'), findsNothing);
  });

  testWidgets('focused source opening restores and starts its position', (
    tester,
  ) async {
    const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
    const segments = [
      TranscriptSegment(
        text: '第一句',
        start: Duration.zero,
        end: Duration(seconds: 5),
      ),
      TranscriptSegment(
        text: '第二句',
        start: Duration(seconds: 12),
        end: Duration(seconds: 20),
      ),
    ];
    final c = _RecordingController();
    c.views[reference.key] = const RecordingViewData(
      reference: reference,
      title: '来源回跳',
      path: '/tmp/100.wav',
      text: '第一句第二句',
      segments: segments,
    );
    addTearDown(c.dispose);
    await pump(
      tester,
      c,
      const RecordingDetailScreen(
        reference: reference,
        initialHighlightedParagraph: 1,
        initialPlaybackStart: Duration(seconds: 12),
      ),
    );
    await tester.pumpAndSettle();

    expect(c.playbackRequests, [
      ('/tmp/100.wav', const Duration(seconds: 12), 100),
    ]);
    expect(find.byKey(const ValueKey('highlighted-segment-1')), findsOneWidget);
  });

  testWidgets('focused source has a back control on wide layouts', (
    tester,
  ) async {
    const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
    final c = _RecordingController();
    c.views[reference.key] = const RecordingViewData(
      reference: reference,
      title: '来源回跳',
      path: '/tmp/100.wav',
      text: '第一句第二句',
      segments: [
        TranscriptSegment(
          text: '第一句',
          start: Duration.zero,
          end: Duration(seconds: 5),
        ),
        TranscriptSegment(
          text: '第二句',
          start: Duration(seconds: 12),
          end: Duration(seconds: 20),
        ),
      ],
    );
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: MaterialApp(
          theme: AppTheme.light,
          home: RecordingNavigation(
            wide: true,
            onOpen: (_, {initialParagraph}) {},
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const RecordingDetailScreen(
                        reference: reference,
                        focusedSource: true,
                      ),
                    ),
                  ),
                  child: const Text('打开来源'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开来源'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回纪要'), findsOneWidget);

    await tester.tap(find.byTooltip('返回纪要'));
    await tester.pumpAndSettle();
    expect(find.text('打开来源'), findsOneWidget);
  });

  testWidgets('sentence highlight follows audio and yields to manual scroll', (
    tester,
  ) async {
    const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
    final segments = List.generate(
      60,
      (index) => TranscriptSegment(
        text: '第 $index 段，这是一句足够长的转写内容，用来形成可滚动的正文。',
        start: Duration(seconds: index * 10),
        end: Duration(seconds: index * 10 + 8),
      ),
    );
    final c = _RecordingController();
    c.views[reference.key] = RecordingViewData(
      reference: reference,
      title: '长录音',
      path: '/tmp/100.wav',
      text: segments.map((segment) => segment.text).join(),
      segments: segments,
    );
    addTearDown(c.dispose);
    await pump(tester, c, const RecordingDetailScreen(reference: reference));

    c.setPlayback('/tmp/100.wav', const Duration(seconds: 300));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('highlighted-segment-30')),
      findsOneWidget,
    );

    await tester.drag(
      find.byKey(const ValueKey('source-reader')),
      const Offset(0, 260),
    );
    await tester.pumpAndSettle();
    expect(find.text('回到播放位置'), findsOneWidget);

    c.setPlayback('/tmp/100.wav', const Duration(seconds: 410));
    await tester.pumpAndSettle();
    expect(find.text('回到播放位置'), findsOneWidget);

    await tester.tap(find.text('回到播放位置'));
    await tester.pumpAndSettle();
    expect(find.text('回到播放位置'), findsNothing);
  });

  testWidgets('scrolling timed text to the end does not resume following', (
    tester,
  ) async {
    const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
    final segments = List.generate(
      60,
      (index) => TranscriptSegment(
        text: '第 $index 段，这是一句足够长的转写内容，用来形成可滚动的正文。',
        start: Duration(seconds: index * 10),
        end: Duration(seconds: index * 10 + 8),
      ),
    );
    final c = _RecordingController();
    c.views[reference.key] = RecordingViewData(
      reference: reference,
      title: '长录音',
      path: '/tmp/100.wav',
      text: segments.map((segment) => segment.text).join(),
      segments: segments,
    );
    addTearDown(c.dispose);
    await pump(tester, c, const RecordingDetailScreen(reference: reference));

    c.setPlayback('/tmp/100.wav', const Duration(seconds: 300));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('source-reader')),
      const Offset(0, -20000),
    );
    await tester.pumpAndSettle();
    expect(find.text('回到播放位置'), findsOneWidget);

    c.setPlayback('/tmp/100.wav', const Duration(seconds: 410));
    await tester.pumpAndSettle();
    expect(find.text('回到播放位置'), findsOneWidget);
  });

  testWidgets(
    'untrusted timings never turn transcript text into seek targets',
    (tester) async {
      const reference = RecordingReference(fileId: 100, path: '/tmp/100.wav');
      final c = _RecordingController();
      c.views[reference.key] = const RecordingViewData(
        reference: reference,
        title: '校订后的录音',
        path: '/tmp/100.wav',
        text: '校订后的正文',
        segments: [
          TranscriptSegment(
            text: '旧的第一句',
            start: Duration.zero,
            end: Duration(seconds: 5),
          ),
          TranscriptSegment(
            text: '旧的第二句',
            start: Duration(seconds: 8),
            end: Duration(seconds: 12),
          ),
        ],
      );
      addTearDown(c.dispose);
      await pump(tester, c, const RecordingDetailScreen(reference: reference));

      expect(find.text('校订后的正文'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('unreliable-timing-notice')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('segment-0')), findsNothing);

      c.views[reference.key] = const RecordingViewData(
        reference: reference,
        title: '没有时码的录音',
        path: '/tmp/100.wav',
        text: '没有时码的正文',
      );
      c.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('missing-timing-notice')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('segment-0')), findsNothing);

      c.views[reference.key] = const RecordingViewData(
        reference: reference,
        title: '时码重复的录音',
        path: '/tmp/100.wav',
        text: '重复时码的正文',
        segments: [
          TranscriptSegment(
            text: '重复时码的',
            start: Duration.zero,
            end: Duration(seconds: 4),
          ),
          TranscriptSegment(
            text: '正文',
            start: Duration.zero,
            end: Duration(seconds: 8),
          ),
        ],
      );
      c.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('unreliable-timing-notice')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('segment-0')), findsNothing);
    },
  );

  testWidgets('missing original explains why replay is unavailable', (
    tester,
  ) async {
    const reference = RecordingReference(fileId: 100);
    final c = _RecordingController();
    c.views[reference.key] = const RecordingViewData(
      reference: reference,
      title: '只有文字',
      text: '原件不在本机的转写。',
      originalPresent: false,
    );
    addTearDown(c.dispose);
    await pump(tester, c, const RecordingDetailScreen(reference: reference));

    expect(find.text('只有文字'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('undownloaded-timing-notice')),
      findsOneWidget,
    );
    expect(find.text('录音尚未下载到本机；取回原音频后可回听，转写文字仍可阅读。'), findsOneWidget);
    expect(find.byType(InlinePlayer), findsNothing);

    c.views[reference.key] = const RecordingViewData(
      reference: RecordingReference(fileId: 100, path: '/tmp/100.wav'),
      title: '文件丢失',
      path: '/tmp/100.wav',
      text: '原件文件已经丢失的转写。',
      originalPresent: false,
    );
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('missing-file-timing-notice')),
      findsOneWidget,
    );
    expect(find.text('原录音文件已不在本机，无法回听；转写文字仍可阅读。'), findsOneWidget);
    expect(find.byType(InlinePlayer), findsNothing);
  });

  testWidgets('completed playback shows the end state and offers replay', (
    tester,
  ) async {
    final c = _RecordingController()
      ..playingPath = '/tmp/100.wav'
      ..duration = const Duration(seconds: 30)
      ..position = const Duration(seconds: 30)
      ..playbackCompleted = true;
    addTearDown(c.dispose);
    await pump(
      tester,
      c,
      const Scaffold(body: InlinePlayer(path: '/tmp/100.wav')),
    );

    expect(find.byKey(const ValueKey('playback-completed')), findsOneWidget);
    expect(find.byIcon(Icons.replay_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.replay_rounded));
    await tester.pumpAndSettle();
    expect(c.togglePlaybackCalls, 1);
    expect(find.byKey(const ValueKey('playback-completed')), findsNothing);
  });
}

class _RecordingController extends RecorderController {
  _RecordingController() : super(loadPersistedState: false);
  final views = <String, RecordingViewData>{};
  int languagePreparationCalls = 0;
  bool globallyConfigured = true;
  bool processingBusy = false;
  final languageChecks = <String>[];
  final languageStatuses = <String, SpeechResourceStatus>{};
  final languageStatusResolvers =
      <String, Future<SpeechResourceStatus> Function()>{};
  final transcriptionRequests = <(String?, bool)>[];
  final playbackRequests = <(String, Duration, int?)>[];
  int togglePlaybackCalls = 0;
  String? transcriptionFailure;
  (String, String)? preparedTranslation;
  RecordingReference? _current;
  @override
  RecordingReference? get currentRecordingReference => _current;
  @override
  bool get isLiveSession => recording;
  @override
  bool get fileProcessingBusy => recording || processingBusy;
  @override
  bool get sttConfigured => globallyConfigured;
  @override
  AppleSpeechCapabilities get appleCapabilities =>
      const AppleSpeechCapabilities(
        supported: true,
        speechStatus: SpeechResourceStatus.needsDownload,
        translationStatus: SpeechResourceStatus.needsDownload,
        speechLanguages: [
          SpeechLanguage(code: 'en-US', name: 'English (United States)'),
          SpeechLanguage(code: 'zh-CN', name: '简体中文'),
        ],
        translationLanguages: [
          SpeechLanguage(code: 'en-US', name: 'English (United States)'),
          SpeechLanguage(code: 'zh-Hans', name: '简体中文'),
          SpeechLanguage(code: 'zh-Hant', name: '繁體中文'),
        ],
      );
  @override
  RecordingViewData recordingView(RecordingReference reference) =>
      views[reference.key] ?? super.recordingView(reference);

  @override
  Future<void> playFrom(String path, Duration start, {int? fileId}) async {
    playbackRequests.add((path, start, fileId));
  }

  @override
  Future<void> playExported(
    String path, {
    int? fileId,
    Duration startAt = Duration.zero,
  }) async {
    if (playingPath == path) return togglePlayPause();
    playingPath = path;
    playingFileId = fileId;
    position = startAt;
    playbackCompleted = false;
    isPlaying = true;
    notifyListeners();
  }

  @override
  Future<void> togglePlayPause() async {
    togglePlaybackCalls++;
    playbackCompleted = false;
    position = Duration.zero;
    notifyListeners();
  }

  void setPlayback(String path, Duration at, {bool completed = false}) {
    playingPath = path;
    position = at;
    playbackCompleted = completed;
    notifyListeners();
  }

  void setProcessingBusy(bool value) {
    processingBusy = value;
    notifyListeners();
  }

  @override
  Future<SpeechResourceStatus> recordingSpeechStatus(
    String sourceLanguage,
  ) async {
    languageChecks.add(sourceLanguage);
    final resolver = languageStatusResolvers[sourceLanguage];
    if (resolver != null) return resolver();
    return languageStatuses[sourceLanguage] ?? SpeechResourceStatus.ready;
  }

  @override
  Future<void> transcribeRecording(
    RecordingReference reference, {
    String? sourceLanguage,
    bool prepareLanguages = false,
  }) async {
    transcriptionRequests.add((sourceLanguage, prepareLanguages));
    if (prepareLanguages && sourceLanguage != null) {
      languageStatuses[sourceLanguage] = SpeechResourceStatus.ready;
    }
    final previous = views[reference.key];
    if (previous != null && transcriptionFailure != null) {
      views[reference.key] = RecordingViewData(
        reference: previous.reference,
        title: previous.title,
        path: previous.path,
        text: previous.text,
        translation: previous.translation,
        sourceLanguage: previous.sourceLanguage,
        provider: previous.provider,
        error: transcriptionFailure,
      );
      notifyListeners();
    }
  }

  @override
  Future<void> prepareAppleLanguages() async {
    languagePreparationCalls++;
  }

  @override
  Future<void> prepareRecordingTranslation(
    RecordingReference ref, {
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    preparedTranslation = (sourceLanguage, targetLanguage);
  }

  @override
  Future<void> refreshFilesOnTabEnter() async {}
  @override
  Future<void> refreshInfoOnDeviceTabEnter() async {}
  void start(String id, String text) {
    _current = RecordingReference(sessionId: id);
    recording = true;
    liveSessionRevision++;
    updateText(text);
  }

  void updateText(String text) {
    final reference = _current!;
    views[reference.key] = RecordingViewData(
      reference: reference,
      title: '当前录音',
      text: text,
      live: recording,
      audioLocked: recording,
    );
    notifyListeners();
  }

  void shortcut() {
    shortcutNavigationRevision++;
    notifyListeners();
  }

  @override
  Future<void> pauseRecord() async {
    recording = false;
    final text = views[_current!.key]!.text;
    updateText(text);
  }
}
