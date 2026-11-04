import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/meeting_minutes.dart';
import '../../state/minutes_export.dart';
import '../../state/recording_analysis.dart';
import '../../state/recorder_controller.dart';
import '../../state/transcript_chapters.dart';
import '../transcript_jump.dart';
import 'minutes_mind_map.dart';
import 'minutes_topic_card.dart';
import 'minutes_terms.dart';
import '../../platform/device_kind.dart';

class MinutesPanel extends StatefulWidget {
  const MinutesPanel({
    super.key,
    required this.controller,
    required this.reference,
    this.onOpenSource,
  });
  final RecorderController controller;
  final RecordingReference reference;
  final ValueChanged<TranscriptJump>? onOpenSource;
  @override
  State<MinutesPanel> createState() => _MinutesPanelState();
}

class _MinutesPanelState extends State<MinutesPanel> {
  bool ready = false;
  String? loadError;
  String selectedTemplateId = minutesTemplateId;
  String selectedLanguage = 'zh';
  bool speakerNamingBusy = false;
  bool correctionBusy = false;
  String? lastCopiedRichHtml;
  RecordingAnalysis get manager => widget.controller.analysis;
  String get key =>
      '${widget.controller.analysisKey(widget.reference)}/minutes';
  @override
  void initState() {
    super.initState();
    manager.load().then(
      (_) {
        if (mounted) {
          final existing = manager.results[key]?.templateId;
          setState(() {
            if (existing != null &&
                builtInMeetingTemplates.any((t) => t.id == existing)) {
              selectedTemplateId = existing;
            }
            ready = true;
          });
        }
      },
      onError: (Object _) {
        if (mounted) setState(() => loadError = '无法读取纪要，请重试');
      },
    );
  }

  Future<void> generate(AnalysisResult? previous) async {
    var confirmedRestart = previous != null;
    if (previous != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('重新生成纪要？'),
          content: const Text('生成成功后将替换当前纪要，包括手动修改。取消或生成失败会保留原纪要。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('重新生成'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    } else if (manager.hasIncompleteJob(key)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('可能重复收费？'),
          content: const Text('上次生成尚未完成，或原文已变更。重新开始可能重复收费；取消不发送请求。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('继续生成'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      confirmedRestart = true;
    }
    await widget.controller.generateMinutes(
      widget.reference,
      templateId: selectedTemplateId,
      language: selectedLanguage,
      confirmedRestart: confirmedRestart,
    );
  }

  Future<void> export(
    MeetingMinutes minutes,
    AnalysisResult result, {
    MinutesExportFormat format = MinutesExportFormat.markdown,
  }) async {
    try {
      if (format == MinutesExportFormat.markdown) {
        final content = minutes.export(result);
        if (runsOnPhone) {
          final box = context.findRenderObject() as RenderBox?;
          await SharePlus.instance.share(
            ShareParams(
              text: content,
              title: '会议纪要',
              sharePositionOrigin: box == null
                  ? null
                  : box.localToGlobal(Offset.zero) & box.size,
            ),
          );
        } else {
          final location = await getSaveLocation(suggestedName: '会议纪要.md');
          if (location != null) {
            await File(location.path).writeAsString(content);
          }
        }
        return;
      }
      final bytes = format == MinutesExportFormat.docx
          ? minutes.exportDocxBytes(result)
          : minutes.exportPdfBytes(result);
      final suggested = '会议纪要.${format.extension}';
      if (runsOnPhone) {
        final box = context.findRenderObject() as RenderBox?;
        final tempDir = await Directory.systemTemp.createTemp('koe-minutes-');
        final file = File('${tempDir.path}/$suggested');
        await file.writeAsBytes(bytes, flush: true);
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: format.mimeType)],
            title: '会议纪要',
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(suggestedName: suggested);
        if (location != null) {
          await File(location.path).writeAsBytes(bytes, flush: true);
        }
      }
    } catch (_) {
      if (mounted) message('导出失败，请重试');
    }
  }

  Future<void> copyRichText(
    MeetingMinutes minutes,
    AnalysisResult result,
  ) async {
    final html = minutes.exportHtml(result);
    final plain = minutes.export(result);
    lastCopiedRichHtml = html;
    await Clipboard.setData(ClipboardData(text: plain));
    if (mounted) message('已复制富文本与纯文本');
  }

