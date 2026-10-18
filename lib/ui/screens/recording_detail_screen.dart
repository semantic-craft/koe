import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../ai/apple_speech.dart';
import '../../ai/stt_types.dart';
import '../../state/export_catalog.dart';
import '../../state/recorder_controller.dart';
import '../../state/recording_bookmarks.dart';
import '../../theme/app_theme.dart';
import '../recording_navigation.dart';
import '../transcript_layout.dart';
import '../widgets/analysis_panel.dart';
import '../widgets/inline_player.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/topic_note_panel.dart';
import 'files_screen.dart';

class RecordingDetailScreen extends StatefulWidget {
  const RecordingDetailScreen({
    super.key,
    required this.reference,
    this.initialHighlightedParagraph,
  });

  final RecordingReference reference;
  final int? initialHighlightedParagraph;

  @override
  State<RecordingDetailScreen> createState() => _RecordingDetailScreenState();
}

class _RecordingDetailScreenState extends State<RecordingDetailScreen> {
  bool _showTranslation = false;
  bool _selectionInitialized = false;
  String? _selectedRecordingLanguage;
  int? _highlightedParagraph;

  @override
  void initState() {
    super.initState();
    _highlightedParagraph = widget.initialHighlightedParagraph;
  }

  @override
  void didUpdateWidget(RecordingDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialHighlightedParagraph !=
        widget.initialHighlightedParagraph) {
      _highlightedParagraph = widget.initialHighlightedParagraph;
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Segments the reader can locate; bookmarks resolve against the same list
  /// the user sees so a marker never lands on a different sentence.
  List<TranscriptSegment> _locatableSegments(
    RecorderController c,
    RecordingViewData recording,
  ) {
    final path = recording.path;
    final source = normalizeSttText(recording.text);
    final raw = recording.segments;
    final matched =
        transcriptSegmentsMatchText(
          raw,
          source,
          aliases: path == null ? const {} : c.speakerAliasesForPath(path),
        )
        ? raw
        : const <TranscriptSegment>[];
    final locatable =
        recording.originalPresent &&
        transcriptSegmentsLocatable(
          matched,
          duration: path == null ? null : c.localDurationForPath(path),
        );
    return locatable ? matched : const <TranscriptSegment>[];
  }

  List<BookmarkTarget> _bookmarkTargets(
    RecorderController c,
    RecordingViewData recording,
    List<TranscriptSegment> segments, {
    List<RecordingBookmark>? only,
    ({bool known, String? version})? audioOverride,
  }) {
    if (recording.live) return const [];
    final path = recording.path;
    final saved = only ?? c.bookmarksFor(widget.reference);
    if (saved.isEmpty) return const [];
    final audio =
        audioOverride ??
        (path == null || !recording.originalPresent
            ? (known: true, version: null)
            : c.bookmarkAudioVersion(path));
    return [
      for (final bookmark in saved)
        resolveBookmark(
          bookmark,
          audioAvailable:
              path != null &&
              recording.originalPresent &&
              !recording.audioLocked,
          audioChanged: c.recordingAudioChanged(widget.reference),
          segments: segments,
          duration: path == null ? null : c.localDurationForPath(path),
          audioVersionKnown: audio.known,
          currentAudioVersion: audio.version,
        ),
    ];
  }

  Future<void> _openBookmark(BookmarkTarget target) async {
    final c = context.read<RecorderController>();
    final path = c.recordingView(widget.reference).path;
    if (target.seekTo == null || path == null) {
      _notice(target.unavailableReason ?? '这条书签暂时无法回听');
      return;
    }
    // Verify the content itself before playing; the marker may have been
    // drawn from a cached digest of a file replaced with the same size/mtime.
    final fresh = await c.verifyBookmarkAudio(path);
    if (!mounted) return;
    final recording = c.recordingView(widget.reference);
    final checked = _bookmarkTargets(
      c,
      recording,
      _locatableSegments(c, recording),
      only: [target.bookmark],
      audioOverride: (known: true, version: fresh),
    );
    final now = checked.isEmpty ? null : checked.single;
    final seekTo = now?.seekTo;
    if (now == null || seekTo == null || recording.path == null) {
      _notice(now?.unavailableReason ?? '这条书签暂时无法回听');
      return;
    }
    if (_showTranslation) setState(() => _showTranslation = false);
    await c.playFrom(
      recording.path!,
      seekTo,
      fileId: recording.reference.fileId,
    );
  }

  Future<void> _addBookmark() async {
    final c = context.read<RecorderController>();
    final recording = c.recordingView(widget.reference);
    final path = recording.path;
    if (path == null) return;
    final loaded =
        c.playingPath == path ||
        (recording.reference.fileId != null &&
            c.playingFileId == recording.reference.fileId);
    final position = loaded ? c.position : Duration.zero;
    final segments = _locatableSegments(c, recording);
    // A gap between sentences stays a plain time bookmark.
    final index = segmentContaining(segments, position);
    final segment = index == null ? null : segments[index];
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      builder: (_) => _BookmarkEditor(
        title: '添加书签',
        position: position,
        excerpt: segment == null
            ? null
            : transcriptSegmentLabel(
                segment,
                aliases: c.speakerAliasesForPath(path),
              ),
        onSave: (note) => c.addBookmark(
          widget.reference,
          position: position,
          segment: segment,
          note: note,
        ),
      ),
    );
    if (!mounted) return;
    _notice(saved == true ? '已保存书签' : '已取消，未保存书签');
  }

