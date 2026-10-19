import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/context/ask_retrieval.dart';
import 'package:koe/util/off_ui.dart';

void main() {
  test('资料多时检索在后台完成，命中和顺序与原检索一致', () async {
    offUiFallbacks = 0;
    final texts = [
      for (var i = 0; i < 4000; i++)
        switch (i % 4) {
          0 => '第$i段：下周和供应商确认报价单，预算控制在十万以内',
          1 => '第$i段：周末去看房，顺便约中介聊聊贷款',
          2 => '第$i段：报价单里的运费要单独列出来',
          _ => '第$i段：今天的会议主要讨论了招聘计划',
        },
    ];
    var size = 0;
    for (final text in texts) {
      size += text.length;
    }
    expect(size, greaterThan(rankBackgroundThreshold));

    const question = '供应商的报价单预算是多少？';
    final background = await rankTextsOffUi(question, texts);

    expect(background, rankTexts(question, texts));
    expect(background, isNotEmpty);
    expect(offUiFallbacks, 0);
  });
}
