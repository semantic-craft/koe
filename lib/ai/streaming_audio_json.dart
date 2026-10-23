import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Base64 characters are JSON-safe. Stream only that string value while the
/// encoder retains at most two carry bytes. No whole-file or JSON copy.
class StreamingAudioJsonRequest extends http.BaseRequest with http.Abortable {
  StreamingAudioJsonRequest(
    Uri url, {
    required this.file,
    required Map<String, dynamic> body,
    required Future<void> abort,
    required this.isCurrent,
    required this.onProgress,
    required this.onUploaded,
    this.onSending,
  }) : abortTrigger = abort,
       super('POST', url) {
    final json = jsonEncode(body);
    const marker = '"data":""';
    final index = json.indexOf(marker);
    if (index < 0) throw ArgumentError('Missing empty audio data field');
    prefix = utf8.encode(json.substring(0, index + marker.length - 1));
    suffix = utf8.encode(json.substring(index + marker.length - 1));
    contentLength =
        prefix.length + ((file.lengthSync() + 2) ~/ 3) * 4 + suffix.length;
  }
  final File file;
  @override
  final Future<void> abortTrigger;
  final bool Function() isCurrent;
  final void Function(int, int) onProgress;
  final void Function() onUploaded;

  /// Awaited before the closing bytes: until they go out the service holds
  /// no complete request it could act on, or charge for.
  final Future<void> Function()? onSending;
  late final List<int> prefix, suffix;
  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_stream());
  }

  Stream<List<int>> _stream() async* {
    void check() {
      if (!isCurrent()) throw http.RequestAbortedException();
    }

    check();
    yield prefix;
    final length = file.lengthSync();
    var sent = 0;
    onProgress(0, length);
    Stream<List<int>> audio() async* {
      await for (final chunk in file.openRead()) {
        check();
        yield chunk;
        sent += chunk.length;
        onProgress(sent, length);
      }
    }

    yield* audio().transform(base64.encoder).transform(utf8.encoder);
    await onSending?.call();
    check();
    yield suffix;
    onUploaded();
  }
}
