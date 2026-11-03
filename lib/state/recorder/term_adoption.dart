part of '../recorder_controller.dart';

/// Local user decisions live with the version of minutes they apply to.
mixin _RecorderTermAdoption on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  RecordingAnalysis get analysis;
  String analysisKey(RecordingReference ref);
  RecordingViewData recordingView(RecordingReference ref);
  bool recordingAudioChanged(RecordingReference ref);
  Future<void> addVocabularyTermStrict(String term);
  Future<bool> replaceTermsInTranscript(
    String path,
    Map<String, String> replacements, {
    String? expectedHash,
  });
  // END DEPS

  Map<String, int> termReplacementCounts(
    RecordingReference ref,
    MinuteTerm term,
  ) {
    final words =
        term.heard
            .where((word) => word.isNotEmpty && word != term.name)
            .toSet()
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    if (words.isEmpty) return const {};
    final counts = <String, int>{};
    for (final match in RegExp(
      words.map(RegExp.escape).join('|'),
    ).allMatches(recordingView(ref).text)) {
      counts.update(match[0]!, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  Future<void> adoptMinutesTerm(
    RecordingReference ref,
    AnalysisResult expected,
    int termIndex, {
    required bool replace,
  }) async {
    await analysis.load();
    final slot = '${analysisKey(ref)}/minutes';
    if (!identical(analysis.results[slot], expected)) {
      throw StateError('纪要已更新或正在处理，请重新打开后确认');
    }
    final token = analysis.claimMutation(slot);
    if (token == null) throw StateError('纪要正在处理，请稍后重试');
    void checkClaim() {
      if (!analysis.ownsMutation(slot, token) ||
          !identical(analysis.results[slot], expected)) {
        throw StateError('采纳已取消或纪要已变化，请重新确认');
      }
    }

    try {
      checkClaim();
      final before = recordingView(ref);
      if (expected.sourceHash != analysisFingerprint(before.text) ||
          recordingAudioChanged(ref)) {
        throw StateError('原文已变化，请先重新生成纪要');
      }
      final parsed = MeetingMinutes.parse(
        expected.text,
        expected.sources.length,
        sourceTexts: expected.sources,
      );
      if (termIndex < 0 || termIndex >= parsed.terms.length) {
        throw StateError('术语已变化');
      }
      final term = parsed.terms[termIndex];
      final decision = MinuteTermAdoption(
        kind: replace ? 'replaced' : 'vocabulary',
        at: DateTime.now(),
        previousVersion: minuteVersionFingerprint(expected),
      );
      if (!replace) {
        if (term.name.runes.length > 40) {
          throw const FormatException('词表名称须为 1–40 个字');
        }
        final candidate = validateMinutes(
          parsed.adoptTerm(termIndex, decision).encode(),
          expected.sources,
        );
        checkClaim();
        await addVocabularyTermStrict(term.name);
        checkClaim();
        if (analysisFingerprint(recordingView(ref).text) !=
            expected.sourceHash) {
          throw StateError('词表已保存，但原文已变化，纪要尚未标记采纳');
        }
        await analysis.editResult(
          slot,
          expected,
          candidate,
          mutationClaim: token,
          isStillCurrent: () =>
              analysisFingerprint(recordingView(ref).text) ==
                  expected.sourceHash &&
              !recordingAudioChanged(ref),
        );
        return;
      }
      final path = before.path ?? ref.path;
      final counts = termReplacementCounts(ref, term);
      if (path == null || counts.isEmpty) throw StateError('当前原文没有可订正的识别写法');
      final replacements = {for (final word in counts.keys) word: term.name};
      final sources = [
        for (final text in expected.sources)
          replaceMinuteTerms(text, replacements),
      ];
      final candidate = parsed
          .replaceTerms(replacements)
          .pruneHeard(sources)
          .adoptTerm(
            termIndex,
            decision,
            replaced: replacements.keys.toSet(),
            name: term.name,
          );
      final encoded = validateMinutes(candidate.encode(), sources);
      final intendedHash = analysisFingerprint(
        replaceMinuteTerms(before.text, replacements),
      );
      checkClaim();
      await replaceTermsInTranscript(
        path,
        replacements,
        expectedHash: expected.sourceHash,
      );
      checkClaim();
      if (analysisFingerprint(recordingView(ref).text) != intendedHash) {
        throw StateError('原文在保存期间已变化，纪要尚未标记采纳');
      }
      await analysis.replaceResultWithSources(
        slot,
        expected,
        text: encoded,
        sources: sources,
        sourceHash: intendedHash,
        mutationClaim: token,
        isStillCurrent: () =>
            analysisFingerprint(recordingView(ref).text) == intendedHash &&
            !recordingAudioChanged(ref),
      );
    } finally {
      analysis.releaseMutation(slot, token);
      notifyListeners();
    }
  }
}
