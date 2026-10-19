/// Picks the transcript sentences most related to a question, without a
/// model: shared Chinese character pairs and Latin words, weighted so that
/// rare pairs count more than common ones.
library;

import 'dart:math' as math;

import '../../util/off_ui.dart';

const _stopPairs = {
  '什么',
  '怎么',
  '我们',
  '你们',
  '他们',
  '一下',
  '这个',
  '那个',
  '是不',
  '不是',
  '有没',
  '没有',
  '可以',
  '就是',
  '还是',
  '然后',
  '因为',
  '所以',
  '如果',
  '时候',
  '一个',
  '的话',
  '了吗',
  '是什',
  '么时',
  '吗？',
  '问一',
};

Set<String> queryTerms(String text) {
  final terms = <String>{};
  final lower = text.toLowerCase();
  for (final match in RegExp(r'[a-z0-9]{2,}').allMatches(lower)) {
    terms.add(match.group(0)!);
  }
  final han = lower.replaceAll(RegExp(r'[^一-鿿]'), ' ');
  for (final run in han.split(' ')) {
    for (var i = 0; i + 1 < run.length; i++) {
      final pair = run.substring(i, i + 2);
      if (!_stopPairs.contains(pair)) terms.add(pair);
    }
  }
  return terms;
}

/// Indexes into [texts], best match first, at most [limit]; only texts that
/// share at least one term with [query].
List<int> rankTexts(String query, List<String> texts, {int limit = 30}) {
  final terms = queryTerms(query);
  if (terms.isEmpty || texts.isEmpty) return const [];
  final lowered = [for (final text in texts) text.toLowerCase()];
  final weight = <String, double>{};
  for (final term in terms) {
    final df = lowered.where((text) => text.contains(term)).length;
    if (df > 0) weight[term] = math.log(1 + texts.length / df);
  }
  if (weight.isEmpty) return const [];
  final scored = <(int, double)>[];
  for (final (index, text) in lowered.indexed) {
    var score = 0.0;
    for (final entry in weight.entries) {
      if (text.contains(entry.key)) score += entry.value;
    }
    if (score > 0) scored.add((index, score));
  }
  scored.sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (index, _) in scored.take(limit)) index];
}

/// Corpus size, in characters, from which [rankTextsOffUi] ranks on a
/// background isolate.
const rankBackgroundThreshold = 50000;

/// [rankTexts] that runs on a background isolate once [texts] grow with the
/// user's history; same result and order.
Future<List<int>> rankTextsOffUi(
  String query,
  List<String> texts, {
  int limit = 30,
}) {
  var size = 0;
  for (final text in texts) {
    size += text.length;
  }
  return runOffUi(
    () => rankTexts(query, texts, limit: limit),
    size: size,
    threshold: rankBackgroundThreshold,
    debugName: 'rankTexts',
  );
}
