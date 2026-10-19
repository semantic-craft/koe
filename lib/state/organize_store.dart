import 'dart:io';

import 'package:flutter/foundation.dart';

import 'context/context_file.dart';

/// Which recordings Koe organizes on its own (#133).
///
/// [known] is every recording path seen since auto-organize was switched on;
/// only paths that appear later count as new. [queued] is what still waits to
/// be organized, from new recordings or a history range the user chose.
class OrganizeStore {
  OrganizeStore({File? file, bool inMemory = false})
    : _file = ContextFile(fileName, file: file, inMemory: inMemory);

  static const fileName = 'organize.json';

  final ContextFile _file;
  Future<void>? _loading;

  bool enabled = false;
  final Set<String> known = {};
  final List<String> queued = [];
  String? recoveryNotice;

  Future<void> get idle => _file.idle;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final json = await _file.read();
      if (json == null) return;
      enabled = json['enabled'] == true;
      known.addAll(decodeIds(json['known']));
      for (final path in decodeIds(json['queued'])) {
        if (!queued.contains(path)) queued.add(path);
      }
    } on FormatException {
      recoveryNotice = '自动整理记录无法读取，已另存旧文件；请重新开启';
    } catch (error) {
      recoveryNotice = '自动整理记录无法读取';
      debugPrint('[OrganizeStore] load failed: $error');
    }
  }

  Future<void> save() => _file.write({
    'enabled': enabled,
    'known': known.toList(),
    'queued': queued,
  });
}
