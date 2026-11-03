import 'dart:async';
import 'package:flutter/material.dart';
import '../../state/mac_interpreting.dart';

class MacInterpretingPanel extends StatefulWidget {
  const MacInterpretingPanel({
    super.key,
    required this.model,
    required this.onEnable,
    required this.canInstall,
  });
  final MacInterpretingState model;
  final Future<void> Function(String input, String output, bool automatic)
  onEnable;
  final bool Function() canInstall;
  @override
  State<MacInterpretingPanel> createState() => _MacInterpretingPanelState();
}

class _MacInterpretingPanelState extends State<MacInterpretingPanel> {
  List<Map<String, dynamic>> _inputs = [], _outputs = [];
  String? _input, _output;
  final _holdKey = GlobalKey();
  bool _automatic = false, _installing = false;
  String _notice = '';
  MacInterpretingState get m => widget.model;
  @override
  void initState() {
    super.initState();
    _automatic = m.autoInput;
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final result = Map<String, dynamic>.from(
        await m.bridge.call('devices') as Map,
      );
      if (!mounted) return;
      setState(() {
        _input ??= m.inputUID;
        _output ??= m.outputUID;
        _inputs = (result['inputs'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _outputs = (result['outputs'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (!_inputs.any((e) => e['uid'] == _input)) _input = null;
        if (_input == null &&
            _inputs.any((e) => e['uid'] == result['defaultInput'])) {
          _input = result['defaultInput'] as String;
        }
        if (!_outputs.any((e) => e['uid'] == _output)) {
          _output = _outputs.firstOrNull?['uid'] as String?;
        }
        _notice = result['error'] as String? ?? '';
        if (_outputs.isEmpty && _notice.isEmpty) {
          _notice = '尚未检测到 BlackHole 2ch。请完成系统安装；若已完成，请保存工作并按安装器提示重启 Mac 后刷新。';
        }
      });
    } catch (_) {
      if (mounted) setState(() => _notice = '无法读取音频设备，请确认 Mac 版本后重试');
    }
  }

  Future<void> _install() async {
    if (!widget.canInstall()) {
      setState(() => _notice = '请先结束本机录音或文字采集');
      return;
    }
    setState(() {
      _installing = true;
      _notice = '正在下载并校验官方安装包';
    });
    try {
      await m.bridge.call('install');
      if (mounted) setState(() => _notice = '已交给系统安装器，请完成安装后刷新；打开安装器不代表安装成功。');
    } catch (_) {
      if (mounted) setState(() => _notice = '下载、校验或打开安装器未完成，可重试；普通录音不受影响。');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Widget _device(
    String label,
    List<Map<String, dynamic>> items,
    String? value,
    void Function(String?) select,
  ) => DropdownButtonFormField<String>(
    initialValue: value,
    key: ValueKey('$label:$value'),
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final item in items)
        DropdownMenuItem(
          value: item['uid'] as String,
          child: Text(item['name'] as String, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: m.enabled || m.busy || _installing ? null : select,
  );
  Widget _language(String label, String value, void Function(String) select) =>
      DropdownButtonFormField<String>(
        initialValue:
            const ['zh-CN', 'en', 'ja', 'ko', 'fr', 'de', 'es'].contains(value)
            ? value
            : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: const [
          DropdownMenuItem(value: 'zh-CN', child: Text('中文')),
          DropdownMenuItem(value: 'en', child: Text('英语')),
          DropdownMenuItem(value: 'ja', child: Text('日语')),
          DropdownMenuItem(value: 'ko', child: Text('韩语')),
          DropdownMenuItem(value: 'fr', child: Text('法语')),
          DropdownMenuItem(value: 'de', child: Text('德语')),
          DropdownMenuItem(value: 'es', child: Text('西班牙语')),
        ],
        onChanged: m.enabled || m.busy
            ? null
            : (v) {
                if (v != null) setState(() => select(v));
              },
      );
  @override
  void dispose() {
    if (m.busy) unawaited(m.cancel(notify: false));
    if (_installing) unawaited(m.bridge.call('cancelInstall'));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Mac 同声传译',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const Text(
              '在会议软件中选择 BlackHole 2ch 作为麦克风。按住说一句，松开后翻译；忙时不接下一句。快捷键 ⌃⌥⌘T。',
            ),
            _device(
              '真实麦克风',
              _inputs,
              _input,
              (v) => setState(() {
                _input = v;
                m.inputUID = v;
              }),
            ),
            _device(
              '译音输出',
              _outputs,
              _output,
              (v) => setState(() {
                _output = v;
                m.outputUID = v;
              }),
            ),
            _language('我说的语种', m.sourceLanguage, (v) => m.sourceLanguage = v),
            _language('译成', m.targetLanguage, (v) => m.targetLanguage = v),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('临时切换系统默认输入'),
              subtitle: const Text('默认关闭。开启后会临时修改系统麦克风，停止时尝试恢复；手动选择会议输入更简单。'),
              value: _automatic,
              onChanged: m.enabled || m.busy
                  ? null
                  : (v) => setState(() => _automatic = v),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: m.enabled
                      ? () => unawaited(m.disable().catchError((Object _) {}))
                      : m.busy ||
                            _installing ||
                            _input == null ||
                            _output == null
                      ? null
                      : () => widget.onEnable(_input!, _output!, _automatic),
                  child: Text(m.enabled ? '关闭同传' : '本场启用'),
                ),
                TextButton(
                  onPressed: m.busy ? null : _refresh,
                  child: const Text('刷新设备'),
                ),
                if (!m.enabled)
                  TextButton(
                    onPressed: _installing ? null : _install,
                    child: const Text('安装 BlackHole 2ch'),
                  ),
                if (_installing)
                  TextButton(
                    onPressed: () => m.bridge.call('cancelInstall'),
                    child: const Text('取消下载'),
                  ),
              ],
            ),
            if (_notice.isNotEmpty) Text(_notice),
            if (m.enabled)
              Listener(
                key: _holdKey,
                onPointerDown: (_) => unawaited(m.press()),
                onPointerUp: (_) => unawaited(m.release()),
                onPointerCancel: (_) => unawaited(m.cancel()),
                onPointerMove: (e) {
                  final box = _holdKey.currentContext?.findRenderObject();
                  if (box is RenderBox &&
                      !(Offset.zero & box.size).contains(
                        box.globalToLocal(e.position),
                      )) {
                    unawaited(m.cancel());
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(20),
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  child: const Text('按住说话 · 松开发送', textAlign: TextAlign.center),
                ),
              ),
            Text(switch (m.phase) {
              InterpretingPhase.off => '已关闭',
              InterpretingPhase.ready => '就绪',
              InterpretingPhase.preparing => '准备麦克风 / 等待权限',
              InterpretingPhase.capturing => '正在采集，最长30秒',
              InterpretingPhase.recognizing => '识别收尾',
              InterpretingPhase.translating => '翻译中',
              InterpretingPhase.synthesizing => '合成中',
              InterpretingPhase.speaking => '正在输出译音',
              InterpretingPhase.error => '未完成，请检查后重试',
            }),
            if (m.busy)
              TextButton(onPressed: m.cancel, child: const Text('取消本句')),
            if (m.message.isNotEmpty) Text(m.message),
            if (m.source.isNotEmpty) SelectableText('原文：${m.source}'),
            if (m.translation.isNotEmpty) SelectableText('译文：${m.translation}'),
          ],
        ),
      ),
    ),
  );
}
