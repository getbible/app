import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/app_state.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/annotations.dart';
import 'package:getbible_live/domain/models/bible.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/services/scripture_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'paragraph batches validate every range before writing any record',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      final AppState state = AppState.fromDatabase(database);
      addTearDown(state.close);
      const Passage origin = Passage(translation: 'tst', book: 1, chapter: 1);
      const Verse first = Verse(
        chapter: 1,
        verse: 1,
        name: 'First',
        text: ' A 😀 ',
      );
      const Verse second = Verse(
        chapter: 1,
        verse: 3,
        name: 'Third',
        text: ' Third. ',
      );
      state.passage = origin;
      state.current = const BibleChapter(
        translation: 'Fixture',
        abbreviation: 'tst',
        language: 'English',
        direction: 'LTR',
        bookNumber: 1,
        bookName: 'Genesis',
        chapter: 1,
        name: 'Genesis 1',
        verses: <Verse>[first, second],
      );
      final MarkingGroup group = MarkingGroup(
        id: 'personal',
        name: 'Personal',
        color: '#11AAFF',
        updatedAt: DateTime.utc(2026),
      );
      state.groups = <MarkingGroup>[group];
      await state.annotations.saveGroup(group);
      const ScriptureVerseSelection valid = ScriptureVerseSelection(
        verse: first,
        range: ScriptureTextRange(3, 5),
      );
      await state.markTextSelections(
        origin,
        const <ScriptureVerseSelection>[
          valid,
          ScriptureVerseSelection(
            verse: second,
            range: ScriptureTextRange(1, 99),
          ),
        ],
        'Genesis',
        group.id,
      );
      expect(await state.annotations.getMarkings(), isEmpty);

      const List<ScriptureVerseSelection> batch = <ScriptureVerseSelection>[
        valid,
        ScriptureVerseSelection(verse: second, range: ScriptureTextRange(1, 6)),
      ];
      await state.markTextSelections(origin, batch, 'Genesis', group.id);
      expect(
        state.markings.map((Marking item) => item.quote),
        unorderedEquals(<String>['😀', 'Third']),
      );
      expect(
        state.markings.every((Marking item) => item.passage == origin),
        isTrue,
      );
      state.passage = origin.copyWith(chapter: 2);
      await state.markTextSelections(origin, batch, 'Genesis', group.id);
      expect((await state.annotations.getMarkings()).length, 2);
    },
  );

  test(
    'native original ranges save verbatim; removal retains independent records',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      final AppState state = AppState.fromDatabase(database);
      addTearDown(state.close);
      const Passage passage = Passage(translation: 'kjv', book: 1, chapter: 1);
      const Verse verse = Verse(
        chapter: 1,
        verse: 1,
        name: 'Genesis 1:1',
        text: ' A 😀 e\u0301. ',
      );
      final MarkingGroup group = MarkingGroup(
        id: 'personal',
        name: 'Personal',
        color: '#11AAFF',
        updatedAt: DateTime.utc(2026),
      );
      state.passage = passage;
      state.groups = <MarkingGroup>[group];
      await state.annotations.saveGroup(group);
      await state.markSelectedText(verse, 3, 5, verse.name, group.id);
      final Marking emoji = state.markings.single;
      expect(emoji.quote, '😀');
      expect(emoji.start, 3);
      expect(emoji.end, 5);
      expect(
        ScriptureTextMap(verse.text).matchesQuote(
          ScriptureTextRange(emoji.start!, emoji.end!),
          emoji.quote,
        ),
        isTrue,
      );

      final List<Marking> independent = <Marking>[
        _marking(
          'whole',
          passage.copyWith(translation: 'web'),
          1,
          null,
          null,
          'different translation text',
        ),
        _marking(
          'other-translation',
          passage.copyWith(translation: 'web'),
          1,
          3,
          5,
          'other',
        ),
        _marking('other-verse', passage, 2, 3, 5, '😀'),
        _marking('non-overlapping', passage, 1, 6, 8, 'e\u0301'),
      ];
      for (final Marking item in independent) {
        await state.annotations.saveMarking(item);
      }
      final VerseNote note = VerseNote(
        id: 'local-note',
        passage: passage,
        verse: 1,
        reference: verse.name,
        text: 'Keep this note.',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      await state.annotations.saveNote(note);
      state.markings = await state.annotations.getMarkingsForPassage(passage);
      expect(state.selectionHasMarking(1, 3, 5), isTrue);
      await state.removeSelectionMarkings(1, 3, 5);
      final List<Marking> remaining = await state.annotations.getMarkings();
      expect(
        remaining.map((Marking item) => item.id),
        unorderedEquals(independent.map((Marking item) => item.id)),
      );
      expect((await state.annotations.getNotes()).single.text, note.text);
      expect(state.selectionHasMarking(1, 3, 5), isFalse);
    },
  );
}

Marking _marking(
  String id,
  Passage passage,
  int verse,
  int? start,
  int? end,
  String quote,
) => Marking(
  id: id,
  passage: passage,
  verse: verse,
  start: start,
  end: end,
  quote: quote,
  reference: 'Genesis 1:$verse',
  groupId: 'personal',
  createdAt: DateTime.utc(2026),
);
