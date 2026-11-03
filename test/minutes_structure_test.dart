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
}
