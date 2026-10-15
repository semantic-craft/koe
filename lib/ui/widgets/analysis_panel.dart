import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';
import '../../state/recorder_controller.dart';
import '../../state/recording_analysis.dart';

class AnalysisPanel extends StatefulWidget {
  const AnalysisPanel({
    super.key,
    required this.controller,
    required this.reference,
  });
  final RecorderController controller;
  final RecordingReference reference;
  @override
  State<AnalysisPanel> createState() => _AnalysisPanelState();
}

class _AnalysisPanelState extends State<AnalysisPanel> {
  final instruction = TextEditingController();
  bool custom = false;
  bool ready = false;
  String? loadError;
  RecordingAnalysis get manager => widget.controller.analysis;
  @override
  void initState() {
    super.initState();
    manager.load().then(
      (_) {
        if (mounted) setState(() => ready = true);
      },
      onError: (Object e) {
        if (mounted) setState(() => loadError = '无法读取已有分析，请检查存储空间后重试');
      },
    );
  }

  @override
  void dispose() {
    instruction.dispose();
    super.dispose();
  }

  Future<void> exportAnalysis(AnalysisResult result) async {
    try {
      final contents = result.exportText;
      if (Platform.isIOS) {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            text: contents,
            title: custom ? '录音分析' : '录音摘要',
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(
          suggestedName: custom ? '录音分析.md' : '录音摘要.md',
        );
        if (location != null) await File(location.path).writeAsString(contents);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导出失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([manager, widget.controller]),
    builder: (context, _) {
      final recording = widget.controller.recordingView(widget.reference);
      final recordingKey = widget.controller.analysisKey(widget.reference);
      final key = RecordingAnalysis.key(recordingKey, custom);
      final result = manager.results[key];
      final busy = manager.busy(key);
      final stale =
          result != null &&
          result.sourceHash != analysisFingerprint(recording.text);
      return Scaffold(
        appBar: AppBar(title: const Text('摘要与分析')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                recording.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              const Text('千问 Qwen3.8-Flash · 使用已配置的千问 Key'),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('摘要')),
                  ButtonSegment(value: true, label: Text('自定义分析')),
                ],
                selected: {custom},
                onSelectionChanged: (v) => setState(() => custom = v.first),
              ),
              if (custom)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: TextField(
                    key: const ValueKey('analysis-instruction'),
                    controller: instruction,
                    maxLines: 3,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                      labelText: '分析要求',
                      hintText: '例如：提取待办、负责人和未决问题',
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              if (loadError != null) Text(loadError!),
              if (recording.text.trim().isEmpty) const Text('请先完成这段录音的转写。'),
              if (widget.controller.analysisApiKey.isEmpty)
                const Text('请先在设置中配置千问 API Key。'),
              if (busy) ...[
                const LinearProgressIndicator(),
                Text(manager.progress[key] ?? '正在准备分析'),
                TextButton(
                  onPressed: () => manager.cancel(key),
                  child: const Text('取消分析'),
                ),
              ] else
                FilledButton(
                  key: const ValueKey('generate-analysis'),
                  onPressed:
                      !ready ||
                          recording.live ||
                          recording.text.trim().isEmpty ||
                          widget.controller.analysisApiKey.isEmpty
                      ? null
                      : () => manager.run(
                          recording: recordingKey,
                          source: recording.text,
                          apiKey: widget.controller.analysisApiKey,
                          custom: custom,
                          instruction: instruction.text,
                          currentSource: () => widget.controller
                              .recordingView(widget.reference)
                              .text,
                        ),
                  child: Text(
                    result == null ? (custom ? '开始分析' : '生成摘要') : '重新生成',
                  ),
                ),
              if (manager.errors[key] != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(manager.errors[key]!),
                ),
              if (result != null) ...[
                const Divider(height: 32),
                if (stale)
                  const Text(
                    '原文已更新，这份结果已过期，请重新生成。',
                    style: TextStyle(color: Colors.orange),
                  ),
                Text(
                  '${result.model} · ${result.createdAt.toLocal().toString().split('.').first}',
                ),
                const SizedBox(height: 12),
                if (custom) Text('分析要求：${result.instruction}'),
                SelectableText(result.text),
                Wrap(
                  spacing: 12,
                  children: [
                    TextButton.icon(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: result.exportText),
                      ),
                      icon: const Icon(Icons.copy),
                      label: const Text('复制'),
                    ),
                    TextButton.icon(
                      onPressed: () => exportAnalysis(result),
                      icon: const Icon(Icons.ios_share),
                      label: const Text('导出'),
                    ),
                  ],
                ),
                ExpansionTile(
                  title: const Text('查看原文依据'),
                  children: [
                    for (final source in result.sources.indexed)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          '[S${source.$1 + 1}] ${source.$2}',
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
