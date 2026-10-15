import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../ai/apple_speech.dart';
import '../../ai/stt_types.dart';
import '../../state/export_catalog.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/inline_player.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/widgets.dart';

class RecordingDetailScreen extends StatefulWidget {
  const RecordingDetailScreen({super.key, required this.reference});

  final RecordingReference reference;

  @override
  State<RecordingDetailScreen> createState() => _RecordingDetailScreenState();
}

class _RecordingDetailScreenState extends State<RecordingDetailScreen> {
  bool _showTranslation = false;
  bool _selectionInitialized = false;
  String? _selectedRecordingLanguage;

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _share(RecordingViewData recording) async {
    final path = recording.path;
    if (path == null || recording.audioLocked) return;
    try {
      final paths = await context
          .read<RecorderController>()
          .prepareLocalSharePaths([path]);
      if (paths.isEmpty) throw StateError('录音文件不存在');
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: paths.map(XFile.new).toList(),
          title: recording.title,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (error) {
      _notice('无法分享，请重试');
    }
  }

  Future<void> _save(RecordingViewData recording) async {
    if (recording.audioLocked || recording.path == null) return;
    if (Platform.isIOS) return _share(recording);
    try {
      final destination = await getDirectoryPath(
        confirmButtonText: '保存',
        canCreateDirectories: true,
      );
      if (destination == null || !mounted) return;
      final result = await context.read<RecorderController>().saveLocalCopies([
        recording.path!,
      ], destination);
      _notice(
        result.failed.isEmpty
            ? '已保存录音${result.transcripts > 0 ? '和转写文本' : ''}'
            : '保存失败，请重试',
      );
    } catch (error) {
      _notice('无法保存，请重试');
    }
  }

  Future<void> _rename(RecordingViewData recording) async {
    final path = recording.path;
    if (path == null || recording.audioLocked) return;
    final label = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        title: '重命名录音',
        label: '录音名称',
        initialName: ExportCatalog.editableLabelFromPath(path),
        maxLength: 100,
        validate: (value) {
          ExportCatalog.renamedFileName(path, value);
          return value.trim();
        },
      ),
    );
    if (label == null || !mounted) return;
    try {
      await context.read<RecorderController>().renameLocalExport(path, label);
    } catch (error) {
      _notice('无法重命名，请检查名称后重试');
    }
  }

  Future<void> _transcribe(
    RecordingViewData recording, {
    String? sourceLanguage,
    bool prepareLanguages = false,
  }) async {
    final controller = context.read<RecorderController>();
    if (recording.audioLocked ||
        recording.processing ||
        controller.fileProcessingBusy) {
      return;
    }
    final apple = controller.speechProvider == SttProvider.apple;
    if (recording.text.isNotEmpty) {
      if (apple) {
        final choice = await showDialog<(String, bool)>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('重新转写？'),
            scrollable: true,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('成功后将替换当前文本、自定义说话人姓名和译文。失败时保留现有结果。'),
                const SizedBox(height: 20),
                _AppleTranscriptionForm(
                  reference: widget.reference,
                  initialLanguage:
                      _selectedRecordingLanguage ?? recording.sourceLanguage,
                  enabled: true,
                  retranscribing: true,
                  onLanguageChanged: (language) =>
                      _selectedRecordingLanguage = language,
                  onSubmit: (language, prepare) async =>
                      Navigator.pop(dialogContext, (language, prepare)),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
            ],
          ),
        );
        if (choice == null || !mounted) return;
        sourceLanguage = choice.$1;
        prepareLanguages = choice.$2;
      } else {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('重新转写？'),
            content: const Text('成功后将替换当前文本、自定义说话人姓名和译文。失败时保留现有结果。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('重新转写'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
      }
    }
    if (apple && sourceLanguage == null) return;
    await controller.transcribeRecording(
      widget.reference,
      sourceLanguage: apple ? sourceLanguage : null,
      prepareLanguages: apple && prepareLanguages,
    );
  }

  Future<void> _speakers(RecordingViewData recording) async {
    final path = recording.path;
    if (path == null || recording.audioLocked) return;
    final controller = context.read<RecorderController>();
    final tokens = KoeTokens.of(context);
    final speaker = await showModalBottomSheet<TranscriptSpeaker>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .65,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '说话人姓名',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: tokens.textPrimary,
                  ),
                ),
              ),
              for (final speaker in controller.transcriptSpeakersForPath(path))
                ListTile(
                  leading: IconBadge(
                    icon: Icons.person_outline_rounded,
                    size: 32,
                    iconSize: 16,
                    color: tokens.accent,
                    backgroundColor: tokens.accentSoft,
                    borderColor: tokens.accentBorder,
                  ),
                  title: Text(
                    speaker.displayLabel,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  trailing: Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: tokens.textSecondary,
                  ),
                  onTap: () => Navigator.pop(context, speaker),
                ),
            ],
          ),
        ),
      ),
    );
    if (speaker == null || !mounted) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        title: '重命名说话人',
        label: '说话人姓名',
        initialName: speaker.displayLabel,
        maxLength: 40,
        inputKey: const ValueKey('speaker-name-input'),
        validate: (value) {
          final name = value
              .trim()
              .replaceFirst(RegExp(r'[:：]\s*$'), '')
              .trimRight();
          if (name.isEmpty) throw ArgumentError('请输入说话人姓名');
          return name;
        },
      ),
    );
    if (name == null || !mounted) return;
    try {
      await controller.renameTranscriptSpeaker(path, speaker.id, name);
    } catch (error) {
      _notice('无法保存姓名，请重试');
    }
  }

  Future<void> _translate(RecordingViewData recording) async {
    final controller = context.read<RecorderController>();
    final languages = controller.appleCapabilities.translationLanguages;
    if (languages.isEmpty) {
      _notice('此设备不支持 Apple 翻译');
      return;
    }
    final pair = await showDialog<(String, String, bool)>(
      context: context,
      builder: (_) => _TranslationDialog(
        languages: languages,
        preparedSource:
            controller.appleCapabilities.translationStatus ==
                SpeechResourceStatus.ready
            ? controller.appleSourceLanguage
            : null,
        preparedTarget:
            controller.appleCapabilities.translationStatus ==
                SpeechResourceStatus.ready
            ? controller.translationTargetLanguage
            : null,
        source: recording.sourceLanguage ?? controller.appleSourceLanguage,
        target:
            recording.translation?.targetLanguage ??
            controller.translationTargetLanguage,
      ),
    );
    if (pair == null || !mounted) return;
    if (pair.$3) {
      await controller.prepareRecordingTranslation(
        widget.reference,
        sourceLanguage: pair.$1,
        targetLanguage: pair.$2,
      );
    } else {
      await controller.translateRecording(
        widget.reference,
        sourceLanguage: pair.$1,
        targetLanguage: pair.$2,
      );
    }
    if (mounted &&
        controller.recordingView(widget.reference).translation != null) {
      setState(() => _showTranslation = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final tokens = KoeTokens.of(context);
    final recording = c.recordingView(widget.reference);
    if (!_selectionInitialized) {
      _selectionInitialized = true;
      _showTranslation =
          recording.live && recording.mode == SttDisplayMode.translation;
    }
    final translated = recording.translation?.text ?? '';
    final hasTranslation = translated.isNotEmpty;
    final source = normalizeSttText(recording.text);
    final text = _showTranslation && hasTranslation ? translated : source;
    final fileReady = recording.path != null && !recording.audioLocked;
    final canProcess = fileReady && !c.fileProcessingBusy && !c.isLiveSession;
    final canOfferTranslation =
        source.isNotEmpty && !recording.live && c.appleCapabilities.supported;
    final hasReaderHeader =
        recording.processing ||
        recording.error != null ||
        (source.isEmpty && translated.isEmpty) ||
        (recording.path == null && !recording.live && !recording.audioLocked);
    final hasSpeakers =
        recording.path != null &&
        c.transcriptSpeakersForPath(recording.path!).isNotEmpty;

    final statusDotColor = recording.paused
        ? tokens.amber
        : recording.live
        ? tokens.coral
        : tokens.textMuted;

    return Scaffold(
      key: ValueKey('recording-detail-${widget.reference.key}'),
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bgCard,
        title: Text(
          recording.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        titleTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: tokens.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: tokens.borderSoft),
        ),
        actions: [
          IconButton(
            tooltip: '分享录音',
            onPressed: fileReady ? () => _share(recording) : null,
            icon: const Icon(Icons.ios_share_rounded, size: 20),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (action) {
              switch (action) {
                case 'rename':
                  _rename(recording);
                case 'save':
                  _save(recording);
                case 'transcribe':
                  _transcribe(recording);
                case 'speakers':
                  _speakers(recording);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'rename',
                enabled: fileReady,
                child: const Text('重命名'),
              ),
              PopupMenuItem(
                value: 'save',
                enabled: fileReady,
                child: const Text('保存录音'),
              ),
              if (source.isNotEmpty)
                PopupMenuItem(
                  value: 'transcribe',
                  enabled:
                      canProcess &&
                      (c.speechProvider == SttProvider.apple ||
                          c.sttConfigured),
                  child: const Text('重新转写'),
                ),
              if (hasSpeakers)
                PopupMenuItem(
                  value: 'speakers',
                  enabled: fileReady && !recording.processing,
                  child: const Text('说话人姓名'),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              color: tokens.bgCard,
              border: Border(bottom: BorderSide(color: tokens.borderSoft)),
            ),
            child: Align(
              alignment: Alignment.center,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      if (hasTranslation)
                        Expanded(
                          child: SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: false, label: Text('原文')),
                              ButtonSegment(value: true, label: Text('译文')),
                            ],
                            selected: {_showTranslation},
                            showSelectedIcon: false,
                            onSelectionChanged: (value) =>
                                setState(() => _showTranslation = value.first),
                          ),
                        )
                      else
                        Expanded(
                          child: Row(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: statusDotColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  recording.paused
                                      ? '已暂停'
                                      : recording.live
                                      ? (recording.provider == SttProvider.moss
                                            ? '录音中'
                                            : '实时转写')
                                      : '转写文本',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: tokens.textSecondary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (recording.processing) ...[
                        const SizedBox(width: 8),
                        Tooltip(
                          message: '正在处理',
                          child: SizedBox.square(
                            dimension: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tokens.accent,
                            ),
                          ),
                        ),
                      ],
                      if (canOfferTranslation) ...[
                        const SizedBox(width: 8),
                        if (hasTranslation)
                          IconButton(
                            tooltip: '翻译为其他语言',
                            onPressed: canProcess
                                ? () => _translate(recording)
                                : null,
                            icon: const Icon(Icons.translate_rounded, size: 19),
                          )
                        else
                          TextButton.icon(
                            onPressed: canProcess
                                ? () => _translate(recording)
                                : null,
                            icon: const Icon(Icons.translate_rounded, size: 17),
                            label: const Text('翻译'),
                          ),
                      ],
                      IconButton(
                        tooltip: _showTranslation && hasTranslation
                            ? '复制译文'
                            : '复制原文',
                        onPressed: text.isEmpty
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: text),
                                );
                                _notice(
                                  _showTranslation && hasTranslation
                                      ? '已复制译文'
                                      : '已复制原文',
                                );
                              },
                        icon: const Icon(Icons.copy_outlined, size: 19),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _showTranslation && hasTranslation ? 1 : 0,
              children: [
                for (final translation in [false, true])
                  RecordingTextReader(
                    key: ValueKey(
                      translation ? 'translation-reader' : 'source-reader',
                    ),
                    text: translation ? translated : source,
                    live: recording.live,
                    visible:
                        translation == (_showTranslation && hasTranslation),
                    header: !hasReaderHeader || (translation && !hasTranslation)
                        ? null
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (recording.processing)
                                _ProcessingStatus(progress: recording.progress),
                              if (recording.error != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: tokens.coralSoft,
                                      borderRadius: BorderRadius.circular(
                                        AppRadii.md,
                                      ),
                                      border: Border.all(
                                        color: tokens.coralBorder,
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 2,
                                          ),
                                          child: Icon(
                                            Icons.error_outline_rounded,
                                            size: 16,
                                            color: tokens.coral,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            recording.error!,
                                            style: TextStyle(
                                              color: tokens.coral,
                                              fontSize: 13,
                                              height: 1.4,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (source.isEmpty && translated.isEmpty)
                                _EmptyRecording(
                                  key: const ValueKey('empty-recording'),
                                  recording: recording,
                                  canTranscribe:
                                      canProcess &&
                                      (c.speechProvider == SttProvider.apple ||
                                          c.sttConfigured),
                                  configured: c.sttConfigured,
                                  onTranscribe: () => _transcribe(recording),
                                  appleForm:
                                      c.speechProvider == SttProvider.apple
                                      ? _AppleTranscriptionForm(
                                          reference: widget.reference,
                                          initialLanguage:
                                              _selectedRecordingLanguage ??
                                              recording.sourceLanguage,
                                          enabled: canProcess,
                                          onLanguageChanged: (language) =>
                                              _selectedRecordingLanguage =
                                                  language,
                                          onSubmit: (language, prepare) =>
                                              _transcribe(
                                                recording,
                                                sourceLanguage: language,
                                                prepareLanguages: prepare,
                                              ),
                                        )
                                      : null,
                                ),
                              if (recording.path == null &&
                                  !recording.live &&
                                  !recording.audioLocked)
                                _DeviceDownload(recording: recording),
                            ],
                          ),
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: recording.live || recording.audioLocked
          ? _LiveControls(recording: recording)
          : fileReady
          ? Material(
              color: tokens.bgCard,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Center(
                    heightFactor: 1,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: InlinePlayer(
                        path: recording.path!,
                        fileId: recording.reference.fileId,
                      ),
                    ),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

/// Paragraphs are created lazily, with independent source/translation positions.
class RecordingTextReader extends StatefulWidget {
  const RecordingTextReader({
    super.key,
    required this.text,
    required this.live,
    this.visible = true,
    this.header,
  });
  final String text;
  final bool live;
  final bool visible;
  final Widget? header;

  @override
  State<RecordingTextReader> createState() => _RecordingTextReaderState();
}

class _RecordingTextReaderState extends State<RecordingTextReader> {
  final _scroll = ScrollController();
  bool _following = true;
  late List<String> _paragraphs;

  @override
  void initState() {
    super.initState();
    _paragraphs = _split(widget.text);
    _follow();
  }

  static List<String> _split(String text) {
    final paragraphs = <String>[];
    for (final line in text.split(RegExp(r'\n+'))) {
      if (line.trim().isEmpty) continue;
      // Some services emit an entire recording as one line. Bound paragraph
      // size too, so a long unpunctuated transcript still lays out lazily.
      var runes = line.runes.toList();
      while (runes.length > 1200) {
        var end = 1200;
        for (var index = 1199; index > 800; index--) {
          if (' 。！？.!?'.runes.contains(runes[index])) {
            end = index + 1;
            break;
          }
        }
        paragraphs.add(String.fromCharCodes(runes.take(end)));
        runes = runes.sublist(end);
      }
      if (runes.isNotEmpty) paragraphs.add(String.fromCharCodes(runes));
    }
    return paragraphs;
  }

  @override
  void didUpdateWidget(RecordingTextReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _paragraphs = _split(widget.text);
      _follow();
    } else if (!oldWidget.visible && widget.visible) {
      _follow();
    }
  }

  void _follow([int remaining = 6]) {
    if (!widget.live || !widget.visible || !_following) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_following || !widget.visible) {
        return;
      }
      final target = _scroll.position.maxScrollExtent;
      if ((_scroll.offset - target).abs() < 1) return;
      _scroll.jumpTo(target);
      // Lazy variable-height paragraphs can refine their extent after a jump.
      if (remaining > 0) _follow(remaining - 1);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static TextSpan _buildParagraphSpan(String paragraph, KoeTokens tokens) {
    final speakerMatch = RegExp(r'^([^:：\n]{1,24}[：:])(.*)$').firstMatch(
      paragraph,
    );
    if (speakerMatch != null) {
      return TextSpan(
        children: [
          TextSpan(
            text: speakerMatch.group(1),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: tokens.accent,
            ),
          ),
          TextSpan(text: speakerMatch.group(2)),
        ],
      );
    }
    return TextSpan(text: paragraph);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Stack(
      children: [
        NotificationListener<UserScrollNotification>(
          onNotification: (notification) {
            if (notification.depth == 0 && widget.live && _scroll.hasClients) {
              final following =
                  notification.direction == ScrollDirection.forward
                  ? false
                  : _scroll.position.extentAfter < 96;
              if (_following != following) {
                setState(() => _following = following);
              }
            }
            return false;
          },
          child: Scrollbar(
            controller: _scroll,
            child: SelectionArea(
              child: ListView.builder(
                key: ValueKey('recording-text-scroll-${widget.key}'),
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(
                  20,
                  16,
                  20,
                  widget.live ? 84 : 24,
                ),
                itemCount: _paragraphs.length + (widget.header == null ? 0 : 1),
                itemBuilder: (context, index) {
                  final isHeader = widget.header != null && index == 0;
                  final isLast =
                      index ==
                      _paragraphs.length + (widget.header == null ? 0 : 1) - 1;
                  final paragraph = isHeader
                      ? ''
                      : _paragraphs[index - (widget.header == null ? 0 : 1)];
                  final hasSpeaker =
                      !isHeader &&
                      RegExp(r'^[^:：\n]{1,24}[：:]').hasMatch(paragraph);
                  return Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: SizedBox(
                        width: double.infinity,
                        child: Padding(
                          padding: EdgeInsets.only(
                            bottom: isHeader || isLast ? 0 : 16,
                          ),
                          child: isHeader
                              ? widget.header!
                              : DecoratedBox(
                                  decoration: hasSpeaker
                                      ? BoxDecoration(
                                          border: Border(
                                            left: BorderSide(
                                              color: tokens.accentBorder,
                                              width: 2.5,
                                            ),
                                          ),
                                        )
                                      : const BoxDecoration(),
                                  child: Padding(
                                    padding: EdgeInsets.only(
                                      left: hasSpeaker ? 12 : 0,
                                    ),
                                    child: Text.rich(
                                      _buildParagraphSpan(paragraph, tokens),
                                      style: TextStyle(
                                        fontSize: 17.5,
                                        height: 1.68,
                                        letterSpacing: -0.1,
                                        color: tokens.textPrimary,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        if (widget.live && !_following)
          Positioned(
            right: 20,
            bottom: 16,
            child: FilledButton.icon(
              key: const ValueKey('follow-latest'),
              style: FilledButton.styleFrom(
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              onPressed: () {
                setState(() => _following = true);
                _follow();
              },
              icon: const Icon(Icons.arrow_downward_rounded, size: 17),
              label: const Text('最新内容'),
            ),
          ),
      ],
    );
  }
}

class _LiveControls extends StatelessWidget {
  const _LiveControls({required this.recording});
  final RecordingViewData recording;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final tokens = KoeTokens.of(context);
    final isPaused = recording.live && recording.paused;
    final isRecording = recording.live && !recording.paused;
    final statusColor = isRecording
        ? tokens.coral
        : isPaused
        ? tokens.amber
        : tokens.accent;

    return Container(
      decoration: BoxDecoration(
        color: tokens.bgCard,
        border: Border(top: BorderSide(color: tokens.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  recording.live
                      ? (recording.paused ? '已暂停' : '录音中')
                      : '正在保存录音',
                  style: TextStyle(
                    color: tokens.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              if (recording.error != null)
                IconButton(
                  tooltip: '查看处理错误',
                  color: tokens.coral,
                  icon: const Icon(Icons.error_outline_rounded),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('处理未完成'),
                      scrollable: true,
                      content: Text(recording.error!),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (recording.live && c.recording)
                FilledButton.icon(
                  key: const ValueKey('pause-recording'),
                  style: FilledButton.styleFrom(
                    backgroundColor: tokens.coral,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(96, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                    ),
                  ),
                  onPressed: c.phase == AppPhase.busy ? null : c.pauseRecord,
                  icon: const Icon(Icons.pause_rounded, size: 19),
                  label: const Text('暂停'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyRecording extends StatelessWidget {
  const _EmptyRecording({
    super.key,
    required this.recording,
    required this.canTranscribe,
    required this.configured,
    required this.onTranscribe,
    this.appleForm,
  });
  final RecordingViewData recording;
  final bool canTranscribe;
  final bool configured;
  final VoidCallback onTranscribe;
  final Widget? appleForm;
  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final local = recording.path != null;
    final message = recording.processing
        ? '正在生成转写文本'
        : recording.live
        ? (!recording.transcriptionEnabled
              ? '自动转写已关闭'
              : !recording.speechReady
              ? (recording.provider == SttProvider.apple
                    ? '在设置中下载并准备语音语言'
                    : '请在设置中配置 ${recording.provider.label}')
              : recording.provider == SttProvider.moss
              ? '录音结束后生成文字'
              : '开始说话后，文字会显示在这里')
        : !local
        ? '下载录音后即可播放和转写'
        : !configured && appleForm == null
        ? '在设置中准备语音服务后即可转写'
        : '这段录音还没有转写文本';

    final icon = recording.processing
        ? Icons.hourglass_top_rounded
        : recording.live
        ? Icons.graphic_eq_rounded
        : !local
        ? Icons.cloud_download_outlined
        : Icons.subtitles_outlined;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconBadge(
            icon: icon,
            size: 44,
            iconSize: 22,
            radius: 12,
            color: recording.live ? tokens.accent : tokens.textSecondary,
            backgroundColor: recording.live
                ? tokens.accentSoft
                : tokens.bgPanel,
            borderColor: recording.live ? tokens.accentBorder : tokens.border,
          ),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w500,
              height: 1.5,
              color: tokens.textSecondary,
            ),
          ),
          if (local && !recording.live && appleForm != null) ...[
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: tokens.bgCard,
                  borderRadius: BorderRadius.circular(AppRadii.lg),
                  border: Border.all(color: tokens.border),
                  boxShadow: tokens.cardShadow,
                ),
                child: appleForm!,
              ),
            ),
          ] else if (local && !recording.live && !recording.processing) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(140, 46),
              ),
              onPressed: canTranscribe ? onTranscribe : null,
              icon: const Icon(Icons.subtitles_outlined, size: 18),
              label: const Text('转写录音'),
            ),
          ],
        ],
      ),
    );
  }
}

/// A manual recording choice is independent of the next-live-recording settings.
class _AppleTranscriptionForm extends StatefulWidget {
  const _AppleTranscriptionForm({
    required this.reference,
    required this.initialLanguage,
    required this.enabled,
    required this.onLanguageChanged,
    required this.onSubmit,
    this.retranscribing = false,
  });

  final RecordingReference reference;
  final String? initialLanguage;
  final bool enabled;
  final bool retranscribing;
  final ValueChanged<String> onLanguageChanged;
  final Future<void> Function(String language, bool prepareLanguages) onSubmit;

  @override
  State<_AppleTranscriptionForm> createState() =>
      _AppleTranscriptionFormState();
}

class _AppleTranscriptionFormState extends State<_AppleTranscriptionForm> {
  String? _language;
  SpeechResourceStatus? _status;
  bool _checking = false;
  bool _submitting = false;
  String? _error;
  int _requestRevision = 0;

  static String _normalized(String value) =>
      value.replaceAll('_', '-').toLowerCase();

  String? _supportedLanguage(String? code) {
    if (code == null) return null;
    final languages = context
        .read<RecorderController>()
        .appleCapabilities
        .speechLanguages;
    return languages
        .where((language) => _normalized(language.code) == _normalized(code))
        .firstOrNull
        ?.code;
  }

  @override
  void initState() {
    super.initState();
    _initializeLanguage();
  }

  @override
  void didUpdateWidget(_AppleTranscriptionForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_language == null) _initializeLanguage();
  }

  void _initializeLanguage() {
    final known = _supportedLanguage(widget.initialLanguage);
    if (known == null) return;
    _language = known;
    _checkLanguage();
  }

  Future<void> _checkLanguage() async {
    final language = _language;
    if (language == null) return;
    final revision = ++_requestRevision;
    setState(() {
      _checking = true;
      _status = null;
      _error = null;
    });
    try {
      final status = await context
          .read<RecorderController>()
          .recordingSpeechStatus(language);
      if (!mounted || revision != _requestRevision || language != _language) {
        return;
      }
      setState(() {
        _checking = false;
        _status = status;
      });
    } catch (_) {
      if (!mounted || revision != _requestRevision || language != _language) {
        return;
      }
      setState(() {
        _checking = false;
        _error = '无法检查语言，请重试';
      });
    }
  }

  void _selectLanguage(String language) {
    setState(() => _language = language);
    widget.onLanguageChanged(language);
    _checkLanguage();
  }

  Future<void> _submit() async {
    final language = _language;
    if (language == null ||
        _checking ||
        _submitting ||
        _status == null ||
        _status == SpeechResourceStatus.unsupported) {
      return;
    }
    final c = context.read<RecorderController>();
    if (!widget.enabled ||
        c.fileProcessingBusy ||
        c.recordingView(widget.reference).audioLocked ||
        c.speechProvider != SttProvider.apple) {
      return;
    }
    widget.onLanguageChanged(language);
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(
        language,
        _status == SpeechResourceStatus.needsDownload,
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
        if (!widget.retranscribing) await _checkLanguage();
      }
    }
  }

  @override
  void dispose() {
    _requestRevision++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final tokens = KoeTokens.of(context);
    final languages = c.appleCapabilities.speechLanguages;
    final selected = _supportedLanguage(_language);
    final enabled =
        widget.enabled &&
        !c.fileProcessingBusy &&
        !c.recordingView(widget.reference).audioLocked &&
        c.speechProvider == SttProvider.apple;
    final canSubmit =
        enabled &&
        selected != null &&
        !_checking &&
        !_submitting &&
        (_status == SpeechResourceStatus.ready ||
            _status == SpeechResourceStatus.needsDownload);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        KeyedSubtree(
          key: ValueKey(
            'recording-language-${widget.retranscribing ? 'retranscribe' : 'transcribe'}',
          ),
          child: DropdownButtonFormField<String>(
            key: ValueKey(selected),
            initialValue: selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '录音语言'),
            hint: const Text('选择录音语言'),
            items: [
              for (final language in languages)
                DropdownMenuItem(
                  value: language.code,
                  child: Text(language.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: enabled && !_submitting && languages.isNotEmpty
                ? (language) {
                    if (language != null) _selectLanguage(language);
                  }
                : null,
          ),
        ),
        if (_checking) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '正在检查语言…',
                  style: TextStyle(color: tokens.textSecondary),
                ),
              ),
            ],
          ),
        ] else if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: tokens.coral)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: enabled ? _checkLanguage : null,
              child: const Text('重试'),
            ),
          ),
        ] else if (_status == SpeechResourceStatus.unsupported) ...[
          const SizedBox(height: 12),
          Text(
            '不支持此录音语言，请选择其他语言',
            style: TextStyle(color: tokens.textSecondary),
          ),
        ] else if (languages.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            c.appleCapabilitiesLoading
                ? '正在获取支持的语言…'
                : c.appleSetupError ?? '当前无法使用 Apple 设备端转写',
            style: TextStyle(color: tokens.textSecondary),
          ),
          if (!c.appleCapabilitiesLoading)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: enabled ? c.refreshAppleCapabilities : null,
                child: const Text('重新检查'),
              ),
            ),
        ],
        const SizedBox(height: 18),
        FilledButton.icon(
          key: ValueKey(
            'apple-${widget.retranscribing ? 'retranscribe' : 'transcribe'}',
          ),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: canSubmit ? _submit : null,
          icon: Icon(
            _status == SpeechResourceStatus.needsDownload
                ? Icons.download_rounded
                : Icons.subtitles_outlined,
          ),
          label: Text(
            _submitting
                ? '处理中…'
                : _status == SpeechResourceStatus.needsDownload
                ? '下载语言并转写'
                : widget.retranscribing
                ? '重新转写'
                : '转写录音',
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

class _DeviceDownload extends StatelessWidget {
  const _DeviceDownload({required this.recording});
  final RecordingViewData recording;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final tokens = KoeTokens.of(context);
    final id = recording.reference.fileId;
    if (id == null) return const SizedBox.shrink();
    final file = c.files.where((file) => file.fileId == id).firstOrNull;
    final downloading = c.activeBleDownloadFileId == id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(148, 46)),
            onPressed: c.connected
                ? (file != null && c.canDownloadOverBle && !downloading
                      ? () => c.downloadFileOverBle(file)
                      : null)
                : () => showScanDevicesSheet(context),
            icon: Icon(
              c.connected ? Icons.download_rounded : Icons.radar_rounded,
              size: 18,
            ),
            label: Text(
              !c.connected
                  ? '连接设备'
                  : downloading
                  ? '下载中…'
                  : '下载录音',
            ),
          ),
          if (downloading) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.pill),
              child: LinearProgressIndicator(
                minHeight: 4,
                backgroundColor: tokens.bgSubtle,
                color: tokens.accent,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProcessingStatus extends StatelessWidget {
  const _ProcessingStatus({this.progress});
  final SttFileProgress? progress;
  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final stage = progress?.stage;
    final label = switch (stage) {
      SttFileStage.preparing => '正在准备音频…',
      SttFileStage.uploading => '正在上传…',
      SttFileStage.queued => '等待处理…',
      SttFileStage.fetching => '正在获取结果…',
      _ => '正在处理…',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: tokens.bgCard,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(color: tokens.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: tokens.accent,
                  ),
                ),
                const SizedBox(width: 8),
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
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.pill),
              child: LinearProgressIndicator(
                value: progress?.fraction,
                minHeight: 4,
                backgroundColor: tokens.bgSubtle,
                color: tokens.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.label,
    required this.initialName,
    required this.maxLength,
    required this.validate,
    this.inputKey,
  });
  final String title;
  final String label;
  final String initialName;
  final int maxLength;
  final String Function(String) validate;
  final Key? inputKey;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _input = TextEditingController(text: widget.initialName);
  String? _error;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      Navigator.pop(context, widget.validate(_input.text));
    } on ArgumentError catch (error) {
      setState(() => _error = error.message?.toString());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: widget.inputKey,
      controller: _input,
      autofocus: true,
      maxLength: widget.maxLength,
      decoration: InputDecoration(
        labelText: widget.label,
        errorText: _error,
        counterText: '',
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('保存')),
    ],
  );
}

class _TranslationDialog extends StatefulWidget {
  const _TranslationDialog({
    required this.languages,
    required this.source,
    required this.target,
    this.preparedSource,
    this.preparedTarget,
  });
  final List<SpeechLanguage> languages;
  final String source;
  final String target;
  final String? preparedSource;
  final String? preparedTarget;
  @override
  State<_TranslationDialog> createState() => _TranslationDialogState();
}

class _TranslationDialogState extends State<_TranslationDialog> {
  String? _source;
  String? _target;
  @override
  void initState() {
    super.initState();
    _source = _supported(widget.source);
    _target = _supported(widget.target);
  }

  String? _supported(String? code) {
    if (code == null) return null;
    final normalized = code.toLowerCase();
    final exact = widget.languages
        .where((language) => language.code.toLowerCase() == normalized)
        .firstOrNull;
    if (exact != null) return exact.code;
    // A bare language may suggest a region; explicit scripts/regions must not
    // silently switch to a different dialect or writing system.
    if (normalized.contains('-')) return null;
    final candidates = widget.languages
        .where(
          (language) =>
              language.code.toLowerCase().split('-').first == normalized,
        )
        .toList();
    return candidates.length == 1 ? candidates.single.code : null;
  }

  bool get _needsPreparation =>
      _source != _supported(widget.preparedSource) ||
      _target != _supported(widget.preparedTarget);
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('翻译录音文本'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _source,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '原文语言'),
            items: [
              for (final language in widget.languages)
                DropdownMenuItem(
                  value: language.code,
                  child: Text(language.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => setState(() => _source = value),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _target,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '目标语言'),
            items: [
              for (final language in widget.languages)
                DropdownMenuItem(
                  value: language.code,
                  child: Text(language.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => setState(() => _target = value),
          ),
          const SizedBox(height: 12),
          Text(
            _needsPreparation ? '下载所选语言后，在设备端翻译。' : '使用已下载的语言在设备端翻译。',
            style: TextStyle(
              fontSize: 13,
              color: KoeTokens.of(context).textSecondary,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _source != null && _target != null && _source != _target
            ? () => Navigator.pop(context, (
                _source!,
                _target!,
                _needsPreparation,
              ))
            : null,
        child: Text(_needsPreparation ? '下载并翻译' : '翻译'),
      ),
    ],
  );
}