  Future<void> exportSubtitle({required bool vtt}) async {
    try {
      final content = vtt
          ? widget.controller.exportTranscriptVttText(widget.reference)
          : widget.controller.exportTranscriptSrtText(widget.reference);
      final ext = vtt ? 'vtt' : 'srt';
      final suggested = '逐字稿.$ext';
      if (runsOnPhone) {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            text: content,
            title: suggested,
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(suggestedName: suggested);
        if (location != null) {
          await File(location.path).writeAsString(content);
        }
      }
    } catch (_) {
      if (mounted) message('字幕导出失败，请重试');
    }
  }

  void message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _showReplaceTermDialog() async {
    final fromController = TextEditingController();
    final toController = TextEditingController();
    var applyAll = false;
    var addToVocab = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('查找替换'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('minutes-replace-from-input'),
                  controller: fromController,
                  decoration: const InputDecoration(
                    labelText: '原词（查找内容）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('minutes-replace-to-input'),
                  controller: toController,
                  decoration: const InputDecoration(
                    labelText: '替换为（正确用词）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Checkbox(
                      key: const ValueKey('minutes-replace-scope-all'),
                      value: applyAll,
                      onChanged: (v) =>
                          setModalState(() => applyAll = v ?? false),
                    ),
                    const Expanded(child: Text('应用到全部录音与纪要')),
                  ],
                ),
                Row(
                  children: [
                    Checkbox(
                      key: const ValueKey('minutes-replace-add-vocab'),
                      value: addToVocab,
                      onChanged: (v) =>
                          setModalState(() => addToVocab = v ?? true),
                    ),
                    const Expanded(child: Text('同时加入个人词汇表')),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('minutes-replace-submit'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('执行替换'),
            ),
          ],
        ),
      ),
    );
    final from = fromController.text.trim();
    final to = toController.text.trim();
    if (confirmed != true || from.isEmpty || from == to) return;
    try {
      final report = applyAll
          ? await widget.controller.replaceTermAcrossLibrary(
              from,
              to,
              addToVocabulary: addToVocab,
            )
          : await widget.controller.replaceTermInRecording(
              widget.reference,
              from,
              to,
              addToVocabulary: addToVocab,
            );
      if (!mounted) return;
      setState(() {});
      message(
        '已更新 ${report.recordingsUpdated} 条逐字稿、${report.minutesUpdated} 份纪要'
        '${report.addedToVocabulary ? '，并已加入词汇表' : ''}',
      );
    } catch (_) {
      if (!mounted) return;
      message(applyAll ? '替换未完成，部分记录可能已更新，请检查后重试' : '替换未完成，请检查逐字稿与纪要后重试');
    }
  }

  Future<void> _adoptTerm(
    AnalysisResult result,
    MeetingMinutes minutes,
    int index, {
    required bool replace,
  }) async {
    final term = minutes.terms[index];
    final counts = widget.controller.termReplacementCounts(
      widget.reference,
      term,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(replace ? '确认本场订正' : '加入个人词表'),
        content: SingleChildScrollView(
          child: Text(
            replace
                ? '仅影响本场逐字稿与纪要，不改其他录音。\n将以下识别写法改为「${term.name}」：\n${counts.entries.map((e) => '${e.key}：${e.value} 处').join('\n')}\n原纪要保留在版本历史中。'
                : '将「${term.name}」加入个人词表，供以后的转写参考。不会替换当前原文。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(replace ? '确认订正' : '确认加入词表'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.controller.adoptMinutesTerm(
        widget.reference,
        result,
        index,
        replace: replace,
      );
      if (mounted) message(replace ? '已订正本场原文，原纪要已保留' : '已加入词表，原文保持不变');
    } catch (error) {
      if (!mounted) return;
      final detail = error is FormatException
          ? error.message
          : error is StateError
          ? error.message
          : '请检查存储后重试';
      message('采纳未完成，部分内容可能已保存；$detail');
    }
  }

  Future<void> _showTermEvidence(MinuteTerm term) async {
    final fingerprint = term.adoption?.previousVersion;
    final previous = manager
        .versionsFor(key)
        .where((v) => minuteVersionFingerprint(v) == fingerprint)
        .firstOrNull;
    String content = '采纳前版本已不在保留的历史中，无法显示当时原文。';
    if (previous != null) {
      try {
        content = MeetingMinutes.parse(
          previous.text,
          previous.sources.length,
          sourceTexts: previous.sources,
        ).export(previous);
      } catch (_) {
        content = previous.text;
      }
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('采纳前原文'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(child: SelectableText(content)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showVersionHistory() async {
    final versions = manager.versionsFor(key);
    if (versions.isEmpty) return;
    String readable(AnalysisResult r) {
      try {
        return MeetingMinutes.parse(
          r.text,
          r.sources.length,
          sourceTexts: r.sources,
        ).export(r);
      } catch (_) {
        return r.text;
      }
    }

    String versionLabel(AnalysisResult r, int index) {
      final tag = r.isDraft
          ? '草稿版'
          : r.editedAt != null
          ? '手动编辑'
          : '正式生成';
      return '版本 ${index + 1} · $tag · ${r.createdAt.toIso8601String()}';
    }

    final selectedIndex = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('纪要版本历史'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: ListView.separated(
            itemCount: versions.length,
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (context, index) {
              final v = versions[index];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          versionLabel(v, index),
                          style: Theme.of(c).textTheme.titleSmall,
                        ),
                      ),
                      FilledButton.tonal(
                        key: ValueKey('minutes-restore-version-$index'),
                        onPressed: () => Navigator.pop(c, index),
                        child: const Text('复原此版本'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText(readable(v), maxLines: 6),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (selectedIndex != null && mounted) {
      try {
        await manager.restoreVersion(key, selectedIndex);
      } catch (_) {
        if (mounted) message('复原版本失败，请重试');
      }
    }
  }

  Future<void> _answerReviewItems(MeetingMinutes minutes) async {
    final controllers = <String, TextEditingController>{
      for (final q in minutes.reviewItems) q: TextEditingController(),
    };
    final submitted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('回答待确认问题并修订纪要'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, q) in minutes.reviewItems.indexed) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('${i + 1}. $q'),
                  ),
                  TextField(
                    key: ValueKey('minutes-review-answer-$i'),
                    controller: controllers[q],
                    decoration: const InputDecoration(
                      hintText: '输入确认结果（留空则暂不回答）',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('minutes-review-submit'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('据此修订纪要'),
          ),
        ],
      ),
    );
    final answers = <String, String>{
      for (final e in controllers.entries)
        if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final ctrl in controllers.values) {
        ctrl.dispose();
      }
    });
    if (submitted == true && answers.isNotEmpty && mounted) {
      try {
        await widget.controller.reviseMinutesWithReviewAnswers(
          widget.reference,
          answers,
          language: selectedLanguage,
        );
      } catch (e) {
        if (mounted) message('$e');
      }
    }
  }

  Future<void> _runSpeakerNaming() async {
    setState(() => speakerNamingBusy = true);
    try {
      await widget.controller.suggestSpeakerNames(widget.reference);
    } catch (e) {
      if (mounted) message('$e');
    } finally {
      if (mounted) setState(() => speakerNamingBusy = false);
    }
  }

  Future<void> _runTranscriptCorrections() async {
    setState(() => correctionBusy = true);
    try {
      await widget.controller.suggestTranscriptCorrections(widget.reference);
    } catch (e) {
      if (mounted) message('$e');
    } finally {
      if (mounted) setState(() => correctionBusy = false);
    }
  }

  void _openSource(
    int sourceIndex,
    String source,
    TranscriptSourceMatch? match,
  ) {
    if (match != null && widget.onOpenSource != null) {
      widget.onOpenSource!(
        TranscriptJump(
          segmentIndex: match.segmentIndex,
          start: match.start,
          snippet: match.snippet,
        ),
      );
      return;
    }
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('原文 [S${sourceIndex + 1}]'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (match == null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('无法可靠定位到原声；以下是模型使用的原文片段。'),
                ),
              SelectableText(source),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _compare(AnalysisResult current, AnalysisResult previous) async {
    String readable(AnalysisResult result) {
      try {
        return MeetingMinutes.parse(
          result.text,
          result.sources.length,
          sourceTexts: result.sources,
        ).export(result);
      } catch (_) {
        return result.text;
      }
    }

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('与上一版对比'),
        content: SizedBox(
          width: 720,
          height: 480,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '上一版${previous.editedAt == null ? '（生成）' : '（人工编辑）'}',
                      style: Theme.of(c).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        child: SelectableText(readable(previous)),
                      ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '当前版本${current.editedAt == null ? '（生成）' : '（人工编辑）'}',
                      style: Theme.of(c).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        child: SelectableText(readable(current)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> edit(MeetingMinutes minutes, AnalysisResult result) async {
    final title = TextEditingController(text: minutes.title);
    final overview = TextEditingController(text: minutes.overview);
    final fields =
        <
          (
            MinuteItem,
            TextEditingController,
            TextEditingController?,
            TextEditingController?,
          )
        >[
          for (final section in minutes.sections)
            for (final item in section.$2)
              (
                item,
                TextEditingController(text: item.text),
                item.owner == null
                    ? null
                    : TextEditingController(text: item.owner),
                item.due == null ? null : TextEditingController(text: item.due),
              ),
        ];
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('编辑纪要'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: '主题'),
                ),
                TextField(
                  controller: overview,
                  minLines: 2,
                  maxLines: null,
                  decoration: const InputDecoration(labelText: '概览'),
                ),
                for (final section in minutes.sections) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Text(section.$1),
                  ),
                  for (final item in section.$2) ...[
                    TextField(
                      controller: fields
                          .firstWhere((f) => identical(f.$1, item))
                          .$2,
                      minLines: 1,
                      maxLines: null,
                      decoration: const InputDecoration(labelText: '内容'),
                    ),
                    if (item.owner != null) ...[
                      TextField(
                        controller: fields
                            .firstWhere((f) => identical(f.$1, item))
                            .$3,
                        decoration: const InputDecoration(labelText: '负责人'),
                      ),
                      TextField(
                        controller: fields
                            .firstWhere((f) => identical(f.$1, item))
                            .$4,
                        decoration: const InputDecoration(labelText: '期限'),
                      ),
                    ],
                  ],
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('保存修改'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      try {
        List<MinuteItem> edited(List<MinuteItem> items) => items.map((item) {
          final f = fields.firstWhere((f) => identical(f.$1, item));
          if (item is MinuteTopic) {
            return MinuteTopic(
              f.$2.text,
              item.sources,
              summary: item.summary,
              points: item.points,
              fishbone: item.fishbone,
            );
          }
          return MinuteItem(
            f.$2.text,
            item.sources,
            owner: f.$3?.text,
            due: f.$4?.text,
          );
        }).toList();
        final changed = MeetingMinutes(
          title: title.text,
          overview: overview.text,
          topics: edited(minutes.topics),
          decisions: edited(minutes.decisions),
          actions: edited(minutes.actions),
          questions: edited(minutes.questions),
          custom: [
            for (final sec in minutes.custom)
              MinuteCustomSection(title: sec.title, items: edited(sec.items)),
          ],
          reviewItems: minutes.reviewItems,
          schemaVersion: minutes.schemaVersion,
          terms: minutes.terms,
        );
        await manager.editResult(
          key,
          result,
          validateMinutes(changed.encode(), result.sources),
        );
      } catch (_) {
        message('保存失败，请确认字段不为空，并重新打开最新纪要');
      }
    }
    // Dialog route finishes its exit animation before disposing its controllers.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    title.dispose();
    overview.dispose();
    for (final f in fields) {
      f.$2.dispose();
      f.$3?.dispose();
      f.$4?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([manager, widget.controller]),
    builder: (context, _) {
      final view = widget.controller.recordingView(widget.reference);
      final result = manager.results[key];
      final sourceHash = analysisFingerprint(view.text.trim());
      final previous = manager.previousResults[key];
      final versions = manager.versionsFor(key);
      final vocabSuggestions = widget.controller.suggestVocabularyFor(
        widget.reference,
      );
      final speakerSuggestions = widget.controller.speakerNameSuggestionsFor(
        widget.reference,
      );
      final correctionSuggestions = widget.controller.transcriptCorrectionsFor(
        widget.reference,
      );
      final canRevertCorrection = widget.controller
          .canRevertTranscriptCorrection(widget.reference);
      MeetingMinutes? minutes;
      if (result != null) {
        try {
          minutes = MeetingMinutes.parse(
            result.text,
            result.sources.length,
            sourceTexts: result.sources,
          );
        } catch (_) {}
      }
      final busy = manager.busy(key);
      final running = manager.running(key);
      final notes = widget.controller.bookmarksFor(widget.reference).length;
      final sourceMatches = <int, TranscriptSourceMatch>{};
      if (result != null &&
          result.sourceHash == sourceHash &&
          !widget.controller.recordingAudioChanged(widget.reference) &&
          view.originalPresent &&
          view.path != null) {
        final aliases = widget.controller.speakerAliasesForPath(view.path!);
        final timed =
            transcriptSegmentsMatchText(
              view.segments,
              view.text,
              aliases: aliases,
            ) &&
            transcriptSegmentsLocatable(
              view.segments,
              duration: widget.controller.localDurationForPath(view.path!),
            );
        if (timed) {
          for (final match in matchTranscriptSources(
            sources: result.sources,
            segments: view.segments,
            aliases: aliases,
            duration: widget.controller.localDurationForPath(view.path!),
          )) {
            sourceMatches[match.sourceIndex] = match;
          }
        }
      }
      Widget sources(List<String> ids) {
        if (result == null) return const SizedBox();
        return Wrap(
          spacing: 4,
          children: [
            for (final index
                in ids
                    .map((id) => int.parse(id.substring(1)) - 1)
                    .where(
                      (index) => index >= 0 && index < result.sources.length,
                    ))
              TextButton(
                onPressed: () => _openSource(
                  index,
                  result.sources[index],
                  sourceMatches[index],
                ),
                child: Text(
                  sourceMatches[index] == null
                      ? '出处 [S${index + 1}]'
                      : '出处 [S${index + 1}] ${_time(sourceMatches[index]!.start)}',
                ),
              ),
          ],
        );
      }

      String? sourcePosition(MinuteTopic topic) {
        final starts =
            topic.sources
                .map(
                  (id) => sourceMatches[int.parse(id.substring(1)) - 1]?.start,
                )
                .whereType<Duration>()
                .toList()
              ..sort();
        return starts.isEmpty ? null : _time(starts.first);
      }

      Widget itemCard(MinuteItem item) => item is MinuteTopic
          ? MinutesTopicCard(
              topic: item,
              sources: sources,
              sourcePosition: sourcePosition(item),
            )
          : Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(item.text),
                    if (item.owner != null)
                      Text('负责人：${item.owner} · 期限：${item.due}'),
                    sources(item.sources),
                  ],
                ),
              ),
            );
      return Scaffold(
        appBar: AppBar(
          title: const Text('结构化纪要'),
          actions: [
            TextButton(
              onPressed: minutes == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MinutesMindMap(
                          controller: widget.controller,
                          reference: widget.reference,
                        ),
                      ),
                    ),
              child: const Text('思维导图'),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(view.title, style: Theme.of(context).textTheme.titleLarge),
              Text(
                '${widget.controller.analysisBackendSummary} · '
                '${meetingTemplateById(selectedTemplateId).labelForLanguage(selectedLanguage)}',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tpl in builtInMeetingTemplates)
                    ChoiceChip(
                      key: ValueKey('minutes-template-${tpl.id}'),
                      label: Text(tpl.nameZh),
                      selected: selectedTemplateId == tpl.id,
                      onSelected: busy
                          ? null
                          : (_) => setState(() => selectedTemplateId = tpl.id),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final lang in const [
                    ('zh', '中文'),
                    ('en', 'English'),
                    ('ja', '日本語'),
                  ])
                    ChoiceChip(
                      key: ValueKey('minutes-language-${lang.$1}'),
                      label: Text(lang.$2),
                      selected: selectedLanguage == lang.$1,
                      onSelected: busy
                          ? null
                          : (_) => setState(() => selectedLanguage = lang.$1),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (loadError != null) Text(loadError!),
              if (view.text.trim().isEmpty) const Text('请先完成转写'),
              if (widget.controller.analysisApiKey.isEmpty)
                Text(
                  widget.controller.analysisBackend == AnalysisBackendKind.none
                      ? '当前整理后端设为“不整理”，请在设置中选择千问或 OpenAI 兼容后端'
                      : widget.controller.analysisBackend ==
                            AnalysisBackendKind.openaiCompatible
                      ? '请先在设置中配置 OpenAI 兼容服务地址、模型名称（远程服务还需 API Key）'
                      : '请先在设置中配置千问 API Key',
                ),
              const SizedBox(height: 12),
              if (busy) ...[
                const LinearProgressIndicator(),
                Text(manager.progress[key] ?? '正在整理纪要'),
                if (running)
                  TextButton(
                    onPressed: () => manager.cancel(key),
                    child: const Text('取消生成'),
                  ),
              ] else
                FilledButton(
                  onPressed:
                      !ready ||
                          widget.controller.recordingAudioChanged(
                            widget.reference,
                          ) ||
                          view.live ||
                          view.text.trim().isEmpty ||
                          widget.controller.analysisApiKey.isEmpty
                      ? null
                      : () => generate(result),
                  child: Text(result == null ? '生成纪要' : '重新生成纪要'),
                ),
              if (!busy && notes > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '生成时一并参考这条录音的 $notes 条书签（笔记和重点）。',
                    key: const ValueKey('minutes-notes-hint'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (manager.errors[key] != null) Text(manager.errors[key]!),
              if (result != null &&
                  (widget.controller.recordingAudioChanged(widget.reference) ||
                      result.sourceHash != sourceHash))
                const Text('原文已更新，这份纪要已过期，请重新生成。'),
              if (result != null && minutes == null) ...[
                const Text('当前纪要格式无法结构化显示或编辑；原数据仍保留。'),
                TextButton(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: result.text)),
                  child: const Text('复制原始结果'),
                ),
              ],
              if (result != null && minutes != null) ...[
                const SizedBox(height: 16),
                Text(
                  minutes.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                SelectableText(minutes.overview),
                Text(
                  '${result.model} · '
                  '${result.isDraft ? '草稿纪要（实时识别生成）' : (result.editedAt == null ? '已生成' : '已手动编辑')}',
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: busy ? null : () => edit(minutes!, result),
                        child: const Text('编辑纪要'),
                      ),
                      TextButton(
                        key: const ValueKey('minutes-replace-term-button'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: busy ? null : _showReplaceTermDialog,
                        child: const Text('查找替换'),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: minutes!.export(result)),
                        ),
                        child: const Text('复制纪要'),
                      ),
                      TextButton(
                        key: const ValueKey('minutes-copy-rich'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: () => copyRichText(minutes!, result),
                        child: const Text('复制富文本'),
                      ),
                      TextButton(
                        key: const ValueKey('minutes-export-md'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: () => export(minutes!, result),
                        child: const Text('导出纪要'),
                      ),
                      if (previous != null)
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                          onPressed: () => _compare(result, previous),
                          child: const Text('对比上一版'),
                        ),
                      if (versions.isNotEmpty)
                        TextButton(
                          key: const ValueKey('minutes-version-history-button'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                          onPressed: _showVersionHistory,
                          child: Text('版本历史 (${versions.length})'),
                        ),
                      TextButton(
                        key: const ValueKey('minutes-export-docx'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: () => export(
                          minutes!,
                          result,
                          format: MinutesExportFormat.docx,
                        ),
                        child: const Text('导出 Word'),
                      ),
                      TextButton(
                        key: const ValueKey('minutes-export-pdf'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: () => export(
                          minutes!,
                          result,
                          format: MinutesExportFormat.pdf,
                        ),
                        child: const Text('导出 PDF'),
                      ),
                      TextButton(
                        key: const ValueKey('minutes-export-srt'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: () => exportSubtitle(vtt: false),
                        child: const Text('导出 SRT'),
                      ),
                      TextButton(
                        key: const ValueKey('minutes-export-vtt'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: () => exportSubtitle(vtt: true),
                        child: const Text('导出 VTT'),
                      ),
                    ],
                  ),
                ),
                for (final section in minutes.sections) ...[
                  if (section.$1 == '未决问题' && minutes.terms.isNotEmpty)
                    MinutesTerms(
                      terms: minutes.terms,
                      sources: sources,
                      replacementCount: (term) => widget.controller
                          .termReplacementCounts(widget.reference, term)
                          .values
                          .fold(0, (a, b) => a + b),
                      onVocabulary:
                          busy ||
                              result.sourceHash != sourceHash ||
                              widget.controller.recordingAudioChanged(
                                widget.reference,
                              )
                          ? null
                          : (index) => _adoptTerm(
                              result,
                              minutes!,
                              index,
                              replace: false,
                            ),
                      onReplace:
                          busy ||
                              result.sourceHash != sourceHash ||
                              widget.controller.recordingAudioChanged(
                                widget.reference,
                              )
                          ? null
                          : (index) => _adoptTerm(
                              result,
                              minutes!,
                              index,
                              replace: true,
                            ),
                      onEvidence: (index) =>
                          _showTermEvidence(minutes!.terms[index]),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      section.$1,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (section.$2.isEmpty) const Text('未提及'),
                  for (final item in section.$2) itemCard(item),
                ],
                if (minutes.reviewItems.isNotEmpty)
                  Card(
                    key: const ValueKey('minutes-review-items-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '待确认问题（${minutes.reviewItems.length}）',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              FilledButton.tonal(
                                key: const ValueKey(
                                  'minutes-review-items-button',
                                ),
                                onPressed: busy
                                    ? null
                                    : () => _answerReviewItems(minutes!),
                                child: const Text('回答并修订纪要'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          for (final q in minutes.reviewItems)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text('• $q'),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
              if (vocabSuggestions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '建议加入个人词汇表：',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final term in vocabSuggestions.take(8))
                      ActionChip(
                        key: ValueKey('vocab-suggest-$term'),
                        label: Text('+ $term'),
                        onPressed: () =>
                            widget.controller.addVocabularyTerm(term),
                      ),
                  ],
                ),
              ],
              if (view.text.trim().isNotEmpty &&
                  widget.controller.analysisApiKey.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      key: const ValueKey('minutes-suggest-speakers'),
                      onPressed: speakerNamingBusy ? null : _runSpeakerNaming,
                      child: Text(speakerNamingBusy ? '正在推测发言人…' : 'AI 猜发言人名字'),
                    ),
                    OutlinedButton(
                      key: const ValueKey('minutes-suggest-corrections'),
                      onPressed: correctionBusy
                          ? null
                          : _runTranscriptCorrections,
                      child: Text(correctionBusy ? '正在检查错词…' : 'AI 校正建议'),
                    ),
                    if (canRevertCorrection)
                      TextButton(
                        key: const ValueKey('revert-transcript-correction'),
                        onPressed: () => widget.controller
                            .revertTranscriptCorrection(widget.reference),
                        child: const Text('还原校正'),
                      ),
                  ],
                ),
              ],
              for (final s in speakerSuggestions)
                Card(
                  child: ListTile(
                    title: Text('说话人 ${s.speakerId} → ${s.suggestedName}'),
                    subtitle: Text(
                      [
                        s.reason,
                        if (s.evidenceQuote != null) '「${s.evidenceQuote}」',
                      ].join('\n'),
                    ),
                    trailing: FilledButton.tonal(
                      key: ValueKey('apply-speaker-suggestion-${s.speakerId}'),
                      onPressed: () => widget.controller
                          .applySpeakerNameSuggestion(widget.reference, s),
                      child: const Text('套用'),
                    ),
                  ),
                ),
              for (final c in correctionSuggestions)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${c.wrong} → ${c.right}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(c.reason),
                        if (c.contextQuote != null) Text('「${c.contextQuote}」'),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              key: ValueKey('accept-correction-${c.wrong}'),
                              onPressed: () =>
                                  widget.controller.acceptTranscriptCorrection(
                                    widget.reference,
                                    c,
                                  ),
                              child: const Text('接受'),
                            ),
                            TextButton(
                              key: ValueKey(
                                'accept-correction-vocab-${c.wrong}',
                              ),
                              onPressed: () =>
                                  widget.controller.acceptTranscriptCorrection(
                                    widget.reference,
                                    c,
                                    addToVocabulary: true,
                                  ),
                              child: const Text('接受并加词汇表'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

String _time(Duration value) {
  final total = value.inSeconds.clamp(0, 359999);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int part) => part.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}
