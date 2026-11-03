import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/meeting_minutes.dart';

const structureSources = ['江松说明：延期是因为接口没有联调。', '团队决定周五由江松完成联调。'];
Map<String, dynamic> structureFixture() => {
  'schemaVersion': 2,
  'title': '联调会议',
  'overview': '讨论延期原因和联调安排',
  'topics': [
    {
      'text': '延期原因',
      'sources': ['S1'],
      'summary': '接口未联调造成延期',
      'points': [
        {
          'text': '需要先完成接口联调',
          'sources': ['S1'],
        },
      ],
      'fishbone': {
        'question': '为什么延期',
        'branches': [
          {
            'text': '接口',
            'detail': '接口没有联调',
            'sources': ['S1'],
          },
        ],
      },
    },
  ],
  'decisions': [],
  'actions': [
    {
      'text': '完成联调',
      'owner': '江充',
      'due': '周五',
      'sources': ['S2'],
    },
  ],
  'questions': [],
  'terms': [
    {
      'name': '江充',
      'note': '参会人，名字待确认',
      'heard': ['江松'],
      'sources': ['S1', 'S2'],
    },
  ],
};

void main() {
  test(
    'validated nested minutes preserve content and evidence through JSON round trip',
    () {
      final raw = structureFixture();
      final encoded = validateMinutes(jsonEncode(raw), structureSources);
      expect(jsonDecode(encoded), raw);
    },
  );
  test(
    'unknown schema and v1 extensions are rejected instead of discarded',
    () {
      for (final version in [0, 3, 2.5, '2', true, null]) {
        final raw = structureFixture()..['schemaVersion'] = version;
        expect(
          () => validateMinutes(jsonEncode(raw), structureSources),
          throwsFormatException,
        );
      }
      final legacy = structureFixture()..remove('schemaVersion');
      expect(
        () => validateMinutes(jsonEncode(legacy), structureSources),
        throwsFormatException,
      );
    },
  );
  test('invented nested references and misheard spellings are rejected', () {
    final invalidPoint = structureFixture();
    ((invalidPoint['topics'] as List).single['points'] as List)
        .single['sources'] = [
      'S3',
    ];
    expect(
      () => validateMinutes(jsonEncode(invalidPoint), structureSources),
      throwsFormatException,
    );
    final inventedTerm = structureFixture();
    (inventedTerm['terms'] as List).single['heard'] = ['不存在的名字'];
    expect(
      () => validateMinutes(jsonEncode(inventedTerm), structureSources),
      throwsFormatException,
    );
  });
  test(
    'oversized nested collections are rejected without silent truncation',
    () {
      final raw = structureFixture();
      (raw['topics'] as List).single['points'] = List.generate(
        101,
        (_) => {
          'text': '点',
          'sources': ['S1'],
        },
      );
      expect(
        () => validateMinutes(jsonEncode(raw), structureSources),
        throwsFormatException,
      );
    },
  );
  test('numeric calculations may not combine facts from separate sources', () {
    final sources = [
      '社保计划按最低比例，买个60%左右。',
      '基本工资目前是平均工资在3000块左右。',
      '缴费基数按基本工资3000元的60%计算。',
    ];
    final synthesized = structureFixture()..remove('terms');
    final topic = (synthesized['topics'] as List).single;
    topic['summary'] = '确认按最低比例缴纳，基数约为基本工资的60%。';
    topic['sources'] = ['S1', 'S2'];
    expect(
      () => validateMinutes(jsonEncode(synthesized), sources),
      throwsFormatException,
    );

    final separateFacts = Map<String, dynamic>.of(synthesized);
    (separateFacts['topics'] as List).single['summary'] =
        '社保计划约60%；基本工资约3000元。';
    expect(validateMinutes(jsonEncode(separateFacts), sources), isA<String>());

    final groundedCalculation = Map<String, dynamic>.of(synthesized);
    (groundedCalculation['topics'] as List).single['summary'] =
        '缴费基数按基本工资3000元的60%计算。';
    (groundedCalculation['topics'] as List).single['sources'] = ['S3'];
    expect(
      validateMinutes(jsonEncode(groundedCalculation), sources),
      isA<String>(),
    );

    final implicitRelation = Map<String, dynamic>.of(synthesized);
    (implicitRelation['topics'] as List).single['summary'] =
        '确认按最低比例缴纳，按基本工资的60%缴纳。';
    (implicitRelation['topics'] as List).single['sources'] = ['S1', 'S2'];
    expect(
      () => validateMinutes(jsonEncode(implicitRelation), sources),
      throwsFormatException,
    );

    final groundedImplicitRelation = Map<String, dynamic>.of(synthesized);
    (groundedImplicitRelation['topics'] as List).single['summary'] =
        '确认按最低比例缴纳，按基本工资的60%缴纳。';
    (groundedImplicitRelation['topics'] as List).single['sources'] = ['S3'];
    expect(
      validateMinutes(jsonEncode(groundedImplicitRelation), sources),
      isA<String>(),
    );
  });
}
