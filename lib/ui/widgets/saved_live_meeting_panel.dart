import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/recorder_controller.dart';
import '../../state/live_minutes_store.dart';
import '../../state/meeting_minutes.dart';
import '../../state/recording_analysis.dart';

class SavedLiveMeetingPanel extends StatefulWidget {
  const SavedLiveMeetingPanel({super.key, required this.recordingKey});
  final String recordingKey;
  @override
  State<SavedLiveMeetingPanel> createState() => _SavedLiveMeetingPanelState();
}

class _SavedLiveMeetingPanelState extends State<SavedLiveMeetingPanel> {
  LiveMinutesStore? _store;
  Future<List<Map<String, dynamic>>>? _records;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.read<RecorderController>().liveMeetingStore;
    if (_store != store) {
      _store = store;
      _records = store.all();
    }
  }

  @override
  void didUpdateWidget(covariant SavedLiveMeetingPanel old) {
    super.didUpdateWidget(old);
    if (old.recordingKey != widget.recordingKey) _records = _store!.all();
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<Map<String, dynamic>>>(
        future: _records,
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Text('实时资料暂无法读取');
          final controller = context.read<RecorderController>();
          final records = (snapshot.data ?? [])
              .where(
                (j) => controller.liveRecordMatchesRecordingKey(
                  j,
                  widget.recordingKey,
                ),
              )
              .toList();
          if (records.isEmpty) return const SizedBox.shrink();
          return ExpansionTile(
            title: const Text('本场实时速记与字幕'),
            subtitle: const Text('当时的原文快照 · 只读，不据此推断回听时间'),
            children: [
              for (final j in records)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (j['requestStatus'] == 'pending' ||
                          j['requestStatus'] == 'unknown' ||
                          (j['journal'] is Map &&
                              (j['journal'] as Map).values.any(
                                (s) => s == 'pending' || s == 'unknown',
                              )))
                        const Text('上次请求结果未知，未自动重发'),
                      if (j['error'] != null) Text(j['error'] as String),
                      if (j['active'] case final String raw)
                        _minutes(raw, (j['sources'] as List).cast<String>()),
                      for (final e in j['entries'] as List? ?? [])
                        SelectableText(
                          '${e['text']}\n${e['translation'] ?? ''}',
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      );
  Widget _minutes(String raw, List<String> sources) {
    try {
      final result = AnalysisResult(
        text: raw,
        sourceHash: '',
        model: 'live',
        instruction: '',
        sources: sources,
        createdAt: DateTime(2000),
        isDraft: true,
      );
      return SelectableText(
        MeetingMinutes.parse(
          raw,
          sources.length,
          sourceTexts: sources,
        ).export(result),
      );
    } catch (_) {
      return const Text('速记格式无法读取，请更新 App');
    }
  }
}
