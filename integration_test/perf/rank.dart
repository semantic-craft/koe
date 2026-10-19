import 'package:koe/state/context/ask_retrieval.dart';

/// The retrieval call the app makes when answering a question
/// (lib/state/recorder/ask.dart).
Future<List<int>> rankForPerf(String question, List<String> texts) =>
    rankTextsOffUi(question, texts, limit: 30);
