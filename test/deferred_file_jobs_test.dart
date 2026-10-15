import 'dart:async';

import 'package:anker_recorder/state/deferred_file_jobs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a persistent engine accepts the job at enqueue time, even gated',
    () async {
      final accepted = <String>[];
      var runs = 0;
      final jobs = DeferredFileJobs<String>(
        canStart: () => false,
        engine: (config) => config,
        accept: (recordingKey, path, config) async {
          accepted.add('$recordingKey:$path:$config');
          return true;
        },
        run:
            (
              path,
              config, {
              prepareLanguages = false,
              fromQueue = false,
            }) async {
              runs++;
              return true;
            },
      );
      await jobs.enqueue('recording-1', '/a.wav', 'moss');
      // The journal write happens at enqueue, before the gate ever opens.
      expect(accepted, ['recording-1:/a.wav:moss']);
      await jobs.pump();
      expect(runs, 0);
      // The adapter owns the job; the mechanism never re-offers it.
      await jobs.enqueue('recording-1', '/a.wav', 'moss');
      expect(accepted, hasLength(1));
    },
  );

  test(
    'memory jobs wait for the gate and run one at a time in FIFO order',
    () async {
      var allowed = false;
      final order = <String>[];
      Completer<void>? gate;
      final jobs = DeferredFileJobs<String>(
        canStart: () => allowed,
        engine: (config) => config,
        accept: (recordingKey, path, config) async => false,
        run:
            (
              path,
              config, {
              prepareLanguages = false,
              fromQueue = false,
            }) async {
              order.add(path);
              if (gate != null) await gate.future;
              return true;
            },
      );
      await jobs.enqueue('recording-1', '/a.wav', 'qwen');
      await jobs.enqueue('recording-2', '/b.wav', 'qwen');
      await jobs.pump();
      expect(order, isEmpty, reason: 'gate 关闭时不启动');
      allowed = true;
      gate = Completer<void>();
      // Callers fire the pump without awaiting it; a running job blocks it.
      unawaited(jobs.pump());
      await Future<void>.delayed(Duration.zero);
      expect(order, ['/a.wav']);
      // The first job is still in flight; a re-pump must not start the second.
      await jobs.pump();
      expect(order, hasLength(1));
      gate.complete();
      for (var i = 0; i < 100 && order.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(order, ['/a.wav', '/b.wav']);
    },
  );

  test('a busy engine keeps the entry queued for the next pump', () async {
    var runs = 0;
    final jobs = DeferredFileJobs<int>(
      canStart: () => true,
      engine: (config) => 'engine',
      accept: (recordingKey, path, config) async => false,
      run: (path, config, {prepareLanguages = false, fromQueue = false}) async {
        runs++;
        return false;
      },
    );
    await jobs.enqueue('recording-1', '/a.wav', 7);
    await jobs.pump();
    expect(runs, 1);
    // Not accepted: the entry stays and is offered again on the next pump.
    await jobs.pump();
    expect(runs, 2);
    expect(jobs.busy, isFalse);
  });

  test('a started recording is skipped once per engine', () async {
    var runs = 0;
    String? lastEngine;
    final jobs = DeferredFileJobs<String>(
      canStart: () => true,
      engine: (config) => config,
      accept: (recordingKey, path, config) async => false,
      run: (path, config, {prepareLanguages = false, fromQueue = false}) async {
        runs++;
        lastEngine = config;
        return true;
      },
    );
    await jobs.enqueue('recording-1', '/a.wav', 'qwen');
    await Future<void>.delayed(Duration.zero);
    expect(runs, 1);
    await jobs.enqueue('recording-1', '/a.wav', 'qwen');
    await Future<void>.delayed(Duration.zero);
    expect(runs, 1, reason: '同引擎同录音只自动跑一次');
    // A different engine may still hold a job for the same recording key.
    await jobs.enqueue('recording-1', '/a.wav', 'doubao');
    await Future<void>.delayed(Duration.zero);
    expect(runs, 2);
    expect(lastEngine, 'doubao');
  });

  test('runNow executes immediately with manual semantics', () async {
    final seen = <(String, bool, bool)>[];
    final jobs = DeferredFileJobs<String>(
      canStart: () => false,
      engine: (config) => config,
      accept: (recordingKey, path, config) async => false,
      run: (path, config, {prepareLanguages = false, fromQueue = false}) async {
        seen.add((path, prepareLanguages, fromQueue));
        return true;
      },
    );
    final result = await jobs.runNow('/a.wav', 'qwen', prepareLanguages: true);
    expect(result, isTrue);
    expect(seen, [('/a.wav', true, false)]);
  });

  test('dispose drops queued entries and stops the pump', () async {
    var allowed = false;
    var runs = 0;
    final jobs = DeferredFileJobs<String>(
      canStart: () => allowed,
      engine: (config) => config,
      accept: (recordingKey, path, config) async => false,
      run: (path, config, {prepareLanguages = false, fromQueue = false}) async {
        runs++;
        return true;
      },
    );
    await jobs.enqueue('recording-1', '/a.wav', 'qwen');
    jobs.dispose();
    allowed = true;
    await jobs.pump();
    expect(runs, 0);
    await jobs.enqueue('recording-2', '/b.wav', 'qwen');
    await Future<void>.delayed(Duration.zero);
    expect(runs, 0);
  });
}
