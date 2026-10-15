import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// OSS requires Content-Disposition before Content-Type in the file part.
/// Keep the payload streamed and byte-for-byte intact; only encode headers here.
class OssUploadRequest extends http.BaseRequest with http.Abortable {
  OssUploadRequest(
    Uri url, {
    required Map<String, String> fields,
    required this.file,
    this.abortTrigger,
  }) : fields = Map.unmodifiable(fields),
       super('POST', url) {
    final random = Random.secure();
    final boundary =
        'koe-${List.generate(24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final prefix = StringBuffer();
    for (final entry in fields.entries) {
      prefix.write(
        '--$boundary\r\ncontent-disposition: form-data; '
        'name="${_quote(entry.key)}"\r\n\r\n${entry.value}\r\n',
      );
    }
    prefix.write(
      '--$boundary\r\ncontent-disposition: form-data; '
      'name="${_quote(file.field)}"; filename="${_quote(file.filename ?? 'audio')}"\r\n'
      'content-type: ${file.contentType}\r\n\r\n',
    );
    _prefix = utf8.encode(prefix.toString());
    _suffix = utf8.encode('\r\n--$boundary--\r\n');
    headers['content-type'] = 'multipart/form-data; boundary=$boundary';
    contentLength = _prefix.length + file.length + _suffix.length;
  }

  final Map<String, String> fields;
  final http.MultipartFile file;
  @override
  final Future<void>? abortTrigger;
  late final List<int> _prefix;
  late final List<int> _suffix;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body());
  }

  Stream<List<int>> _body() async* {
    yield _prefix;
    yield* file.finalize();
    yield _suffix;
  }

  static String _quote(String value) => value
      .replaceAll('\r', '%0D')
      .replaceAll('\n', '%0A')
      .replaceAll('"', '%22');
}
