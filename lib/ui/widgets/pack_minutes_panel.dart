import 'package:flutter/material.dart';

import '../../state/material_pack.dart';
import '../../state/meeting_minutes.dart';
import '../../state/recording_analysis.dart';

/// Reads the pack's sole stored snapshot. No audio controls or edits are
/// offered until the original has been paired and restored to a recording.
class PackMinutesPanel extends StatelessWidget {
  const PackMinutesPanel({super.key, required this.manifest});
  final Object? manifest;

  String _reading(AnalysisResult result) {
    final minutes = MeetingMinutes.parse(
      result.text,
      result.sources.length,
      sourceTexts: result.sources,
    );
    final decisions = [
      for (final term in minutes.terms)
        if (term.adoption case final adoption?)
          '${term.name}：${adoption.kind == 'vocabulary' ? '已加入词表' : '已订正本场原文'}，${adoption.at.toIso8601String()}',
    ];
    return [
      minutes.export(result),
      if (decisions.isNotEmpty) '术语采纳记录\n${decisions.join('\n')}',
    ].join('\n\n');
  }

  @override
  Widget build(BuildContext context) {
    if (manifest == null) return const SizedBox.shrink();
    final PackMinutes? minutes;
    try {
      minutes = MaterialPack.fromJson(manifest).minutes;
    } on MaterialPackException {
      return const Text('资料包纪要无法读取，请更新 App 或重新导入资料包。');
    }
    if (minutes == null) return const SizedBox.shrink();
    final history = minutes.history;
    return ExpansionTile(
      key: const ValueKey('pack-minutes'),
      title: const Text('包内纪要'),
      subtitle: const Text('只读；原文依据为当时的快照'),
      childrenPadding: const EdgeInsets.all(12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (history.isNotEmpty)
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('资料包纪要历史'),
                content: SizedBox(
                  width: 640,
                  height: 420,
                  child: ListView.separated(
                    itemCount: history.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (_, index) =>
                        SelectableText(_reading(history[index])),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            child: Text('查看纪要历史（${history.length}）'),
          ),
        SelectableText(_reading(minutes.current)),
      ],
    );
  }
}
