import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/annotations.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/services/scripture_text.dart';

void main() {
  group('original Scripture coordinate mapping', () {
    test(
      'maps multiword tokens through original whitespace and punctuation',
      () {
        final Verse verse = _verse(
          '  Very\t good,\nindeed. ',
          tokens: <Object?>[
            _token('Very good,', 1, 2),
            _token('indeed.', 3, 3),
          ],
        );
        final ScriptureTextMap map = ScriptureTextMap(verse.text);
        final ScriptureTextRange range = map.tokenRange(verse.tokens.first)!;
        expect(verse.text.substring(range.start, range.end), 'Very\t good,');
        expect(map.words, hasLength(3));
        expect(map.tokensAt(8, verse.tokens), <ScriptureToken>[
          verse.tokens.first,
        ]);
        expect(map.tokensAt(0, verse.tokens), isEmpty);
      },
    );

    test('UTF16 offsets retain emoji, combining marks and Unicode spaces', () {
      const String text = '😀\u00a0e\u0301\u2003שלום 中文連續';
      final ScriptureTextMap map = ScriptureTextMap(text);
      expect(map.wordRange(1, 1), const ScriptureTextRange(0, 2));
      expect(map.wordRange(2, 2), const ScriptureTextRange(3, 5));
      expect(map.wordRange(3, 3), const ScriptureTextRange(6, 10));
      expect(text.substring(map.wordRange(4, 4)!.start), '中文連續');
      expect(map.matchesQuote(const ScriptureTextRange(0, 2), '😀'), isTrue);
      expect(map.isValidRange(const ScriptureTextRange(1, 2)), isFalse);
      expect(map.isValidRange(const ScriptureTextRange(3, 5)), isTrue);
    });

    test('token indexes are zero based and inclusive, not word offsets', () {
      final Verse verse = _verse(
        'very good word',
        tokens: <Object?>[_token('very good', 1, 2), _token('word', 3, 3)],
        spans: <Object?>[_span('hi', 'very good word', 1, 3, tokenEnd: 1)],
      );
      final ScriptureTextMap map = ScriptureTextMap(verse.text);
      expect(map.tokensForSpan(verse.spans.first, verse.tokens), verse.tokens);
      expect(map.spanRange(verse.spans.first), const ScriptureTextRange(0, 14));
    });

    test('unlocated or malformed ranges never infer positions', () {
      final Verse verse = _verse(
        'God said God',
        tokens: <Object?>[_token('God', 0, 0)],
        spans: <Object?>[
          _span('divineName', 'God', 0, 0),
          _span('divineName', 'God', 1, 3),
          _span('divineName', 'absent', 1, 1),
        ],
      );
      final ScriptureTextMap map = ScriptureTextMap(verse.text);
      expect(map.tokenRange(verse.tokens.first), isNull);
      expect(verse.spans.map(map.spanRange), everyElement(isNull));
      expect(map.wordRange(2, 1), isNull);
      expect(map.wordRange(1, 4), isNull);
    });

    test('exact bounded spans may omit adjacent punctuation', () {
      final Verse verse = _verse(
        '“God,” said.',
        spans: <Object?>[_span('divineName', 'God', 1, 1)],
      );
      expect(
        ScriptureTextMap(verse.text).spanRange(verse.spans.first),
        const ScriptureTextRange(1, 4),
      );
    });
  });

  group('deterministic rendering layers', () {
    test(
      'source attributes justify styling; arbitrary quotes are ordinary',
      () {
        final Verse verse = _verse(
          'one two three four five',
          spans: <Object?>[
            _span('q', 'one', 1, 1),
            _span('q', 'two', 2, 2, attrs: <String, String>{'who': '#Moses'}),
            _span('q', 'three', 3, 3, attrs: <String, String>{'who': '#Jesus'}),
            _span(
              'transChange',
              'four',
              4,
              4,
              attrs: <String, String>{'type': 'added'},
            ),
            _span(
              'transChange',
              'five',
              5,
              5,
              attrs: <String, String>{'type': 'deleted'},
            ),
          ],
        );
        final List<ScriptureTextSegment> segments =
            const ScriptureTextComposer().compose(verse: verse);
        expect(_segment(segments, 'one').sourceStyle.jesusWords, isFalse);
        expect(_segment(segments, 'two').sourceStyle.jesusWords, isFalse);
        expect(_segment(segments, 'three').sourceStyle.jesusWords, isTrue);
        expect(_segment(segments, 'four').sourceStyle.italic, isTrue);
        expect(_segment(segments, 'five').sourceStyle.italic, isFalse);
        expect(
          segments.map((ScriptureTextSegment item) => item.text).join(),
          verse.text,
        );
      },
    );

    test('overlapping source, marking and temporary layers compose', () {
      final Verse verse = _verse(
        'God is good.',
        spans: <Object?>[
          _span('divineName', 'God', 1, 1),
          _span(
            'transChange',
            'God is',
            1,
            2,
            attrs: <String, String>{'type': 'added'},
          ),
        ],
      );
      final List<ScriptureTextSegment> segments = const ScriptureTextComposer()
          .compose(
            verse: verse,
            passage: _passage,
            groups: <MarkingGroup>[_group('blue'), _group('green')],
            markings: <Marking>[
              _marking('new', 0, 3, 'God', 'green', 20),
              _marking('old', 0, 6, 'God is', 'blue', 10),
            ],
            emphasis: const <ScriptureTextEmphasis>[
              ScriptureTextEmphasis(
                range: ScriptureTextRange(0, 3),
                quote: 'God',
              ),
            ],
          );
      final ScriptureTextSegment god = _segment(segments, 'God');
      expect(god.sourceStyle.divineName, isTrue);
      expect(god.sourceStyle.italic, isTrue);
      expect(god.markingGroup!.id, 'green');
      expect(god.emphasized, isTrue);
      expect(_segment(segments, ' is').markingGroup!.id, 'blue');
      expect(
        segments.map((ScriptureTextSegment item) => item.text).join(),
        verse.text,
      );
    });

    test(
      'quote mismatch, wrong translation and malformed emphasis do not color',
      () {
        final Verse verse = _verse('changed text');
        final List<ScriptureTextSegment> segments =
            const ScriptureTextComposer().compose(
              verse: verse,
              passage: _passage,
              groups: <MarkingGroup>[_group('blue')],
              markings: <Marking>[
                _marking('stale', 0, 7, 'earlier', 'blue', 1),
                _marking(
                  'other',
                  0,
                  7,
                  'changed',
                  'blue',
                  2,
                  translation: 'web',
                ),
              ],
              emphasis: const <ScriptureTextEmphasis>[
                ScriptureTextEmphasis(
                  range: ScriptureTextRange(0, 7),
                  quote: 'earlier',
                ),
              ],
            );
        expect(segments, hasLength(1));
        expect(segments.single.markingGroup, isNull);
        expect(segments.single.emphasized, isFalse);
        expect(segments.single.text, 'changed text');
      },
    );

    test('whole verse marks cross translations; equal ages use stable IDs', () {
      final List<ScriptureTextSegment> segments = const ScriptureTextComposer()
          .compose(
            verse: _verse('unchanged'),
            passage: _passage,
            groups: <MarkingGroup>[_group('blue'), _group('green')],
            markings: <Marking>[
              _marking(
                'z',
                null,
                null,
                'other text',
                'green',
                1,
                translation: 'web',
              ),
              _marking('a', null, null, 'old text', 'blue', 1),
            ],
          );
      expect(segments.single.markingGroup!.id, 'green');
    });

    test('plain and source styles disabled preserve text', () {
      final Verse verse = _verse(
        '  exact\ntext ',
        spans: <Object?>[
          _span('hi', 'exact', 1, 1, attrs: <String, String>{'type': 'bold'}),
        ],
      );
      final List<ScriptureTextSegment> segments = const ScriptureTextComposer()
          .compose(verse: verse, showSourceStyles: false);
      expect(segments.single.text, verse.text);
      expect(segments.single.sourceStyle.bold, isFalse);
    });
  });

  test(
    'paragraph selections exclude generated markers and preserve originals',
    () {
      final List<Verse> verses = <Verse>[
        _verse('  First\n', verse: 2),
        _verse('😀 second ', verse: 5),
      ];
      final ScriptureParagraphTextMap map = ScriptureParagraphTextMap(
        verses,
        versePrefix: (Verse verse) => '\uFFFC',
      );
      expect(map.text, '\uFFFC  First\n \uFFFC😀 second ');
      final List<ScriptureVerseSelection> all = map.selections(
        0,
        map.text.length,
      );
      expect(all.map((ScriptureVerseSelection item) => item.quote), <String>[
        '  First\n',
        '😀 second ',
      ]);
      expect(all.last.range, const ScriptureTextRange(0, 10));
      final int secondStart = map.locations.last.$2.start;
      expect(map.selections(secondStart, secondStart + 2).single.quote, '😀');
      expect(map.selections(secondStart + 1, secondStart + 2), isEmpty);
      expect(map.selections(0, 1), isEmpty);
    },
  );
}

