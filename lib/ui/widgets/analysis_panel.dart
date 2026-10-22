import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/recorder_controller.dart';
import '../../state/recording_analysis.dart';
import '../../theme/app_theme.dart';
import '../transcript_jump.dart';
import 'minutes_panel.dart';
import '../../platform/device_kind.dart';

class AnalysisPanel extends StatefulWidget {
  const AnalysisPanel({
    super.key,
    required this.controller,
    required this.reference,
    this.onOpenSource,
  });
  final RecorderController controller;
  final RecordingReference reference;
  final ValueChanged<TranscriptJump>? onOpenSource;
  @override
  State<AnalysisPanel> createState() => _AnalysisPanelState();
}

class _AnalysisPanelState extends State<AnalysisPanel> {
  final instruction = TextEditingController();
  String selectedTemplateId = summaryTemplateId;
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

  PromptTemplate get selectedTemplate =>
      manager.templateById(selectedTemplateId) ??
      manager.requireTemplate(summaryTemplateId);

  Future<void> _openTemplateEditor({PromptTemplate? editing}) async {
    final saved = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _TemplateEditorDialog(editing: editing),
    );
    if (saved == null || !mounted) return;
    try {
      if (editing == null) {
        final created = await manager.createTemplate(
          name: saved.$1,
          prompt: saved.$2,
        );
        if (mounted) {
          setState(() {
            custom = false;
            selectedTemplateId = created.id;
          });
        }
      } else {
        await manager.updateTemplate(
          editing.id,
          name: saved.$1,
          prompt: saved.$2,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> exportAnalysis(AnalysisResult result) async {
    try {
      final contents = result.exportText;
      final isDefaultSummary =
          !custom && selectedTemplate.id == summaryTemplateId;
      if (runsOnPhone) {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            text: contents,
            title: isDefaultSummary ? '录音摘要' : '录音分析',
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(
          suggestedName: isDefaultSummary ? '录音摘要.md' : '录音分析.md',
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
      final activeTemplate = selectedTemplate;
      final key = custom
          ? RecordingAnalysis.key(recordingKey, true)
          : RecordingAnalysis.slotKey(
              recordingKey,
              custom: false,
              templateId: activeTemplate.id,
            );
      final result = manager.results[key];
      final busy = manager.busy(key);
      final running = manager.running(key);
      final notes = widget.controller.bookmarksFor(widget.reference).length;
      final audioChanged = widget.controller.recordingAudioChanged(
        widget.reference,
      );
      final sourceStale =
          result != null &&
          (audioChanged ||
              result.sourceHash != analysisFingerprint(recording.text));
      final templateStale = result != null && manager.isTemplateStale(result);
      final stale = sourceStale || templateStale;
      return Scaffold(
        appBar: AppBar(
          title: const Text('摘要与分析'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MinutesPanel(
                    controller: widget.controller,
                    reference: widget.reference,
                    onOpenSource: widget.onOpenSource,
                  ),
                ),
              ),
              child: const Text('结构化纪要'),
            ),
          ],
        ),
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
                onSelectionChanged: (v) => setState(() {
                  custom = v.first;
                  if (custom && instruction.text.trim().isEmpty) {
                    final saved =
                        manager.customInstructions[recordingKey] ??
                        manager
                            .results[RecordingAnalysis.key(recordingKey, true)]
                            ?.instruction;
                    if (saved != null && saved.isNotEmpty) {
                      instruction.text = saved;
                    }
                  }
                }),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '提示词模板库',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('create-template'),
                    onPressed: () => _openTemplateEditor(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新建模板'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tpl in manager.templates)
                    ChoiceChip(
                      key: ValueKey('template-chip-${tpl.id}'),
                      label: Text(tpl.name),
                      selected: !custom && activeTemplate.id == tpl.id,
                      onSelected: (_) => setState(() {
                        custom = false;
                        selectedTemplateId = tpl.id;
                      }),
                    ),
                ],
              ),
              if (!custom) ...[
                const SizedBox(height: 12),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${activeTemplate.name} · '
                                '${activeTemplate.builtIn ? '内置模板' : '自定义模板'} '
                                'v${activeTemplate.version}',
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('duplicate-template'),
                              onPressed: () async {
                                final copy = await manager.duplicateTemplate(
                                  activeTemplate.id,
                                );
                                if (mounted) {
                                  setState(() {
                                    custom = false;
                                    selectedTemplateId = copy.id;
                                  });
                                }
                              },
                              child: const Text('复制为自定义'),
                            ),
                            if (!activeTemplate.builtIn) ...[
                              TextButton(
                                key: const ValueKey('edit-template'),
                                onPressed: () => _openTemplateEditor(
                                  editing: activeTemplate,
                                ),
                                child: const Text('编辑模板'),
                              ),
                              TextButton(
                                key: const ValueKey('delete-template'),
                                onPressed: () async {
                                  await manager.deleteTemplate(
                                    activeTemplate.id,
                                  );
                                  if (mounted) {
                                    setState(
                                      () => selectedTemplateId =
                                          summaryTemplateId,
                                    );
                                  }
                                },
                                child: const Text('删除模板'),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        SelectableText(
                          activeTemplate.prompt,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
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
              if (audioChanged) const Text('音频内容已变化，请先重新转写；已有分析仅对应旧音频。'),
              if (recording.text.trim().isEmpty) const Text('请先完成这段录音的转写。'),
              if (widget.controller.analysisApiKey.isEmpty)
                const Text('请先在设置中配置千问 API Key。'),
              if (busy) ...[
                const LinearProgressIndicator(),
                Text(manager.progress[key] ?? '正在准备分析'),
                if (running)
                  TextButton(
                    onPressed: () => manager.cancel(key),
                    child: const Text('取消分析'),
                  ),
              ] else
                FilledButton(
                  key: const ValueKey('generate-analysis'),
                  onPressed:
                      !ready ||
                          audioChanged ||
                          recording.live ||
                          recording.text.trim().isEmpty ||
                          widget.controller.analysisApiKey.isEmpty
                      ? null
                      : () => manager.run(
                          recording: recordingKey,
                          source: recording.text,
                          apiKey: widget.controller.analysisApiKey,
                          custom: custom,
                          templateId: custom ? null : activeTemplate.id,
                          instruction: custom ? instruction.text : null,
                          userNotes: widget.controller.analysisNotesFor(
                            widget.reference,
                          ),
                          currentSource: () =>
                              widget.controller.recordingAudioChanged(
                                widget.reference,
                              )
                              ? ''
                              : widget.controller
                                    .recordingView(widget.reference)
                                    .text,
                        ),
                  child: Text(
                    result == null
                        ? (custom || activeTemplate.id != summaryTemplateId
                              ? '开始分析'
                              : '生成摘要')
                        : '重新生成',
                  ),
                ),
              if (!busy && notes > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '生成时一并参考这条录音的 $notes 条书签（笔记和重点）。',
                    key: const ValueKey('analysis-notes-hint'),
                    style: Theme.of(context).textTheme.bodySmall,
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
                  Text(
                    sourceStale
                        ? '原文已更新，这份结果已过期，请重新生成。'
                        : '模板已更新，这份结果已过期，请重新生成。',
                    style: const TextStyle(color: AppColors.amber),
                  ),
                Text(
                  '${result.model} · ${result.createdAt.toLocal().toString().split('.').first}',
                ),
                const SizedBox(height: 12),
                if (custom || result.templateId != summaryTemplateId)
                  Text('分析要求：${result.instruction}'),
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

class _TemplateEditorDialog extends StatefulWidget {
  const _TemplateEditorDialog({this.editing});
  final PromptTemplate? editing;

  @override
  State<_TemplateEditorDialog> createState() => _TemplateEditorDialogState();
}

class _TemplateEditorDialogState extends State<_TemplateEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.editing?.name ?? '',
  );
  late final TextEditingController _prompt = TextEditingController(
    text: widget.editing?.prompt ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    if (name.isEmpty || name.runes.length > 100) {
      setState(() => _error = '模板名称需为 1–100 字');
      return;
    }
    if (prompt.isEmpty || prompt.runes.length > 2000) {
      setState(() => _error = '提示词正文需为 1–2000 字');
      return;
    }
    Navigator.of(context).pop((name, prompt));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.editing == null ? '新建模板' : '编辑模板'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('template-name-input'),
              controller: _name,
              maxLength: 100,
              decoration: const InputDecoration(
                labelText: '模板名称',
                hintText: '例如：提炼行动项',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('template-prompt-input'),
              controller: _prompt,
              maxLines: 4,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: '提示词正文',
                hintText: '输入希望 AI 执行的整理指令',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('save-template'),
        onPressed: _submit,
        child: const Text('保存'),
      ),
    ],
  );
}
