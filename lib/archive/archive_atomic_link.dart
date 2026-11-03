import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'archive_wire.dart';

typedef _LinkNative = Int32 Function(Pointer<Utf8> from, Pointer<Utf8> to);
typedef _LinkDart = int Function(Pointer<Utf8> from, Pointer<Utf8> to);

/// Atomically publishes [source] as [target] without replacing an existing
/// target. `link(2)` fails with EEXIST instead of overwriting, unlike
/// `File.rename`. The caller still owns [source] and deletes it after success.
bool get archiveAtomicLinkSupported =>
    Platform.isMacOS ||
    Platform.isIOS ||
    Platform.isLinux ||
    Platform.isAndroid;

void archiveAtomicLinkNoReplace(String source, String target) {
  if (!archiveAtomicLinkSupported) {
    throw const ArchiveException('当前平台不支持原子恢复发布，未覆盖目标文件');
  }
  final DynamicLibrary library;
  try {
    library = Platform.isLinux
        ? DynamicLibrary.open('libc.so.6')
        : Platform.isAndroid
        ? DynamicLibrary.open('libc.so')
        : DynamicLibrary.process();
  } catch (_) {
    throw const ArchiveException('无法加载系统 link(2)，未覆盖目标文件');
  }
  final _LinkDart link;
  try {
    link = library.lookupFunction<_LinkNative, _LinkDart>('link');
  } catch (_) {
    throw const ArchiveException('系统不支持 link(2)，未覆盖目标文件');
  }
  final from = source.toNativeUtf8();
  final to = target.toNativeUtf8();
  try {
    if (link(from, to) != 0) {
      throw const ArchiveException('目标已存在或原子链接失败，未覆盖目标文件');
    }
  } finally {
    malloc.free(from);
    malloc.free(to);
  }
}
