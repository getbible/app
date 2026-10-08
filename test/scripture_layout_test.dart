import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/domain/models/bible.dart';
import 'package:getbible_live/services/scripture_layout.dart';

void main() {
  test(
    'editorial paragraphs use emitted IDs and ordered headings precede anchor',
    () {
      final BibleChapter chapter = _chapter(
        <Object?>[
          <String, Object?>{
            'order': 0,
            'type': 'heading',
            'anchor': <String, Object?>{'verse': 3, 'edge': 'before'},
            'text': 'First heading',
            'heading_type': 'section',
            'canonical': false,
          },
          <String, Object?>{
            'order': 1,
            'type': 'heading',
            'anchor': <String, Object?>{'verse': 3, 'edge': 'before'},
            'text': 'Second heading',
            'heading_type': 'section',
            'canonical': true,
          },
          <String, Object?>{
            'order': 2,
            'type': 'paragraph',
            'start': 3,
            'end': 8,
          },
          <String, Object?>{
            'order': 3,
            'type': 'paragraph',
            'start': 12,
            'end': 12,
          },
        ],
        <int>[3, 6, 8, 12],
      );
      final List<ScriptureReadingBlock> blocks = ScriptureChapterLayout(
        chapter,
      ).blocks;
      expect(
        (blocks[0] as ScriptureHeadingBlock).heading.text,
        'First heading',
      );
      expect(
        (blocks[1] as ScriptureHeadingBlock).heading.text,
        'Second heading',
      );
      expect(
        (blocks[2] as ScriptureParagraphBlock).verses.map(
          (Verse item) => item.verse,
        ),
        <int>[3, 6, 8],
      );
      expect((blocks[3] as ScriptureParagraphBlock).verses.single.verse, 12);
    },
  );

  test(
    'heading inside a paragraph splits before that verse without duplicate title',
    () {
      final BibleChapter chapter = _chapter(
        <Object?>[
          <String, Object?>{
            'order': 0,
            'type': 'paragraph',
            'start': 1,
            'end': 4,
          },
          <String, Object?>{
            'order': 1,
            'type': 'heading',
            'anchor': <String, Object?>{'verse': 3, 'edge': 'before'},
            'text': 'Heading',
            'heading_type': 'section',
            'canonical': false,
          },
        ],
        <int>[1, 2, 3, 4],
      );
      final List<ScriptureReadingBlock> blocks = ScriptureChapterLayout(
        chapter,
      ).blocks;
      expect(blocks, hasLength(3));
      expect(
        (blocks.first as ScriptureParagraphBlock).verses.map(
          (Verse item) => item.verse,
        ),
        <int>[1, 2],
      );
      expect((blocks[1] as ScriptureHeadingBlock).heading.text, 'Heading');
      expect(
        (blocks.last as ScriptureParagraphBlock).verses.map(
          (Verse item) => item.verse,
        ),
        <int>[3, 4],
      );
    },
  );

  test('missing heading anchor is never substituted with another verse', () {
    final BibleChapter chapter = _chapter(
      <Object?>[
        <String, Object?>{
          'order': 0,
          'type': 'heading',
          'anchor': <String, Object?>{'verse': 2, 'edge': 'before'},
          'text': 'Unavailable heading',
          'heading_type': 'section',
          'canonical': false,
        },
      ],
      <int>[1, 3],
    );
    expect(
      ScriptureChapterLayout(chapter).blocks.whereType<ScriptureHeadingBlock>(),
      isEmpty,
    );
  });

  test('legacy verse titles remain visible without duplicating editorial', () {
    final BibleChapter base = _chapter(
      <Object?>[
        <String, Object?>{
          'order': 0,
          'type': 'heading',
          'anchor': <String, Object?>{'verse': 1, 'edge': 'before'},
          'text': 'Already editorial',
          'heading_type': 'section',
          'canonical': false,
        },
      ],
      <int>[1, 2],
    );
    final Map<String, Object?> json = base.toJson();
    json['verses'] = <Object?>[
      <String, Object?>{
        ...base.verses.first.toJson(),
        'titles': <Object?>[
          <String, Object?>{'text': 'Already editorial'},
          <String, Object?>{
            'text': 'Additional source title',
            'type': 'section',
          },
        ],
      },
      <String, Object?>{
        ...base.verses.last.toJson(),
        'titles': <Object?>[
          <String, Object?>{'text': 'Legacy title', 'canonical': true},
        ],
      },
    ];
    final List<ScriptureReadingBlock> blocks = ScriptureChapterLayout(
      BibleChapter.fromJson(json),
    ).blocks;
    expect(
      blocks.whereType<ScriptureHeadingBlock>().map(
        (ScriptureHeadingBlock item) => item.heading.text,
      ),
      <String>['Already editorial', 'Additional source title', 'Legacy title'],
    );
    expect((blocks.last as ScriptureParagraphBlock).verses.single.verse, 2);
  });

  test('plain verse paragraph flags are used without editorial ranges', () {
    final BibleChapter base = _chapter(const <Object?>[], <int>[1, 2, 3]);
    final Map<String, Object?> json = base.toJson();
    json['verses'] = <Object?>[
      ...base.verses.take(2).map((Verse item) => item.toJson()),
      <String, Object?>{...base.verses.last.toJson(), 'paragraph': true},
    ];
    final List<ScriptureReadingBlock> blocks = ScriptureChapterLayout(
      BibleChapter.fromJson(json),
    ).blocks;
    expect(blocks, hasLength(2));
    expect((blocks.first as ScriptureParagraphBlock).verses, hasLength(2));
    expect((blocks.last as ScriptureParagraphBlock).verses.single.verse, 3);
  });
}

BibleChapter _chapter(List<Object?> editorial, List<int> verses) =>
    BibleChapter.fromJson(<String, Object?>{
      'translation': 'Test',
      'abbreviation': 'kjv',
      'language': 'English',
      'direction': 'LTR',
      'book_nr': 1,
      'book_name': 'Genesis',
      'chapter': 1,
      'name': 'Genesis 1',
      if (editorial.isNotEmpty) 'editorial': editorial,
      'verses': <Object?>[
        for (final int verse in verses)
          <String, Object?>{
            'chapter': 1,
            'verse': verse,
            'name': 'Genesis 1:$verse',
            'text': 'Verse $verse',
          },
      ],
    });
