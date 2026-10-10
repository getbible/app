import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/app_state.dart';
import 'package:getbible_live/core/errors.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/data/repositories/sql_notebook_repository.dart';
import 'package:getbible_live/domain/models/notebook.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/repositories/notebook_repository.dart';

import 'support/reader_api_fixture.dart';

void main() {
  test('overlapping shutdowns await the last private notebook edit', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'getbible-shutdown-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final File file = File('${directory.path}/study.sqlite');
    final AppState state = AppState.fromDatabase(
      await LocalDatabase.fromExecutor(NativeDatabase(file)),
      api: ReaderApiFixture().api,
    );
    final notebooks = state.study.notebooks;
    await notebooks.load();
    await notebooks.createNotebook(title: 'Shutdown recovery');
    final String id = notebooks.notebook!.id;
    notebooks.updateBlockText(
      notebooks.notebook!.blocks.single.id,
      'Final private edit before the autosave timer runs 😃',
    );

    final Future<void> first = state.close();
    final Future<void> second = state.close();
    expect(identical(first, second), isTrue);
    await Future.wait(<Future<void>>[first, second]);

    final LocalDatabase reopened = await LocalDatabase.fromExecutor(
      NativeDatabase(file),
    );
    addTearDown(reopened.close);
    expect(
      (await reopened.getNotebook(id))!.blocks.single.text,
      'Final private edit before the autosave timer runs 😃',
    );
    expect(await reopened.getNotebookDrafts(), isEmpty);
  });

  test(
    'successful shutdown cancels late passage activation before storage closes',
    () async {
      final gate = Completer<void>();
      final fixture = ReaderApiFixture()..delayedIndex = gate;
      final state = AppState.fromDatabase(
        await LocalDatabase.memory(),
        api: fixture.api,
      );
      await state.loadPassage(
        const Passage(translation: 'tst', book: 1, chapter: 1),
      );
      final pending = state.loadPassage(
        const Passage(
          translation: 'tst',
          book: ReaderApiFixture.extendedBook,
          chapter: 7,
        ),
      );
      await fixture.indexStarted.future;
      await state.close();
      gate.complete();
      await pending;
      expect(state.passage.book, 1);
      expect(state.loading, isFalse);
      expect(state.error, isNull);
    },
  );

  test(
    'failed journal write keeps app and draft usable until close retry',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      final _JournalFailureRepository repository = _JournalFailureRepository(
        SqlNotebookRepository(database),
      );
      final Completer<void> passageGate = Completer<void>();
      final ReaderApiFixture fixture = ReaderApiFixture()
        ..delayedIndex = passageGate;
      final AppState state = AppState.fromDatabase(
        database,
        api: fixture.api,
        notebookRepository: repository,
      );
      addTearDown(() async {
        if (!passageGate.isCompleted) passageGate.complete();
        repository.failJournal = false;
        await state.close();
      });
      await state.loadPassage(
        const Passage(translation: 'tst', book: 1, chapter: 1),
      );
      final notebooks = state.study.notebooks;
      await notebooks.load();
      await notebooks.createNotebook(title: 'Retry shutdown');
      final String id = notebooks.notebook!.id;
      repository.failJournal = true;
      notebooks.updateBlockText(
        notebooks.notebook!.blocks.single.id,
        'Keep this final edit available for retry',
      );
      final Future<void> pendingPassage = state.loadPassage(
        const Passage(
          translation: 'tst',
          book: ReaderApiFixture.extendedBook,
          chapter: 7,
        ),
      );
      await fixture.indexStarted.future;
      expect(state.loading, isTrue);
      await expectLater(state.close(), throwsA(isA<StorageException>()));
      expect(
        state.loading,
        isTrue,
        reason:
            'A failed private-durability gate must retain pending navigation.',
      );
      expect(notebooks.hasUndurableDrafts, isTrue);
      expect(
        notebooks.notebook!.blocks.single.text,
        'Keep this final edit available for retry',
      );
      await database.writeSetting('shutdown-retry', 'usable');
      expect(
        jsonDecode((await database.readSetting('shutdown-retry'))!),
        'usable',
      );
      expect(
        (await state.bibles.getTranslations(forceRefresh: true)).data,
        isNotEmpty,
      );
      passageGate.complete();
      await pendingPassage;
      expect(state.loading, isFalse);
      expect(state.passage.book, ReaderApiFixture.extendedBook);
      await state.loadPassage(
        const Passage(translation: 'tst', book: 1, chapter: 1),
      );
      expect(state.passage.book, 1);

      repository.failJournal = false;
      await notebooks.retry();
      expect(notebooks.hasUndurableDrafts, isFalse);
      expect(
        (await database.getNotebook(id))!.blocks.single.text,
        'Keep this final edit available for retry',
      );
      await state.close();
    },
  );
}

/// Fails only the journal boundary, before any recovery record is durable.
final class _JournalFailureRepository implements NotebookRepository {
  _JournalFailureRepository(this.delegate);
  final NotebookRepository delegate;
  bool failJournal = false;
  @override
  Future<List<NotebookSummary>> notebooks() => delegate.notebooks();
  @override
  Future<Notebook?> notebook(String id) => delegate.notebook(id);
  @override
  Future<List<NotebookDraft>> drafts() => delegate.drafts();
  @override
  Future<void> saveDraft(
    Notebook notebook, {
    required int? expectedRevision,
    String editorId = 'primary',
  }) async {
    if (failJournal) {
      throw const StorageException('Journal storage unavailable');
    }
    await delegate.saveDraft(
      notebook,
      expectedRevision: expectedRevision,
      editorId: editorId,
    );
  }

  @override
  Future<void> save(
    Notebook notebook, {
    required int? expectedRevision,
    String editorId = 'primary',
  }) => delegate.save(
    notebook,
    expectedRevision: expectedRevision,
    editorId: editorId,
  );
  @override
  Future<void> discardDraft(
    String id,
    int revision, {
    String editorId = 'primary',
  }) => delegate.discardDraft(id, revision, editorId: editorId);
  @override
  Future<void> delete(String id) => delegate.delete(id);
  @override
  Future<String?> selectedNotebook() => delegate.selectedNotebook();
  @override
  Future<void> selectNotebook(String? id) => delegate.selectNotebook(id);
}
