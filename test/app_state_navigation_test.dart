import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/preferences.dart';
import 'support/reader_api_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'chapter turns use discovered extended-book chapter identities',
    () async {
      final ReaderApiFixture fixture = ReaderApiFixture();
      final LocalDatabase database = await LocalDatabase.memory();
      final AppState state = AppState.fromDatabase(database, api: fixture.api);
      addTearDown(state.close);

      await state.loadPassage(
        const Passage(translation: 'tst', book: 1, chapter: 1),
      );
      expect(state.error, isNull);
      await state.turnChapter(1);
      expect(state.passage.book, ReaderApiFixture.extendedBook);
      expect(state.passage.chapter, 7);
      expect(
        fixture.paths,
        isNot(contains('/v3/tst/${ReaderApiFixture.extendedBook}/1.json')),
      );
      await state.turnChapter(-1);
      expect(state.passage.book, 1);
      expect(state.passage.chapter, 1);
    },
  );

  test(
    'an unavailable exact verse leaves reader and saved position intact',
    () async {
      final ReaderApiFixture fixture = ReaderApiFixture();
      final LocalDatabase database = await LocalDatabase.memory();
      final AppState state = AppState.fromDatabase(database, api: fixture.api);
      addTearDown(state.close);
      const Passage original = Passage(
        translation: 'tst',
        book: 1,
        chapter: 1,
        verse: 3,
      );
      await state.loadPassage(original);
      final LastReadingPosition? before = await state.settings
          .getLastReadingPosition();

      await state.loadPassage(
        const Passage(translation: 'tst', book: 1, chapter: 1, verse: 2),
      );

      expect(state.error, contains('verse is not available'));
      expect(state.passage, original);
      expect(state.current?.verses.last.verse, 3);
      final LastReadingPosition? after = await state.settings
          .getLastReadingPosition();
      expect(after?.passage, before?.passage);
      expect(after?.updatedAt, before?.updatedAt);
    },
  );
  test('a delayed book selection cannot override a newer passage', () async {
    final ReaderApiFixture fixture = ReaderApiFixture();
    final LocalDatabase database = await LocalDatabase.memory();
    final AppState state = AppState.fromDatabase(database, api: fixture.api);
    addTearDown(state.close);
    await state.loadPassage(
      const Passage(translation: 'tst', book: 1, chapter: 1),
    );
    fixture.delayedIndex = Completer<void>();
    final Future<void> delayed = state.openBook(ReaderApiFixture.extendedBook);
    await fixture.indexStarted.future;
    const Passage newer = Passage(
      translation: 'tst',
      book: 1,
      chapter: 1,
      verse: 3,
    );
    await state.loadPassage(newer);
    fixture.delayedIndex!.complete();
    await delayed;
    expect(state.passage, newer);
    expect((await state.settings.getLastReadingPosition())?.passage, newer);
  });

  test(
    'dismissed caller ownership prevents pending navigation activation',
    () async {
      final ReaderApiFixture fixture = ReaderApiFixture();
      final LocalDatabase database = await LocalDatabase.memory();
      final AppState state = AppState.fromDatabase(database, api: fixture.api);
      addTearDown(state.close);
      const Passage original = Passage(translation: 'tst', book: 1, chapter: 1);
      await state.loadPassage(original);
      fixture.delayedIndex = Completer<void>();
      bool visible = true;
      final Future<void> opening = state.loadPassage(
        const Passage(
          translation: 'tst',
          book: ReaderApiFixture.extendedBook,
          chapter: 7,
        ),
        ownsRequest: () => visible,
      );
      await fixture.indexStarted.future;
      visible = false;
      fixture.delayedIndex!.complete();
      await opening;
      expect(state.passage, original);
      expect(
        (await state.settings.getLastReadingPosition())?.passage,
        original,
      );
      expect(state.loading, isFalse);
    },
  );
}
