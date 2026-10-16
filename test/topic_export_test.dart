import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/topic_export.dart';
import 'package:koe/state/topic_note.dart';
import 'package:koe/state/topic_store.dart';
import 'package:koe/state/topic_summary.dart';

void main() {
  Topic topic(String id, String title, {TopicKind kind = TopicKind.general,
      String author = '', bool closed = false}) => Topic(
    id: id,
    kind: kind,
    title: title,
    author: author,
    closed: closed,
    createdAt: DateTime(2026, 10, 16),
  );

  test('书籍导出包含元信息、过期汇总与按顺序的完整笔记，不泄露内部来源', () {
    final book = topic('private-topic-id', '虚构书',
        kind: TopicKind.book, author: '作者甲', closed: true);
    final summary = TopicSummary(
      kind: TopicKind.book,
      topicId: book.id,
      sources: [TopicSummarySource(
        id: 'N1', recordingKey: 'file:secret-recording-id', title: '录音',
        recordedAt: DateTime(2026, 10, 1),
      )],
      sections: {
        for (final key in TopicSummary.sectionKeys(TopicKind.book))
          key: key == 'coreIdeas'
              ? [const TopicSummaryItem(text: '先理解再判断', sources: ['N1'])]
              : <TopicSummaryItem>[],
      },
    );
    TopicExportNote note(String title, int day, int page) => TopicExportNote(
      title: title,
      recordedAt: DateTime(2026, 10, day, 9, 30),
      page: page,
      note: TopicNote(
        kind: TopicKind.book,
        topicId: book.id,
        overview: '本次概要 $title',
        excerpts: [TopicExcerpt(text: '虚构摘录', page: '第$page页',
            sources: const ['S1'])],
        comments: const [TopicComment(text: '我的评论', sources: ['S1'])],
      ),
    );
    final markdown = buildTopicMarkdown(
      topic: book,
      recordingCount: 3,
      exportedAt: DateTime(2026, 10, 16, 20, 15),
      notes: [note('第二页', 2, 2), note('第一页', 1, 1)],
      summary: summary,
      summaryStale: true,
    );
    expect(markdown, startsWith('# 虚构书\n'));
    expect(markdown, contains('- 作者：作者甲'));
    expect(markdown, contains('- 状态：读完'));
    expect(markdown, contains('- 录音数：3'));
    expect(markdown, contains('- 导出时间：2026-10-16 20:15'));
    expect(markdown.indexOf('## 汇总'), lessThan(markdown.indexOf('## 笔记')));
    expect(markdown, contains('此汇总已过期'));
    expect(markdown, contains('先理解再判断'));
    expect(markdown.indexOf('### 1. 第一页'),
        lessThan(markdown.indexOf('### 2. 第二页')));
    expect(markdown, contains('- 录音日期：2026-10-01 09:30'));
    expect(markdown, contains('- 口述页码：1'));
    expect(markdown, contains('虚构摘录'));
    expect(markdown, contains('我的评论'));
    expect(markdown, isNot(contains('private-topic-id')));
    expect(markdown, isNot(contains('secret-recording-id')));
    expect(markdown, isNot(contains('[S1]')));
    expect(markdown, isNot(contains('[N1]')));
  });

  test('空主题也能导出，普通笔记保留想法、变化、待办与结论', () {
    final general = topic('planning', '职业规划');
    final empty = buildTopicMarkdown(
      topic: general, recordingCount: 0,
      exportedAt: DateTime(2026, 10, 16), notes: [],
    );
    expect(empty, contains('尚无汇总。'));
    expect(empty, contains('尚无笔记。'));
    final note = TopicNote(
      kind: TopicKind.general,
      topicId: general.id,
      overview: '重新考虑下一步',
      ideas: const [TopicIdea(text: '先试新方向', reason: '能验证兴趣',
          sources: ['S1'])],
      changes: const [TopicNoteItem('比上次更明确', ['S1'])],
      todos: const [TopicNoteItem('查课程', ['S1'])],
      conclusion: const TopicNoteItem('先试一周', ['S1']),
    );
    final markdown = buildTopicMarkdown(
      topic: general, recordingCount: 1,
      exportedAt: DateTime(2026, 10, 16),
      notes: [TopicExportNote(title: '录音一',
          recordedAt: DateTime(2026, 10, 15), note: note)],
    );
    expect(markdown, contains('先试新方向（理由：能验证兴趣）'));
    expect(markdown, contains('比上次更明确'));
    expect(markdown, contains('查课程'));
    expect(markdown, contains('先试一周'));
  });

  test('文件名清理非法字符并区分清理后同名的主题', () {
    final first = topic('first', 'A/B', kind: TopicKind.book, author: 'C:D');
    final second = topic('second', 'A:B', kind: TopicKind.book, author: 'C/D');
    final third = topic('third', 'A-B - C-D (2)');
    final all = [first, third, second];
    expect(topicExportFileName(first, all), 'A-B - C-D.md');
    expect(topicExportFileName(third, all), 'A-B - C-D (2).md');
    expect(topicExportFileName(second, all), 'A-B - C-D (3).md');
  });
}