const Passage _passage = Passage(translation: 'kjv', book: 1, chapter: 1);

Verse _verse(
  String text, {
  int verse = 1,
  List<Object?> tokens = const <Object?>[],
  List<Object?> spans = const <Object?>[],
}) => Verse.fromJson(<String, Object?>{
  'chapter': 1,
  'verse': verse,
  'name': 'Genesis 1:$verse',
  'text': text,
  if (tokens.isNotEmpty || spans.isNotEmpty) 'tokens': tokens,
  if (tokens.isNotEmpty || spans.isNotEmpty) 'spans': spans,
});

Map<String, Object?> _token(String text, int start, int end) =>
    <String, Object?>{'token': text, 'word_start': start, 'word_end': end};

Map<String, Object?> _span(
  String tag,
  String text,
  int start,
  int end, {
  int tokenEnd = 0,
  Map<String, String> attrs = const <String, String>{},
}) => <String, Object?>{
  'tag': tag,
  'span': text,
  'word_start': start,
  'word_end': end,
  'token_start': 0,
  'token_end': tokenEnd,
  if (attrs.isNotEmpty) 'attrs': attrs,
};

MarkingGroup _group(String id) => MarkingGroup(
  id: id,
  name: id,
  color: '#00AAFF',
  updatedAt: DateTime.utc(2026),
);

Marking _marking(
  String id,
  int? start,
  int? end,
  String quote,
  String group,
  int timestamp, {
  String translation = 'kjv',
}) => Marking(
  id: id,
  passage: Passage(translation: translation, book: 1, chapter: 1),
  verse: 1,
  start: start,
  end: end,
  quote: quote,
  reference: 'Genesis 1:1',
  groupId: group,
  createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true),
);

ScriptureTextSegment _segment(
  List<ScriptureTextSegment> segments,
  String text,
) => segments.firstWhere((ScriptureTextSegment item) => item.text == text);
