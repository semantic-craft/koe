import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:provider/provider.dart';

import '../../state/minutes_document.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../library_filter.dart';
import '../recording_navigation.dart';
import '../widgets/mobile_header.dart';
import '../widgets/widgets.dart';
import 'files_screen.dart';
import 'listening_queue_screen.dart';
import 'minutes_document_screen.dart';
import 'new_recording_sheet.dart';
import 'trash_screen.dart';
import '../file_types.dart';

/// Phone "Materials" section (#131).
///
/// Title and transcript search are real; full-text hits keep their source
/// paragraph or timed sentence. This page never fabricates a search result.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _search = TextEditingController();
  String _query = '';
  LibraryTypeFilter _filter = LibraryTypeFilter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final continuePath = c.continuePath;
    // The header scrolls away with the list so the recordings keep the
    // screen at large text sizes; the lists inside FilesBody drive it.
    return GradientScaffold(
      child: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KoeMobileHeader(
                  onNewRecording: () => _newRecording(context),
                  onOpenSettings: () => openMobileSettings(context),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '资料',
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 30,
                                  height: 1.15,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.6,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('library-queue'),
                            tooltip: '收听队列',
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ListeningQueueScreen(),
                              ),
                            ),
                            icon: Badge(
                              isLabelVisible: c.queueEntries.isNotEmpty,
                              label: Text('${c.queueEntries.length}'),
                              child: const Icon(Icons.queue_music_rounded),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('library-trash'),
                            tooltip: '回收站',
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const TrashScreen(),
                              ),
                            ),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                          IconButton(
                            key: const ValueKey('library-import'),
                            tooltip: '导入音频',
                            onPressed: () => handleNewRecordingAction(
                              context,
                              NewRecordingAction.importAudio,
                            ),
                            icon: const Icon(
                              Icons.audio_file_outlined,
                              size: 20,
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('library-import-text'),
                            tooltip: '文字资料',
                            onPressed: () => _showTextLibrary(context),
                            icon: const Icon(
                              Icons.description_outlined,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '原声留在手机，标题、时间和文字都能找回同一条资料。',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.45,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const ValueKey('library-search'),
                        controller: _search,
                        textInputAction: TextInputAction.search,
                        onChanged: (value) => setState(() => _query = value),
                        decoration: InputDecoration(
                          hintText: '搜索标题或正文',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清除搜索',
                                  onPressed: () {
                                    _search.clear();
                                    setState(() => _query = '');
                                  },
                                  icon: const Icon(Icons.close_rounded),
                                ),
                          filled: true,
                          fillColor: AppColors.bgCard,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadii.card),
                            borderSide: const BorderSide(
                              color: AppColors.border,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadii.card),
                            borderSide: const BorderSide(
                              color: AppColors.border,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _FilterChip(
                            key: const ValueKey('library-filter-all'),
                            label: '全部',
                            selected: _filter == LibraryTypeFilter.all,
                            onSelected: () =>
                                setState(() => _filter = LibraryTypeFilter.all),
                          ),
                          _FilterChip(
                            key: const ValueKey('library-filter-audio'),
                            label: '录音',
                            selected: _filter == LibraryTypeFilter.audio,
                            onSelected: () => setState(
                              () => _filter = LibraryTypeFilter.audio,
                            ),
                          ),
                          _FilterChip(
                            key: const ValueKey('library-filter-text'),
                            label: '文字',
                            selected: _filter == LibraryTypeFilter.text,
                            onSelected: () => setState(
                              () => _filter = LibraryTypeFilter.text,
                            ),
                          ),
                        ],
                      ),
                      if (continuePath != null) ...[
                        const SizedBox(height: 10),
                        _LibraryContinueCard(
                          title: c
                              .recordingView(
                                RecordingReference(
                                  fileId: c.fileIdFromPath(continuePath),
                                  path: continuePath,
                                ),
                              )
                              .title,
                          subtitle: c.continueDetail,
                          playing: c.playingPath == continuePath && c.isPlaying,
                          onToggle: () => c.playingPath == continuePath
                              ? c.togglePlayPause()
                              : c.toggleLatestPlayback(),
                          onOpen: () => RecordingNavigation.open(
                            context,
                            RecordingReference(
                              fileId: c.fileIdFromPath(continuePath),
                              path: continuePath,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                if (_visibleMinutes(c).isNotEmpty)
                  Padding(
                    key: const ValueKey('library-minutes-list'),
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final document in _visibleMinutes(c))
                          _MinutesRow(
                            document: document,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                settings: RouteSettings(
                                  name: 'minutes/${document.id}',
                                ),
                                builder: (_) => MinutesDocumentScreen(
                                  documentId: document.id,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        body: FilesBody(
          key: const ValueKey('library-files'),
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          query: _query,
          typeFilter: _filter,
        ),
      ),
    );
  }

  Future<void> _newRecording(BuildContext context) async {
    final action = await showNewRecordingSheet(context);
    if (action == null || !context.mounted) return;
    await handleNewRecordingAction(context, action);
  }

  List<MinutesDocument> _visibleMinutes(RecorderController c) {
    if (_filter == LibraryTypeFilter.audio) return const [];
    final needle = _query.trim().toLowerCase();
    return c.minutesDocuments.where((document) {
      if (needle.isEmpty) return true;
      return document.title.toLowerCase().contains(needle) ||
          document.bodyText.toLowerCase().contains(needle);
    }).toList();
  }

  Future<void> _importText(BuildContext context) async {
    final controller = context.read<RecorderController>();
    final selected = await openFile(
      acceptedTypeGroups: const [minutesTextFileTypes],
    );
    if (selected == null || !context.mounted) return;
    try {
      final contents = await selected.readAsString();
      final outcome = await controller.importMinutesText(
        selected.name,
        contents,
      );
      if (!context.mounted) return;
      final message = outcome.duplicate
          ? '这条文字已在资料中，未重复导入'
          : outcome.document.timingReliable
          ? '已导入文字，可补配原音频后按句回听'
          : '已导入文字；没有可靠时码，只能阅读';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is FormatException
                ? '无法识别这份文字：${error.message}'
                : error is StateError
                ? error.message
                : '导入失败，请重试',
          ),
        ),
      );
    }
  }

  Future<void> _showTextLibrary(BuildContext context) async {
    final pageContext = context;
    final navigator = Navigator.of(context);
    final controller = context.read<RecorderController>();
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: AppMotion.sheetStyle(context),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.7,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final documents = controller.minutesDocuments;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '文字资料',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          key: const ValueKey('text-library-import'),
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _importText(pageContext);
                          },
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('导入文字'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: documents.isEmpty
                        ? const Center(
                            child: Text('还没有导入文字；可以从妙记 JSON/TXT 导入。'),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                            itemCount: documents.length,
                            itemBuilder: (context, index) {
                              final document = documents[index];
                              return _MinutesRow(
                                document: document,
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  navigator.push(
                                    MaterialPageRoute<void>(
                                      settings: RouteSettings(
                                        name: 'minutes/${document.id}',
                                      ),
                                      builder: (_) => MinutesDocumentScreen(
                                        documentId: document.id,
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MinutesRow extends StatelessWidget {
  const _MinutesRow({required this.document, required this.onTap});

  final MinutesDocument document;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final time = document.capturedAt;
    final status = document.textOnly
        ? '只有文字 · 尚未补配音频'
        : document.unaligned
        ? '已取得音频 · 时码不可靠'
        : '可回听';
    return SurfaceCard(
      key: ValueKey('minutes-row-${document.id}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      onTap: onTap,
      child: Row(
        children: [
          const Icon(
            Icons.description_outlined,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  document.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  time == null
                      ? '发生时间未知 · 导入 ${_shortDate(document.importedAt)}'
                      : '${_shortDateTime(time)} · ${document.sourceName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  status,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}

String _shortDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

String _shortDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      showCheckmark: false,
      labelStyle: TextStyle(
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected ? AppColors.accent : AppColors.textSecondary,
      ),
    );
  }
}

class _LibraryContinueCard extends StatelessWidget {
  const _LibraryContinueCard({
    required this.title,
    required this.subtitle,
    required this.playing,
    required this.onToggle,
    required this.onOpen,
  });

  final String title;
  final String subtitle;
  final bool playing;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      key: const ValueKey('library-continue-listening'),
      padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
      onTap: onOpen,
      child: Row(
        children: [
          IconButton(
            tooltip: playing ? '暂停播放' : '继续播放',
            onPressed: onToggle,
            style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: AppColors.accent,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '继续回听 · $title',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}
