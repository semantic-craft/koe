import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:graphview/GraphView.dart';
import '../../state/meeting_minutes.dart';
import '../../state/recording_analysis.dart';
import '../../state/recorder_controller.dart';
import 'koe_icon_button.dart';

class MinuteMapNode {
  const MinuteMapNode(this.id, this.text, {this.parent, this.item});
  final String id, text;
  final String? parent;
  final MinuteItem? item;
}

List<MinuteMapNode> minuteMapNodes(MeetingMinutes minutes) => [
  MinuteMapNode('root', minutes.title),
  for (final section in minutes.sections.indexed) ...[
    MinuteMapNode('section:${section.$1}', section.$2.$1, parent: 'root'),
    for (final item in section.$2.$2.indexed)
      MinuteMapNode(
        '${section.$1}:${item.$1}',
        item.$2.text,
        parent: 'section:${section.$1}',
        item: item.$2,
      ),
    if (section.$2.$2.isEmpty)
      MinuteMapNode(
        '${section.$1}:empty',
        '未提及',
        parent: 'section:${section.$1}',
      ),
  ],
];

class MinuteMapLayout {
  MinuteMapLayout(this.nodes, this.title, this.metadata) {
    final graph = Graph()..isTree = true;
    final mapped = <String, Node>{};
    for (final item in nodes) {
      final text = TextPainter(
        text: TextSpan(text: item.text, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 210);
      final node = Node.Id(item.id)
        ..size = Size(242, math.max(60, text.height + 28));
      mapped[item.id] = node;
      graph.addNode(node);
      if (item.parent != null) graph.addEdge(mapped[item.parent]!, node);
    }
    final config = BuchheimWalkerConfiguration(
      siblingSeparation: 24,
      subtreeSeparation: 30,
      levelSeparation: 60,
      orientation: BuchheimWalkerConfiguration.ORIENTATION_LEFT_RIGHT,
    );
    BuchheimWalkerAlgorithm(
      config,
      TreeEdgeRenderer(config),
    ).run(graph, 20, 100);
    for (final e in mapped.entries) {
      rects[e.key] = e.value.position & e.value.size;
    }
    var width = 650.0, height = 180.0;
    for (final rect in rects.values) {
      width = math.max(width, rect.right + 24);
      height = math.max(height, rect.bottom + 24);
    }
    size = Size(width, height);
  }
  static const textStyle = TextStyle(
    fontSize: 15,
    height: 1.4,
    color: Color(0xff292724),
  );
  final List<MinuteMapNode> nodes;
  final String title, metadata;
  final rects = <String, Rect>{};
  late final Size size;

  Future<List<int>> png() async {
    final ratio = math.min(
      1.5,
      math.min(
        8192 / math.max(size.width, size.height),
        math.sqrt(16000000 / (size.width * size.height)),
      ),
    );
    if (ratio < .65) throw StateError('导图过大，请导出文字纪要以保留全部内容');
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    MinuteMapPainter(this).paint(canvas, size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (size.width * ratio).ceil(),
      (size.height * ratio).ceil(),
    );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
}

class MinuteMapPainter extends CustomPainter {
  MinuteMapPainter(this.layout);
  final MinuteMapLayout layout;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    void text(String value, Offset offset, double width, TextStyle style) {
      (TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width)).paint(canvas, offset);
    }

    // The header is bounded to one line; full recording title remains in root/details.
    final header = TextPainter(
      text: TextSpan(
        text: layout.title,
        style: const TextStyle(
          fontSize: 20,
          color: Colors.black,
          fontWeight: FontWeight.bold,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 40);
    header.paint(canvas, const Offset(20, 16));
    text(
      layout.metadata,
      const Offset(20, 52),
      size.width - 40,
      const TextStyle(fontSize: 12, color: Color(0xff666666)),
    );
    for (final node in layout.nodes) {
      final r = layout.rects[node.id]!;
      if (node.parent != null) {
        final parent = layout.rects[node.parent]!;
        canvas.drawPath(
          Path()
            ..moveTo(parent.right, parent.center.dy)
            ..cubicTo(
              parent.right + 30,
              parent.center.dy,
              r.left - 30,
              r.center.dy,
              r.left,
              r.center.dy,
            ),
          Paint()
            ..color = const Color(0xffb66c50)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
    for (final node in layout.nodes) {
      final r = layout.rects[node.id]!;
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(12)),
        Paint()
          ..color = node.parent == null
              ? const Color(0xfff0d9cc)
              : const Color(0xfff5f3ef),
      );
      text(
        node.text,
        r.topLeft + const Offset(16, 14),
        210,
        MinuteMapLayout.textStyle,
      );
    }
  }

  @override
  bool shouldRepaint(MinuteMapPainter oldDelegate) =>
      oldDelegate.layout != layout;
}

class MinutesMindMap extends StatefulWidget {
  const MinutesMindMap({
    super.key,
    required this.controller,
    required this.reference,
  });
  final RecorderController controller;
  final RecordingReference reference;
  @override
  State<MinutesMindMap> createState() => _MinutesMindMapState();
}

class _MinutesMindMapState extends State<MinutesMindMap> {
  final transform = TransformationController();
  final collapsed = <String>{};
  bool textView = false, exporting = false;
  Size viewport = Size.zero;
  String? version;
  MinuteMapLayout? cached;
  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  void fit(MinuteMapLayout layout) {
    final scale = math.min(
      1.0,
      math.min(
        viewport.width / layout.size.width,
        viewport.height / layout.size.height,
      ),
    );
    transform.value = Matrix4.identity()..scaleByDouble(scale, scale, 1, 1);
  }

  void zoom(double factor) {
    final scale = transform.value.getMaxScaleOnAxis();
    final target = (scale * factor).clamp(.01, 4.0);
    transform.value = transform.value.clone()
      ..scaleByDouble(target / scale, target / scale, 1, 1);
  }

  void inspect(MinuteMapNode node, AnalysisResult result) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('节点与原文'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(node.text),
            if (node.item?.owner != null)
              Text('负责人：${node.item!.owner} · 期限：${node.item!.due}'),
            for (final id in node.item?.sources ?? <String>[]) ...[
              const SizedBox(height: 12),
              Text('原文 [$id]'),
              SelectableText(result.sources[int.parse(id.substring(1)) - 1]),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
      ],
    ),
  );
  Future<void> export(
    MeetingMinutes minutes,
    AnalysisResult result,
    String title,
    String metadata,
  ) async {
    setState(() => exporting = true);
    try {
      final full = minuteMapNodes(minutes);
      if (full.length > 300) throw StateError('超过 300 个节点，请导出文字纪要保留全部内容');
      final bytes = await MinuteMapLayout(full, title, metadata).png();
      if (!mounted) return;
      if (Platform.isIOS) {
        final dir = await getTemporaryDirectory();
        final file = File(
          '${dir.path}/minutes-map-${DateTime.now().microsecondsSinceEpoch}.png',
        );
        await file.writeAsBytes(bytes);
        if (!mounted) {
          await file.delete();
          return;
        }
        final box = context.findRenderObject() as RenderBox?;
        try {
          await SharePlus.instance.share(
            ShareParams(
              files: [XFile(file.path)],
              title: '思维导图',
              sharePositionOrigin: box == null
                  ? null
                  : box.localToGlobal(Offset.zero) & box.size,
            ),
          );
        } finally {
          if (await file.exists()) await file.delete();
        }
      } else {
        final location = await getSaveLocation(suggestedName: '录音思维导图.png');
        if (location != null) await File(location.path).writeAsBytes(bytes);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e is StateError ? e.message.toString() : '导出失败，请重试'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller.analysis,
      widget.controller,
    ]),
    builder: (context, _) {
      final view = widget.controller.recordingView(widget.reference);
      final result = widget
          .controller
          .analysis
          .results['${widget.controller.analysisKey(widget.reference)}/minutes'];
      MeetingMinutes? minutes;
      if (result != null) {
        try {
          minutes = MeetingMinutes.parse(result.text, result.sources.length);
        } catch (_) {}
      }
      if (result == null || minutes == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('思维导图')),
          body: const Center(child: Text('请先生成有效的结构化纪要')),
        );
      }
      final all = minuteMapNodes(minutes);
      final tooLarge = all.length > 300;
      final currentVersion =
          '${result.sourceHash}/${result.createdAt}/${result.editedAt}/${result.text}';
      if (currentVersion != version) {
        version = currentVersion;
        collapsed.clear();
        cached = null;
      }
      final visible = all.where((n) => !collapsed.contains(n.parent)).toList();
      final layout = tooLarge
          ? null
          : (cached ??= MinuteMapLayout(
              visible,
              view.title,
              '${result.model} · 纪要版本 ${result.editedAt ?? result.createdAt}',
            ));
      return Scaffold(
        appBar: AppBar(
          title: const Text('思维导图'),
          actions: [
            KoeIconButton(
              tooltip: textView ? '图形视图' : '层级文本',
              icon: Icon(textView ? Icons.account_tree_outlined : Icons.list),
              onPressed: () => setState(() => textView = !textView),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (widget.controller.recordingAudioChanged(widget.reference) ||
                  result.sourceHash != analysisFingerprint(view.text))
                const Text('原文已更新，当前导图对应旧纪要'),
              if (tooLarge) const Text('超过 300 个节点，显示完整层级文本；请使用文字纪要导出'),
              Wrap(
                spacing: 8,
                children: [
                  if (!tooLarge)
                    KoeIconButton(
                      tooltip: '放大',
                      onPressed: () => zoom(1.4),
                      icon: const Icon(Icons.zoom_in),
                    ),
                  if (!tooLarge)
                    KoeIconButton(
                      tooltip: '缩小',
                      onPressed: () => zoom(1 / 1.4),
                      icon: const Icon(Icons.zoom_out),
                    ),
                  if (!tooLarge)
                    TextButton(
                      onPressed: () => fit(layout!),
                      child: const Text('适应画布'),
                    ),
                  if (!tooLarge)
                    TextButton(
                      onPressed: () => setState(() {
                        collapsed.clear();
                        cached = null;
                      }),
                      child: const Text('展开全部'),
                    ),
                  TextButton(
                    onPressed: exporting || tooLarge
                        ? null
                        : () => export(
                            minutes!,
                            result,
                            view.title,
                            '${result.model} · 纪要版本 ${result.editedAt ?? result.createdAt}',
                          ),
                    child: Text(exporting ? '正在导出…' : '导出完整图片'),
                  ),
                ],
              ),
              if (!textView && !tooLarge)
                const Text('点击分类折叠或展开，点击内容查看原文；可拖动和缩放。'),
              Expanded(
                child: textView || tooLarge
                    ? ListView(
                        children: [
                          for (final node in all)
                            ListTile(
                              title: Text(node.text),
                              contentPadding: EdgeInsets.only(
                                left: node.parent == null
                                    ? 16
                                    : node.item == null
                                    ? 28
                                    : 44,
                                right: 16,
                              ),
                              subtitle: node.item == null
                                  ? null
                                  : Text(
                                      node.item!.sources
                                          .map((s) => '[$s]')
                                          .join(' '),
                                    ),
                              onTap: () => inspect(node, result),
                            ),
                        ],
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final next = constraints.biggest;
                          if (next != viewport) {
                            viewport = next;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) fit(layout!);
                            });
                          }
                          return InteractiveViewer(
                            transformationController: transform,
                            constrained: false,
                            minScale: .01,
                            maxScale: 4,
                            boundaryMargin: const EdgeInsets.all(400),
                            child: SizedBox(
                              width: layout!.size.width,
                              height: layout.size.height,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: CustomPaint(
                                      painter: MinuteMapPainter(layout),
                                    ),
                                  ),
                                  for (final node in visible)
                                    Positioned.fromRect(
                                      rect: layout.rects[node.id]!,
                                      child: Semantics(
                                        key: ValueKey('map-node-${node.id}'),
                                        button: true,
                                        label: node.text,
                                        child: Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            onTap: () {
                                              if (node.id.startsWith(
                                                'section:',
                                              )) {
                                                setState(() {
                                                  collapsed.contains(node.id)
                                                      ? collapsed.remove(
                                                          node.id,
                                                        )
                                                      : collapsed.add(node.id);
                                                  cached = null;
                                                });
                                              } else {
                                                inspect(node, result);
                                              }
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
