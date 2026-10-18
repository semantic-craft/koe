import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../library_filter.dart';
import '../recording_navigation.dart';
import '../widgets/mobile_header.dart';
import '../widgets/widgets.dart';
import 'files_screen.dart';
import 'new_recording_sheet.dart';
import 'trash_screen.dart';

/// Phone "Materials" section (#131).
///
/// Title search and type filters are real. Full-text hits and source jumps are
/// added by their own tickets; this page never fabricates a search result.
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
    final playing = c.hasLoadedTrack ? c.playingPath : null;
    return GradientScaffold(
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
                      child: Text(
                        '资料',
                        style: TextStyle(
                          fontSize: 30,
                          height: 1.15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.6,
                        ),
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
                    TextButton.icon(
                      key: const ValueKey('library-import'),
                      onPressed: () => handleNewRecordingAction(
                        context,
                        NewRecordingAction.importAudio,
                      ),
                      icon: const Icon(Icons.audio_file_outlined, size: 18),
                      label: const Text('导入'),
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
                    hintText: '搜索资料标题',
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
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppColors.border),
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
                      onSelected: () =>
                          setState(() => _filter = LibraryTypeFilter.audio),
                    ),
                    _FilterChip(
                      key: const ValueKey('library-filter-text'),
                      label: '文字',
                      selected: _filter == LibraryTypeFilter.text,
                      onSelected: () =>
                          setState(() => _filter = LibraryTypeFilter.text),
                    ),
                  ],
                ),
                if (playing != null) ...[
                  const SizedBox(height: 10),
                  _LibraryContinueCard(
                    title: c
                        .recordingView(
                          RecordingReference(
                            fileId: c.fileIdFromPath(playing),
                            path: playing,
                          ),
                        )
                        .title,
                    playing: c.isPlaying,
                    onToggle: c.togglePlayPause,
                    onOpen: () => RecordingNavigation.open(
                      context,
                      RecordingReference(
                        fileId: c.fileIdFromPath(playing),
                        path: playing,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
          Expanded(
            child: FilesBody(
              key: const ValueKey('library-files'),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              query: _query,
              typeFilter: _filter,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _newRecording(BuildContext context) async {
    final action = await showNewRecordingSheet(context);
    if (action == null || !context.mounted) return;
    await handleNewRecordingAction(context, action);
  }
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
      selectedColor: AppColors.mintSoft,
      side: BorderSide(
        color: selected ? AppColors.mintBorder : AppColors.border,
      ),
      labelStyle: TextStyle(
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected ? AppColors.mint : AppColors.textSecondary,
      ),
    );
  }
}

class _LibraryContinueCard extends StatelessWidget {
  const _LibraryContinueCard({
    required this.title,
    required this.playing,
    required this.onToggle,
    required this.onOpen,
  });

  final String title;
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
              color: AppColors.mint,
            ),
          ),
          Expanded(
            child: Text(
              '继续回听 · $title',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}
