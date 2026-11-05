import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<HttpServer?> _startSpeechServer(Directory directory) async {
  final rawPort = Platform.environment['KOE_MINUTES_DRIVER_PORT']?.trim();
  final port = rawPort == null ? null : int.tryParse(rawPort);
  if (port == null || port <= 0) return null;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  var index = 0;
  unawaited(() async {
    await for (final request in server) {
      try {
        final body = await utf8.decoder.bind(request).join();
        final payload = body.isEmpty
            ? const <String, dynamic>{}
            : Map<String, dynamic>.from(jsonDecode(body) as Map);
        final text = (payload['text'] as String? ?? '').trim();
        if (request.uri.path == '/speak' && text.isNotEmpty) {
          final wav = File('${directory.path}/spoken-${++index}.wav');
          final say = await Process.run('/usr/bin/say', [
            '-v',
            'Tingting',
            '-r',
            '180',
            '--data-format=LEI16@16000',
            '-o',
            wav.path,
            text,
          ]);
          if (say.exitCode != 0) {
            await Process.run('/usr/bin/say', [
              '-r',
              '180',
              '--data-format=LEI16@16000',
              '-o',
              wav.path,
              text,
            ]);
          }
          final bytes = await wav.readAsBytes();
          final shasum = await Process.run('/usr/bin/shasum', [
            '-a',
            '256',
            wav.path,
          ]);
          final digest = '${shasum.stdout}'.trim().split(RegExp(r'\s+')).first;
          await Process.run('/usr/bin/afplay', ['-v', '2.0', wav.path]);
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'ok': true,
                'sha256': digest,
                'bytes': bytes.length,
              }),
            );
        } else if (request.uri.path == '/prompt' && text.isNotEmpty) {
          await Process.run('/usr/bin/say', ['-v', 'Tingting', '-r', '195', text]);
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'ok': true}));
        } else if (request.uri.path == '/foreground') {
          final targetPid = payload['pid'];
          if (targetPid is int && targetPid > 0) {
            await Process.run('/usr/bin/osascript', [
              '-l',
              'JavaScript',
              '-e',
              "ObjC.import('AppKit'); "
                  'const app = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($targetPid); '
                  'if (!app.isNil()) { app.unhide; app.activateWithOptions(\$.NSApplicationActivateAllWindows); }',
            ]);
          }
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'ok': true}));
        } else if (request.uri.path == '/screenshot') {
          final name = (payload['name'] as String? ?? '').trim();
          final pngBase64 = (payload['pngBase64'] as String? ?? '').trim();
          if (RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name) &&
              pngBase64.isNotEmpty) {
            final screenshots = Directory('${directory.path}/screenshots');
            await screenshots.create(recursive: true);
            await File(
              '${screenshots.path}/$name.png',
            ).writeAsBytes(base64Decode(pngBase64), flush: true);
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'ok': true}));
          } else {
            request.response.statusCode = HttpStatus.badRequest;
          }
        } else if (request.uri.path == '/config') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'ok': true,
                'apiKey': Platform.environment['DASHSCOPE_API_KEY'] ?? '',
                'baseUrl': Platform.environment['DASHSCOPE_HTTP_BASE_URL'] ?? '',
              }),
            );
        } else {
          request.response.statusCode = HttpStatus.badRequest;
        }
      } catch (error) {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('$error');
      } finally {
        await request.response.close();
      }
    }
  }());
  return server;
}

Future<void> main() async {
  final output = Platform.environment['KOE_MINUTES_PROOF_DIR'];
  if (output == null || output.isEmpty) {
    throw StateError('Run scripts/verify-minutes-flow ios to isolate evidence');
  }
  final directory = Directory(output);
  final server = await _startSpeechServer(directory);
  try {
    await integrationDriver(
      onScreenshot: (name, bytes, [arguments]) async {
        if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name) || bytes.isEmpty) {
          return false;
        }
        final screenshots = Directory('${directory.path}/screenshots');
        await screenshots.create(recursive: true);
        await File(
          '${screenshots.path}/$name.png',
        ).writeAsBytes(bytes, flush: true);
        return true;
      },
      responseDataCallback: (data) async {
        final proofName =
            data != null && data.containsKey('device_minutes_flow')
            ? 'device-proof.json'
            : 'ios-proof.json';
        await File(
          '${directory.path}/$proofName',
        ).writeAsString(jsonEncode(data), flush: true);
      },
    );
  } finally {
    await server?.close(force: true);
  }
}