  Future<void> _editBookmark(RecordingBookmark bookmark) async {
    final c = context.read<RecorderController>();
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      builder: (_) => _BookmarkEditor(
        title: '编辑批注',
        position: bookmark.position,
        excerpt: bookmark.segmentText,
        initialNote: bookmark.note,
        onSave: (note) => c.updateBookmarkNote(bookmark.id, note),
      ),
    );
    if (!mounted) return;
    _notice(saved == true ? '已更新批注' : '已取消，批注未更改');
  }

  Future<void> _removeBookmark(
    BuildContext sheetContext,
    RecordingBookmark bookmark,
  ) async {
    final c = context.read<RecorderController>();
    final confirmed = await showDialog<bool>(
      context: sheetContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条书签？'),
        content: const Text('书签和批注将被删除，录音与转写不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除', style: TextStyle(color: AppColors.coral)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await c.removeBookmark(bookmark.id);
    } catch (_) {
      _notice('删除失败，书签仍保留');
    }
  }

  Future<void> _openBookmarkList() async {
    final c = context.read<RecorderController>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.75,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) {
              final recording = c.recordingView(widget.reference);
              final targets = _bookmarkTargets(
                c,
                recording,
                _locatableSegments(c, recording),
              );
              return _BookmarkListSheet(
                notice: c.bookmarkRecoveryNotice,
                targets: targets,
                showMarkers: c.showBookmarkMarkers,
                onShowMarkersChanged: (value) async {
                  try {
                    await c.setShowBookmarkMarkers(value);
                  } catch (_) {
                    _notice('标记显示设置未保存');
                  }
                },
                onOpen: (target) {
                  Navigator.pop(sheetContext);
                  _openBookmark(target);
                },
                onEdit: (bookmark) => _editBookmark(bookmark),
                onRemove: (bookmark) => _removeBookmark(sheetContext, bookmark),
              );
            },
          ),
        ),
      ),
    );
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

  Future<void> _trash(RecordingViewData recording) async {
    final path = recording.path;
    if (path == null || recording.audioLocked) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移到回收站？'),
        content: const Text(
          '原件、转写和主题关联会保留 30 天，期间可以恢复。'
          '移到回收站后会从资料列表和继续回听中消失；独立笔记不会删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移到回收站'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await context.read<RecorderController>().trashLocalExports([
      path,
    ]);
    if (!mounted) return;
    if (result.failed.isNotEmpty) {
      _notice(result.failed.first);
      return;
    }
    _notice('已移到回收站，30 天内可恢复');
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  Future<void> _clearCache(RecordingViewData recording) async {
    final path = recording.path;
    if (path == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理可恢复的播放缓存？'),
        content: const Text('只删除可重新生成的播放副本，原件、转写与笔记都会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await context
        .read<RecorderController>()
        .clearRecoverableCache(path);
    if (!mounted) return;
    _notice(
      result.removed == 0
          ? '没有可清理的播放缓存，原件已保留'
          : '已清理 ${result.removed} 个播放缓存，原件保留',
    );
  }

  Future<void> _removeFromTopics(RecordingViewData recording) async {
    final path = recording.path;
    if (path == null) return;
    await context.read<RecorderController>().removeRecordingFromTopics(path);
    if (!mounted) return;
    _notice('已移出项目/主题，资料与笔记仍保留');
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
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '说话人姓名',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
              ),
              for (final speaker in controller.transcriptSpeakersForPath(path))
                ListTile(
                  title: Text(speaker.displayLabel),
                  trailing: const Icon(Icons.edit_outlined),
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

  Future<void> _showInfo(RecordingViewData recording) async {
    final controller = context.read<RecorderController>();
    final path = recording.path;
    String date(DateTime? value) {
      if (value == null) return '未知';
      final local = value.toLocal();
      String two(int number) => number.toString().padLeft(2, '0');
      return '${local.year}-${two(local.month)}-${two(local.day)} '
          '${two(local.hour)}:${two(local.minute)}';
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '资料信息',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              _InfoRow(
                label: '录音发生时间',
                value: recording.recordedAt == null
                    ? '未知（导入文件未提供）'
                    : date(recording.recordedAt),
              ),
              _InfoRow(
                label: '导入资料库',
                value: recording.importedAt == null
                    ? '未知'
                    : date(recording.importedAt),
              ),
              _InfoRow(
                label: '时长',
                value: path == null
                    ? '未知'
                    : FilesBody.formatDuration(
                        controller.localDurationForPath(path),
                      ),
              ),
              _InfoRow(
                label: '来源',
                value: recordingSourceLabel(recording.source),
              ),
              _InfoRow(
                label: '原件状态',
                value: !recording.originalPresent
                    ? '找不到原件'
                    : recording.originalComplete
                    ? '已保留'
                    : '已保留但不完整',
              ),
              _InfoRow(
                label: '原件位置',
                value: path ?? '尚未保存到本机',
                selectable: true,
              ),
              if (recording.originalPath != null)
                _InfoRow(
                  label: '原始文件',
                  value: recording.originalPath!,
                  selectable: true,
                ),
              _InfoRow(
                label: '归档状态',
                value: recording.archived ? '回收站' : '资料库',
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final recording = c.recordingView(widget.reference);
    if (!_selectionInitialized) {
      _selectionInitialized = true;
      _showTranslation =
          recording.live && recording.mode == SttDisplayMode.translation;
    }
    final translated = recording.translation?.text ?? '';
    final hasTranslation = translated.isNotEmpty;
    final source = normalizeSttText(recording.text);
    final path = recording.path;
    final rawSegments = recording.segments;
    final segmentText =
        transcriptSegmentsMatchText(
          rawSegments,
          source,
          aliases: path == null ? const {} : c.speakerAliasesForPath(path),
        )
        ? rawSegments
        : const <TranscriptSegment>[];
    final segmentsLocatable =
        recording.originalPresent &&
        transcriptSegmentsLocatable(
          segmentText,
          duration: path == null ? null : c.localDurationForPath(path),
        );
    final activeSegment =
        !_showTranslation && segmentsLocatable && c.playingPath == path
        ? _segmentAt(segmentText, c.position)
        : null;
    final bookmarkTargets = _bookmarkTargets(
      c,
      recording,
      segmentsLocatable ? segmentText : const [],
    );
    final showMarkers = c.showBookmarkMarkers;
    String markerLabel(RecordingBookmark bookmark) =>
        bookmark.note.isNotEmpty ? bookmark.note : bookmark.segmentText ?? '';
    final text = _showTranslation && hasTranslation ? translated : source;
    final fileReady =
        recording.path != null &&
        recording.originalPresent &&
        !recording.audioLocked;
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
    final topicPlacement = c.topicsEnabled
        ? c.topics.topicOf(c.recordingKeyFor(widget.reference))
        : null;
    final hasRecoverableCache =
        recording.path != null && c.hasRecoverableCacheForPath(recording.path!);

    return Scaffold(
      key: ValueKey('recording-detail-${widget.reference.key}'),
      backgroundColor: AppColors.bgElevated,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        automaticallyImplyLeading:
            !(RecordingNavigation.of(context)?.wide ?? false),
        toolbarHeight: (RecordingNavigation.of(context)?.wide ?? false)
            ? 88
            : 64,
        title: Text(
          recording.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        titleTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: AppColors.textPrimary,
          fontSize: (RecordingNavigation.of(context)?.wide ?? false) ? 24 : 18,
          fontWeight: FontWeight.w600,
        ),
        actions: [
          IconButton(
            tooltip: '分享录音',
            onPressed: fileReady ? () => _share(recording) : null,
            icon: const Icon(Icons.ios_share_rounded),
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
                case 'info':
                  _showInfo(recording);
                case 'remove-topic':
                  _removeFromTopics(recording);
                case 'clear-cache':
                  _clearCache(recording);
                case 'trash':
                  _trash(recording);
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
              if (topicPlacement != null)
                PopupMenuItem(
                  value: 'remove-topic',
                  enabled: fileReady,
                  child: const Text('移出项目/主题'),
                ),
              if (hasRecoverableCache)
                PopupMenuItem(
                  value: 'clear-cache',
                  enabled: fileReady && !recording.processing,
                  child: const Text('清理可恢复缓存'),
                ),
              PopupMenuItem(
                value: 'trash',
                enabled: fileReady && !recording.processing,
                child: const Text(
                  '删除资料…',
                  style: TextStyle(color: AppColors.coral),
                ),
              ),
              const PopupMenuItem(value: 'info', child: Text('资料信息')),
            ],
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.center,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    if (hasTranslation)
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
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
                        ),
                      )
                    else
                      Expanded(
                        child: Text(
                          recording.paused
                              ? '已暂停'
                              : recording.live
                              ? (recording.provider.retired ? '录音中' : '实时转写')
                              : '转写文本',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    if (c.topicsEnabled &&
                        c.topics.topicOf(c.recordingKeyFor(widget.reference)) !=
                            null &&
                        source.isNotEmpty &&
                        !recording.live)
                      TextButton.icon(
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          showDragHandle: true,
                          builder: (sheetContext) => SafeArea(
                            child: FractionallySizedBox(
                              heightFactor: 0.85,
                              child: TopicNotePanel(
                                controller: c,
                                reference: widget.reference,
                                onSelectParagraph: (index) {
                                  Navigator.pop(sheetContext);
                                  if (mounted) {
                                    setState(() {
                                      _showTranslation = false;
                                      _highlightedParagraph = index;
                                    });
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.menu_book_outlined, size: 18),
                        label: const Text('主题笔记'),
                      ),
                    if (source.isNotEmpty && !recording.live)
                      IconButton(
                        tooltip: '摘要与分析',
                        icon: const Icon(Icons.auto_awesome_outlined),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => AnalysisPanel(
                              controller: c,
                              reference: widget.reference,
                            ),
                          ),
                        ),
                      ),
                    if (recording.processing) ...[
                      const SizedBox(width: 8),
                      const Tooltip(
                        message: '正在处理',
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
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
                          icon: const Icon(Icons.translate_rounded),
                        )
                      else
                        TextButton.icon(
                          onPressed: canProcess
                              ? () => _translate(recording)
                              : null,
                          icon: const Icon(Icons.translate_rounded),
                          label: const Text('翻译'),
                        ),
                    ],
                    if (!recording.live &&
                        (path != null || bookmarkTargets.isNotEmpty))
                      IconButton(
                        key: const ValueKey('bookmark-list-button'),
                        tooltip: '书签与批注',
                        onPressed: _openBookmarkList,
                        icon: Badge(
                          isLabelVisible: bookmarkTargets.isNotEmpty,
                          label: Text('${bookmarkTargets.length}'),
                          child: const Icon(Icons.bookmarks_outlined),
                        ),
                      ),
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
                      icon: const Icon(Icons.copy_outlined),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!_showTranslation &&
              source.isNotEmpty &&
              !recording.live &&
              !segmentsLocatable)
            _TranscriptTimingNotice(
              unreliable: rawSegments.isNotEmpty,
              originalPresent: recording.originalPresent,
              hasLocalPath: path != null,
              hasFileId: recording.reference.fileId != null,
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
                    highlightedParagraph: translation
                        ? null
                        : _highlightedParagraph,
                    segments: translation || !segmentsLocatable
                        ? const []
                        : segmentText,
                    activeSegment: translation ? null : activeSegment,
                    bookmarkedSegments: translation || !showMarkers
                        ? const {}
                        : {
                            for (final target in bookmarkTargets)
                              if (target.segmentIndex != null)
                                target.segmentIndex!,
                          },
                    speakerAliases: translation
                        ? const {}
                        : recording.path == null
                        ? const {}
                        : c.speakerAliasesForPath(recording.path!),
                    onSegmentTap: translation || !segmentsLocatable
                        ? null
                        : (index) {
                            final target = segmentText[index].start;
                            c.playFrom(
                              recording.path!,
                              target,
                              fileId: recording.reference.fileId,
                            );
                          },
                    header: !hasReaderHeader || (translation && !hasTranslation)
                        ? null
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (recording.processing)
                                _ProcessingStatus(progress: recording.progress),
                              if (recording.processing &&
                                  c.speechProvider == SttProvider.qwen)
                                TextButton(
                                  onPressed: c.cancelQwenFileProcessing,
                                  child: const Text('停止等待（保留已提交任务）'),
                                ),
                              if (recording.processing &&
                                  c.doubaoFileProcessing)
                                TextButton(
                                  onPressed: c.cancelDoubaoFileProcessing,
                                  child: const Text('停止等待（重试将重新上传）'),
                                ),
                              if (recording.error != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Text(
                                    recording.error!,
                                    style: const TextStyle(
                                      color: AppColors.coral,
                                      height: 1.4,
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
      bottomNavigationBar:
          recording.live || recording.paused || recording.audioLocked
          ? _LiveControls(recording: recording)
          : fileReady
          ? Material(
              color: AppColors.bgCard,
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
                        markers: showMarkers
                            ? [
                                for (final target in bookmarkTargets)
                                  if (target.seekTo != null)
                                    InlinePlayerMarker(
                                      id: target.bookmark.id,
                                      at: target.seekTo!,
                                      label: markerLabel(target.bookmark),
                                    ),
                              ]
                            : const [],
                        onMarkerTap: (marker) {
                          for (final target in bookmarkTargets) {
                            if (target.bookmark.id == marker.id) {
                              _openBookmark(target);
                              return;
                            }
                          }
                        },
                        onAddBookmark: _addBookmark,
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

int? _segmentAt(List<TranscriptSegment> segments, Duration position) {
  int? found;
  for (var index = 0; index < segments.length; index++) {
    if (position < segments[index].start) break;
    found = index;
  }
  return found;
}

String _formatSegmentTime(Duration value) {
  final total = value.inSeconds.clamp(0, 359999);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int part) => part.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

/// Explains why sentence replay is unavailable while keeping whole-file
/// playback and the transcript itself usable.
class _TranscriptTimingNotice extends StatelessWidget {
  const _TranscriptTimingNotice({
    required this.unreliable,
    required this.originalPresent,
    required this.hasLocalPath,
    required this.hasFileId,
  });

  final bool unreliable;
  final bool originalPresent;
  final bool hasLocalPath;
  final bool hasFileId;

  @override
  Widget build(BuildContext context) {
    final String message;
    final String key;
    if (!originalPresent) {
      if (hasLocalPath) {
        key = 'missing-file-timing-notice';
        message = '原录音文件已不在本机，无法回听；转写文字仍可阅读。';
      } else if (hasFileId) {
        key = 'undownloaded-timing-notice';
        message = '录音尚未下载到本机；取回原音频后可回听，转写文字仍可阅读。';
      } else {
        key = 'original-missing-timing-notice';
        message = '原录音不可用，无法回听；转写文字仍可阅读。';
      }
    } else if (unreliable) {
      key = 'unreliable-timing-notice';
      message = '这条转写的时码缺失或越界，已关闭逐句定位；整段录音仍可播放。';
    } else {
      key = 'missing-timing-notice';
      message = '这条转写没有可靠的逐句时码，无法精确定位句段；整段录音仍可播放。';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: Row(
        key: ValueKey(key),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12,
                height: 1.35,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
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
    this.highlightedParagraph,
    this.segments = const [],
    this.activeSegment,
    this.bookmarkedSegments = const {},
    this.speakerAliases = const {},
    this.onSegmentTap,
    this.header,
  });
  final String text;
  final bool live;
  final bool visible;
  final int? highlightedParagraph;
  final List<TranscriptSegment> segments;
  final int? activeSegment;
  final Set<int> bookmarkedSegments;
  final Map<String, String> speakerAliases;
  final ValueChanged<int>? onSegmentTap;
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
    _paragraphs = _contentTexts();
    _follow();
  }

  bool get _usesSegments => widget.segments.isNotEmpty;

  List<String> _contentTexts() {
    if (_usesSegments) {
      return [
        for (final segment in widget.segments)
          transcriptSegmentLabel(segment, aliases: widget.speakerAliases),
      ];
    }
    return splitTranscriptDisplayParagraphs(widget.text);
  }

  @override
  void didUpdateWidget(RecordingTextReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        !listEquals(oldWidget.segments, widget.segments) ||
        !mapEquals(oldWidget.speakerAliases, widget.speakerAliases)) {
      _paragraphs = _contentTexts();
      _follow();
    } else if (!oldWidget.visible && widget.visible) {
      _follow();
    }
    final target = widget.activeSegment ?? widget.highlightedParagraph;
    final previous = oldWidget.activeSegment ?? oldWidget.highlightedParagraph;
    if (target != previous && target != null && _following) {
      _scrollToParagraph(target);
    }
  }

  void _scrollToParagraph(int paragraphIndex) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _paragraphs.isEmpty) return;
      final clamped = paragraphIndex.clamp(0, _paragraphs.length - 1);
      final maxExtent = _scroll.position.maxScrollExtent;
      if (maxExtent <= 0 || _paragraphs.length <= 1) return;
      final ratio = clamped / (_paragraphs.length - 1);
      _scroll.animateTo(
        (maxExtent * ratio).clamp(0.0, maxExtent),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _follow([int remaining = 6]) {
    final active = widget.activeSegment ?? widget.highlightedParagraph;
    if ((!widget.live && active == null) || !widget.visible || !_following) {
      return;
    }
    if (!widget.live && active != null) {
      _scrollToParagraph(active);
      return;
    }
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

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        NotificationListener<UserScrollNotification>(
          onNotification: (notification) {
            if (notification.depth == 0 &&
                (widget.live || widget.activeSegment != null) &&
                _scroll.hasClients) {
              // Live text can resume following when the reader reaches the
              // end, but timed playback only follows after an explicit tap.
              final following =
                  widget.live &&
                  notification.direction != ScrollDirection.forward &&
                  _scroll.position.extentAfter < 96;
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
                padding: EdgeInsets.fromLTRB(24, 24, 24, widget.live ? 80 : 28),
                itemCount: _paragraphs.length + (widget.header == null ? 0 : 1),
                itemBuilder: (context, index) => Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: SizedBox(
                      width: double.infinity,
                      child: Padding(
                        padding: EdgeInsets.only(
                          bottom:
                              (widget.header != null && index == 0) ||
                                  index ==
                                      _paragraphs.length +
                                          (widget.header == null ? 0 : 1) -
                                          1
                              ? 0
                              : 24,
                        ),
                        child: widget.header != null && index == 0
                            ? widget.header!
                            : Builder(
                                builder: (context) {
                                  final paragraphIndex =
                                      index - (widget.header == null ? 0 : 1);
                                  final highlighted =
                                      paragraphIndex ==
                                          widget.highlightedParagraph ||
                                      paragraphIndex == widget.activeSegment;
                                  final prefix = _usesSegments
                                      ? 'segment'
                                      : 'paragraph';
                                  final segment = _usesSegments
                                      ? widget.segments[paragraphIndex]
                                      : null;
                                  final content = Container(
                                    key: highlighted
                                        ? ValueKey(
                                            'highlighted-$prefix-$paragraphIndex',
                                          )
                                        : ValueKey('$prefix-$paragraphIndex'),
                                    padding: highlighted
                                        ? const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          )
                                        : EdgeInsets.zero,
                                    decoration: highlighted
                                        ? BoxDecoration(
                                            color: AppColors.bgSubtle,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          )
                                        : null,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (segment != null)
                                          Row(
                                            children: [
                                              Text(
                                                _formatSegmentTime(
                                                  segment.start,
                                                ),
                                                key: ValueKey(
                                                  'segment-time-$paragraphIndex',
                                                ),
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  color: AppColors.accent,
                                                  fontFeatures: [
                                                    FontFeature.tabularFigures(),
                                                  ],
                                                ),
                                              ),
                                              if (widget.bookmarkedSegments
                                                  .contains(paragraphIndex))
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        left: 6,
                                                      ),
                                                  child: Icon(
                                                    Icons.bookmark_rounded,
                                                    key: ValueKey(
                                                      'segment-bookmark-$paragraphIndex',
                                                    ),
                                                    size: 14,
                                                    color: AppColors.accent,
                                                    semanticLabel: '已加书签',
                                                  ),
                                                ),
                                            ],
                                          ),
                                        if (segment != null)
                                          const SizedBox(height: 2),
                                        Text(
                                          _paragraphs[paragraphIndex],
                                          style: const TextStyle(
                                            fontSize: 17,
                                            height: 1.85,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                  final tap = widget.onSegmentTap;
                                  if (!_usesSegments || tap == null) {
                                    return content;
                                  }
                                  return Semantics(
                                    button: true,
                                    label:
                                        '从 ${_formatSegmentTime(widget.segments[paragraphIndex].start)} 回听第 ${paragraphIndex + 1} 段',
                                    child: InkWell(
                                      onTap: () {
                                        setState(() => _following = true);
                                        tap(paragraphIndex);
                                      },
                                      borderRadius: BorderRadius.circular(8),
                                      child: content,
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if ((widget.live || widget.activeSegment != null) && !_following)
          Positioned(
            right: 20,
            bottom: 16,
            child: FilledButton.icon(
              key: const ValueKey('follow-latest'),
              onPressed: () {
                setState(() => _following = true);
                final active = widget.activeSegment;
                if (active != null) {
                  _scrollToParagraph(active);
                } else {
                  _follow();
                }
              },
              icon: const Icon(Icons.arrow_downward_rounded),
              label: Text(widget.activeSegment == null ? '最新内容' : '回到播放位置'),
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
    return Material(
      color: AppColors.bgCard,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  recording.paused
                      ? '已暂停'
                      : recording.live
                      ? '录音中'
                      : '正在保存录音',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ),
              if (recording.error != null)
                IconButton(
                  tooltip: '查看处理错误',
                  color: AppColors.coral,
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
              if (recording.paused &&
                  c.currentRecordingReference?.sessionId ==
                      recording.reference.sessionId)
                FilledButton.icon(
                  key: const ValueKey('resume-recording'),
                  onPressed: c.blocksRecordingControl || !c.connected
                      ? null
                      : c.startRecord,
                  icon: const Icon(Icons.mic_rounded),
                  label: const Text('继续录音'),
                ),
              if (recording.live && c.recording)
                FilledButton.icon(
                  key: const ValueKey('pause-recording'),
                  onPressed: c.phase == AppPhase.busy ? null : c.pauseRecord,
                  icon: const Icon(Icons.pause_rounded),
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
              : recording.provider.retired
              ? '录音结束后生成文字'
              : '开始说话后，文字会显示在这里')
        : !local
        ? '下载录音后即可播放和转写'
        : !configured && appleForm == null
        ? '在设置中准备语音服务后即可转写'
        : '这段录音还没有转写文本';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
          if (local && !recording.live && appleForm != null) ...[
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: appleForm!,
            ),
          ] else if (local && !recording.live && !recording.processing) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: canTranscribe ? onTranscribe : null,
              icon: const Icon(Icons.subtitles_outlined),
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
          const Row(
            children: [
              SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '正在检查语言…',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ] else if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: AppColors.coral)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: enabled ? _checkLanguage : null,
              child: const Text('重试'),
            ),
          ),
        ] else if (_status == SpeechResourceStatus.unsupported) ...[
          const SizedBox(height: 12),
          const Text(
            '不支持此录音语言，请选择其他语言',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ] else if (languages.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            c.appleCapabilitiesLoading
                ? '正在获取支持的语言…'
                : c.appleSetupError ?? '当前无法使用 Apple 设备端转写',
            style: const TextStyle(color: AppColors.textSecondary),
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
        const SizedBox(height: 20),
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
    final id = recording.reference.fileId;
    if (id == null) return const SizedBox.shrink();
    final file = c.files.where((file) => file.fileId == id).firstOrNull;
    final downloading = c.activeBleDownloadFileId == id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        children: [
          FilledButton.icon(
            onPressed: c.connected
                ? (file != null && c.canDownloadOverBle && !downloading
                      ? () => c.downloadFileOverBle(file)
                      : null)
                : () => showScanDevicesSheet(context),
            icon: Icon(
              c.connected ? Icons.download_rounded : Icons.radar_rounded,
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
            const LinearProgressIndicator(minHeight: 3),
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
    final stage = progress?.stage;
    final label = switch (stage) {
      SttFileStage.preparing => '正在准备音频…',
      SttFileStage.uploading => '正在上传…',
      SttFileStage.queued => '等待处理…',
      SttFileStage.fetching => '正在获取结果…',
      _ => '正在处理…',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: const TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress?.fraction, minHeight: 3),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 3),
        selectable
            ? SelectableText(
                value,
                style: const TextStyle(fontSize: 14, height: 1.4),
              )
            : Text(value, style: const TextStyle(fontSize: 14, height: 1.4)),
      ],
    ),
  );
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
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
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

/// Adds or edits one bookmark note. The sheet only closes after the store
/// confirms the write; a failure keeps the draft and says nothing was saved.
class _BookmarkEditor extends StatefulWidget {
  const _BookmarkEditor({
    required this.title,
    required this.position,
    required this.onSave,
    this.excerpt,
    this.initialNote = '',
  });

  final String title;
  final Duration position;
  final String? excerpt;
  final String initialNote;
  final Future<void> Function(String note) onSave;

  @override
  State<_BookmarkEditor> createState() => _BookmarkEditorState();
}

class _BookmarkEditorState extends State<_BookmarkEditor> {
  late final _note = TextEditingController(text: widget.initialNote);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_note.text);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error is BookmarkSaveException
            ? error.message
            : '未保存：书签无法写入本机存储。草稿已保留，可稍后重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // While the write is in flight the sheet cannot be dismissed, so a closed
    // sheet always matches what was actually stored.
    return PopScope(canPop: !_saving, child: _content(context));
  }

  Widget _content(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              _formatSegmentTime(widget.position),
              key: const ValueKey('bookmark-editor-time'),
              style: const TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (widget.excerpt != null) ...[
              const SizedBox(height: 4),
              Text(
                widget.excerpt!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('bookmark-note-field'),
              controller: _note,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '批注（可选）',
                hintText: '写下你的观察',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const ValueKey('bookmark-save-error'),
                style: const TextStyle(color: AppColors.coral, height: 1.4),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '正在保存…' : '保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BookmarkListSheet extends StatelessWidget {
  const _BookmarkListSheet({
    this.notice,
    required this.targets,
    required this.showMarkers,
    required this.onShowMarkersChanged,
    required this.onOpen,
    required this.onEdit,
    required this.onRemove,
  });

  final String? notice;
  final List<BookmarkTarget> targets;
  final bool showMarkers;
  final ValueChanged<bool> onShowMarkersChanged;
  final ValueChanged<BookmarkTarget> onOpen;
  final ValueChanged<RecordingBookmark> onEdit;
  final ValueChanged<RecordingBookmark> onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('bookmark-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Text(
            '书签与批注',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        if (notice != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
            child: Text(
              notice!,
              key: const ValueKey('bookmark-recovery-notice'),
              style: const TextStyle(color: AppColors.coral, height: 1.4),
            ),
          ),
        SwitchListTile(
          key: const ValueKey('bookmark-markers-switch'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          title: const Text('在播放条和正文显示标记'),
          subtitle: const Text('只影响显示，不会删除书签'),
          value: showMarkers,
          onChanged: onShowMarkersChanged,
        ),
        const Divider(height: 1),
        Expanded(
          child: targets.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '还没有书签。播放时点“为当前片段加书签”，可保存位置和个人批注。',
                    key: ValueKey('bookmark-list-empty'),
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: targets.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final target = targets[index];
                    final bookmark = target.bookmark;
                    final time = _formatSegmentTime(bookmark.position);
                    return Semantics(
                      button: target.available,
                      label: target.available
                          ? '从 $time 回听书签'
                          : '书签 $time 暂时无法回听',
                      child: InkWell(
                        key: ValueKey('bookmark-item-$index'),
                        onTap: target.available ? () => onOpen(target) : null,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 12, 8, 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(
                                          target.available
                                              ? Icons.bookmark_rounded
                                              : Icons.bookmark_remove_outlined,
                                          size: 16,
                                          color: target.available
                                              ? AppColors.accent
                                              : AppColors.textMuted,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          time,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontFeatures: [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (bookmark.segmentText != null) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        bookmark.segmentText!,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppColors.textSecondary,
                                          height: 1.4,
                                        ),
                                      ),
                                    ],
                                    if (bookmark.note.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        bookmark.note,
                                        style: const TextStyle(height: 1.4),
                                      ),
                                    ],
                                    if (target.unavailableReason != null) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        target.unavailableReason!,
                                        key: ValueKey(
                                          'bookmark-unavailable-$index',
                                        ),
                                        style: const TextStyle(
                                          color: AppColors.coral,
                                          fontSize: 13,
                                          height: 1.4,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: '编辑批注',
                                onPressed: () => onEdit(bookmark),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: '删除书签',
                                onPressed: () => onRemove(bookmark),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
