import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart'
    show QueryExecutor, QueryExecutorUser, OpeningDetails;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/notebook_controller.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/data/repositories/sql_notebook_repository.dart';
import 'package:getbible/domain/models/notebook.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/repositories/notebook_repository.dart';

void main() {
  for (final int version in <int>[1, 2]) {
    test(
      'schema $version forward migration preserves private identities, timestamps and original ranges',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'getbible-notebook-migration-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final File file = File('${directory.path}/getbible.sqlite');
        final NativeDatabase old = NativeDatabase(file);
        await old.ensureOpen(_FixtureUser(version));
        await _seedPrivateData(old, version);
        await old.close();
        final LocalDatabase database = await LocalDatabase.fromExecutor(
          NativeDatabase(file),
        );
        addTearDown(database.close);
        expect(localDatabaseSchemaVersion, 5);
        final note = (await database.getNotes()).single;
        expect(note.id, 'canonical-original');
        expect(note.createdAt.millisecondsSinceEpoch, 111);
        expect(note.updatedAt.millisecondsSinceEpoch, 222);
        expect(note.text, 'Private unchanged 😃');
        expect(
          note.matchesPassage(
            const Passage(translation: 'other', book: 900000123, chapter: 3),
          ),
          isTrue,
        );
        final marking = (await database.getMarkings()).single;
        expect(marking.id, 'range-original');
        expect(marking.quote, 'A😀');
        expect(marking.start, 2);
        expect(marking.end, 5);
        expect((await database.getGroups()).single.id, 'mine');
        expect(await database.readSetting('reader'), '{"private":"same"}');
        final cache = await database.readCache('bible:v2:s1:chapter:fx:1:1');
        expect(cache!.json, '{"saved":"unchanged"}');
        expect(cache.sha, 'source');
        expect(await database.getNotebooks(), isEmpty);
        expect(await database.getNotebookDrafts(), isEmpty);
        await database.saveNotebook(_document(), expectedRevision: null);
        expect(
          (await database.getNotebook('notebook'))!.blocks.single.text,
          'My study',
        );
      },
    );
  }
  test(
    'failed schema 2 to 3 migration rolls back additions and preserves schema and private data',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'getbible-notebook-rollback-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final File file = File('${directory.path}/getbible.sqlite');
      final NativeDatabase old = NativeDatabase(file);
      await old.ensureOpen(_FixtureUser(2));
      await _seedPrivateData(old, 2);
      await old.runCustom('CREATE TABLE notebooks(original TEXT)', <Object?>[]);
      await old.close();
      final NativeDatabase failed = NativeDatabase(file);
      await expectLater(
        LocalDatabase.fromExecutor(failed),
        throwsA(isA<Exception>()),
      );
      await failed.close();
      final NativeDatabase inspect = NativeDatabase(file);
      await inspect.ensureOpen(_FixtureUser(2));
      addTearDown(inspect.close);
      expect(
        (await inspect.runSelect(
          'PRAGMA user_version',
          <Object?>[],
        )).single['user_version'],
        2,
      );
      expect(
        (await inspect.runSelect(
          'SELECT id, created_at, updated_at FROM notes',
          <Object?>[],
        )).single,
        <String, Object?>{
          'id': 'canonical-original',
          'created_at': 111,
          'updated_at': 222,
        },
      );
      final tables = await inspect.runSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
        <Object?>[],
      );
      expect(
        tables.map((row) => row['name']),
        isNot(contains('notebook_blocks')),
      );
      expect(
        tables.map((row) => row['name']),
        isNot(contains('notebook_drafts')),
      );
    },
  );
  test(
    'atomic document activation preserves order, Scripture attribution and creation times',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final Notebook first = _document();
      await database.saveNotebook(first, expectedRevision: null);
      final NotebookReference reference = NotebookReference(
        passage: const Passage(
          translation: 'fx',
          book: 900000123,
          chapter: 3,
          verse: 7,
        ),
        label: 'Extended 3:7',
        quotation: 'Exact 😃 quotation',
      );
      final Notebook updated = first.edit(
        now: DateTime.utc(2026, 1, 2),
        blocks: <NotebookBlock>[
          NotebookBlock(
            id: 'scripture',
            text: 'My thoughts',
            createdAt: first.createdAt,
            updatedAt: first.updatedAt,
            reference: reference,
          ),
          ...first.blocks,
        ],
      );
      await database.saveNotebookDraft(
        updated,
        expectedRevision: first.revision,
      );
      await database.saveNotebook(updated, expectedRevision: first.revision);
      final Notebook saved = (await database.getNotebook(first.id))!;
      expect(saved.blocks.map((NotebookBlock block) => block.id), <String>[
        'scripture',
        'block',
      ]);
      expect(saved.blocks.first.reference!.quotation, 'Exact 😃 quotation');
      expect(saved.blocks.first.reference!.passage.book, 900000123);
      expect(saved.createdAt, first.createdAt);
      expect(saved.blocks.last.createdAt, first.blocks.single.createdAt);
      expect(await database.getNotebookDrafts(), isEmpty);
      await database.clearCache();
      await database.clearScriptureCache();
      await database.clearAllReaderData();
      expect(
        (await database.getNotebook(first.id))!.blocks.first.text,
        'My thoughts',
      );
    },
  );
  test(
    'block collision rolls back document activation and retains durable draft',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final Notebook first = _document();
      await database.saveNotebook(first, expectedRevision: null);
      final Notebook collision = Notebook(
        id: 'second',
        title: 'Second',
        createdAt: first.createdAt,
        updatedAt: first.updatedAt,
        revision: 1,
        blocks: first.blocks,
      );
      await database.saveNotebookDraft(collision, expectedRevision: null);
      await expectLater(
        database.saveNotebook(collision, expectedRevision: null),
        throwsA(isA<Exception>()),
      );
      expect(await database.getNotebook('second'), isNull);
      expect(
        (await database.getNotebook('notebook'))!.blocks.single.text,
        'My study',
      );
      expect((await database.getNotebookDrafts()).single.notebook.id, 'second');
      expect((await database.getNotebookDrafts()).single.baseRevision, isNull);
    },
  );
  test(
    'controller preserves failed drafts across selection and retries without changing original creation identity',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      final _ControlledRepository repository = _ControlledRepository(
        SqlNotebookRepository(database),
      );
      int ids = 0;
      final NotebookController controller = NotebookController(
        repository,
        createId: () => 'id${ids++}',
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(() async {
        await controller.flush();
        controller.dispose();
        await database.close();
      });
      await controller.createNotebook(title: 'First');
      final String firstId = controller.selectedId!;
      final DateTime created = controller.notebook!.createdAt;
      await controller.createNotebook(title: 'Second');
      final String secondId = controller.selectedId!;
      await controller.selectNotebook(firstId);
      repository.failSave = true;
      controller.updateBlockText(
        controller.notebook!.blocks.single.id,
        'Unsaved private words',
      );
      expect(await controller.flush(), isFalse);
      expect(controller.error, isNotNull);
      expect(
        (await database.getNotebookDrafts()).single.notebook.blocks.single.text,
        'Unsaved private words',
      );
      await controller.selectNotebook(secondId);
      expect(controller.hasUnsavedDrafts, isTrue);
      await controller.selectNotebook(firstId);
      expect(controller.notebook!.blocks.single.text, 'Unsaved private words');
      repository.failSave = false;
      await controller.retry();
      expect(controller.isDirty, isFalse);
      expect(controller.error, isNull);
      expect((await database.getNotebook(firstId))!.createdAt, created);
      expect(
        (await database.getNotebook(firstId))!.blocks.single.text,
        'Unsaved private words',
      );
    },
  );
  test(
    'late save completion cannot clear a newer edit; Ctrl save flushes all document revisions',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      final _ControlledRepository repository = _ControlledRepository(
        SqlNotebookRepository(database),
      );
      final NotebookController controller = NotebookController(
        repository,
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(() async {
        await controller.flush();
        controller.dispose();
        await database.close();
      });
      await controller.createNotebook();
      final String id = controller.notebook!.blocks.single.id;
      controller.updateBlockText(id, 'First edit');
      final Completer<void> gate = Completer<void>();
      repository.pause = gate;
      repository.started = Completer<void>();
      final Future<bool> save = controller.flush();
      await repository.started!.future;
      controller.updateBlockText(id, 'Newer edit 😃');
      gate.complete();
      expect(await save, isTrue);
      expect(controller.isDirty, isFalse);
      expect(
        (await database.getNotebook(
          controller.selectedId!,
        ))!.blocks.single.text,
        'Newer edit 😃',
      );
      expect(await database.getNotebookDrafts(), isEmpty);
    },
  );
  test(
    'restart restores durable draft and selected notebook while offline',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final Notebook original = _document();
      await database.saveNotebook(original, expectedRevision: null);
      final Notebook draft = original.edit(
        title: 'Recovered draft',
        now: original.updatedAt,
      );
      await database.saveNotebookDraft(
        draft,
        expectedRevision: original.revision,
      );
      await database.selectNotebook(original.id);
      final NotebookController controller = NotebookController(
        SqlNotebookRepository(database),
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(() async {
        await controller.flush();
        controller.dispose();
      });
      await controller.load();
      expect(controller.selectedId, original.id);
      expect(controller.notebook!.title, 'Recovered draft');
      expect(controller.isDirty, isTrue);
      await controller.flush();
      expect(
        (await database.getNotebook(original.id))!.title,
        'Recovered draft',
      );
    },
  );
  test(
    'recovered conflict keeps both private versions and requires a new notebook copy',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final Notebook original = _document();
      await database.saveNotebook(original, expectedRevision: null);
      final Notebook draft = original
          .edit(title: 'Retained draft', now: original.updatedAt)
          .edit(title: 'Retained draft', now: original.updatedAt);
      await database.saveNotebookDraft(
        draft,
        expectedRevision: original.revision,
      );
      final Notebook external = original.edit(
        title: 'Other editor',
        now: original.updatedAt,
      );
      await database.saveNotebook(
        external,
        expectedRevision: original.revision,
      );
      final NotebookController controller = NotebookController(
        SqlNotebookRepository(database),
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(() async {
        await controller.flush();
        controller.dispose();
      });
      await controller.load();
      expect(controller.hasConflict, isTrue);
      expect(await controller.flush(), isFalse);
      expect((await database.getNotebook(original.id))!.title, 'Other editor');
      await controller.recoverDraftAsNewNotebook();
      expect(controller.notebook!.title, 'Recovered: Retained draft');
      expect(
        controller.notebook!.blocks.single.id,
        isNot(original.blocks.single.id),
      );
      expect((await database.getNotebook(original.id))!.title, 'Other editor');
      expect(await database.getNotebookDrafts(), isEmpty);
    },
  );
  test(
    'model rejects unsupported versions, duplicate identities and invalid reference coordinates',
    () {
      expect(
        () => Notebook.fromJson(<String, Object?>{
          ..._document().toJson(),
          'version': 2,
        }),
        throwsFormatException,
      );
      final Notebook original = _document();
      expect(
        () => Notebook(
          id: 'duplicate',
          title: '',
          createdAt: original.createdAt,
          updatedAt: original.updatedAt,
          revision: 1,
          blocks: <NotebookBlock>[...original.blocks, ...original.blocks],
        ),
        throwsFormatException,
      );
      expect(
        () => NotebookReference(
          passage: const Passage(translation: 'fx', book: 1, chapter: 0),
          label: 'Introduction',
        ),
        throwsFormatException,
      );
      expect(Notebook.fromJson(original.toJson()).toJson(), original.toJson());
    },
  );

  test(
    'independent editors retain both journals and one activation never clears another editor draft',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final SqlNotebookRepository sql = SqlNotebookRepository(database);
      final Notebook original = _document();
      await sql.save(original, expectedRevision: null);
      final _ControlledRepository firstRepository = _ControlledRepository(sql)
        ..failSave = true;
      final _ControlledRepository secondRepository = _ControlledRepository(sql)
        ..failSave = true;
      final NotebookController first = NotebookController(
        firstRepository,
        autosaveDelay: const Duration(hours: 1),
      );
      final NotebookController second = NotebookController(
        secondRepository,
        autosaveDelay: const Duration(hours: 1),
      );
      await first.load();
      await second.load();
      first.updateBlockText('block', 'First private draft');
      second.updateBlockText('block', 'Second private draft');
      await first.flush();
      await second.flush();
      final List<NotebookDraft> journals = await sql.drafts();
      expect(journals.length, 2);
      expect(
        journals.map((NotebookDraft draft) => draft.editorId).toSet().length,
        2,
      );
      expect(
        journals
            .map((NotebookDraft draft) => draft.notebook.blocks.single.text)
            .toSet(),
        <String>{'First private draft', 'Second private draft'},
      );
      firstRepository.failSave = false;
      await first.retry();
      expect(
        (await sql.drafts()).single.notebook.blocks.single.text,
        'Second private draft',
      );
      secondRepository.failSave = false;
      await second.retry();
      expect(second.hasConflict, isTrue);
      expect(
        (await sql.notebook(original.id))!.blocks.single.text,
        'First private draft',
      );
      await second.recoverDraftAsNewNotebook();
      expect(
        (await sql.notebook(original.id))!.blocks.single.text,
        'First private draft',
      );
      expect(second.notebook!.blocks.single.text, 'Second private draft');
      expect(second.notebook!.id, isNot(original.id));
      expect(await sql.drafts(), isEmpty);
      first.dispose();
      second.dispose();
    },
  );

  test(
    'database file reopen restores a durable failed draft and selected notebook without network access',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'getbible-notebook-restart-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final File file = File('${directory.path}/getbible.sqlite');
      final LocalDatabase firstDatabase = await LocalDatabase.fromExecutor(
        NativeDatabase(file),
      );
      final _ControlledRepository repository = _ControlledRepository(
        SqlNotebookRepository(firstDatabase),
      );
      final NotebookController first = NotebookController(
        repository,
        autosaveDelay: const Duration(hours: 1),
      );
      await first.createNotebook(title: 'Offline sermon');
      final String selectedId = first.selectedId!;
      repository.failSave = true;
      first.updateBlockText(
        first.notebook!.blocks.single.id,
        'Durable private draft 😃',
      );
      expect(await first.flush(), isFalse);
      first.dispose();
      await firstDatabase.close();
      final LocalDatabase reopened = await LocalDatabase.fromExecutor(
        NativeDatabase(file),
      );
      addTearDown(reopened.close);
      final NotebookController restored = NotebookController(
        SqlNotebookRepository(reopened),
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(() async {
        await restored.flush();
        restored.dispose();
      });
      await restored.load();
      expect(restored.selectedId, selectedId);
      expect(restored.notebook!.title, 'Offline sermon');
      expect(restored.notebook!.blocks.single.text, 'Durable private draft 😃');
      expect(restored.isDirty, isTrue);
      expect(await restored.flush(), isTrue);
      expect(
        (await reopened.getNotebook(selectedId))!.blocks.single.text,
        'Durable private draft 😃',
      );
    },
  );

  test(
    'restart exposes additional editor drafts for explicit recovery rather than discarding a private version',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final Notebook original = _document();
      await database.saveNotebook(original, expectedRevision: null);
      await database.saveNotebookDraft(
        original.edit(title: 'First retained version', now: original.updatedAt),
        expectedRevision: 1,
        editorId: 'first',
      );
      await database.saveNotebookDraft(
        original.edit(
          title: 'Second retained version',
          now: original.updatedAt,
        ),
        expectedRevision: 1,
        editorId: 'second',
      );
      final NotebookController restored = NotebookController(
        SqlNotebookRepository(database),
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(() async {
        await restored.flush();
        restored.dispose();
      });
      await restored.load();
      expect(
        restored.additionalRecoveredDrafts.single.notebook.title,
        'Second retained version',
      );
      expect(await restored.flush(), isFalse);
      expect(
        (await database.getNotebook(original.id))!.title,
        'First retained version',
      );
      expect(
        (await database.getNotebookDrafts()).single.notebook.title,
        'Second retained version',
      );
      await restored.recoverSavedDraft(
        restored.additionalRecoveredDrafts.single,
      );
      expect(restored.additionalRecoveredDrafts, isEmpty);
      expect(
        (await database.getNotebook(original.id))!.title,
        'First retained version',
      );
      expect(restored.notebook!.title, 'Recovered: Second retained version');
      expect(await database.getNotebookDrafts(), isEmpty);
    },
  );

  test(
    'two editors recovering one journal fork distinct durable revisions and retire the original only after activation',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final SqlNotebookRepository sql = SqlNotebookRepository(database);
      final Notebook original = _document();
      await sql.save(original, expectedRevision: null);
      await sql.saveDraft(
        original.edit(title: 'Recovered', now: original.updatedAt),
        expectedRevision: 1,
        editorId: 'crashed-editor',
      );
      final _ControlledRepository firstRepository = _ControlledRepository(sql)
        ..failSave = true;
      final _ControlledRepository secondRepository = _ControlledRepository(sql)
        ..failSave = true;
      final NotebookController first = NotebookController(
        firstRepository,
        autosaveDelay: const Duration(hours: 1),
      );
      final NotebookController second = NotebookController(
        secondRepository,
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.load();
      await second.load();
      first.updateBlockText('block', 'First private revision');
      second.updateBlockText('block', 'Second private revision');
      expect(await first.flush(), isFalse);
      expect(await second.flush(), isFalse);
      final List<NotebookDraft> journals = await sql.drafts();
      expect(journals.length, 3);
      expect(
        journals.map((NotebookDraft draft) => draft.editorId).toSet().length,
        3,
      );
      expect(
        journals
            .map((NotebookDraft draft) => draft.notebook.blocks.single.text)
            .toSet(),
        <String>{
          'My study',
          'First private revision',
          'Second private revision',
        },
      );
      expect(
        journals
            .singleWhere(
              (NotebookDraft draft) => draft.editorId == 'crashed-editor',
            )
            .notebook
            .blocks
            .single
            .text,
        'My study',
      );
      secondRepository.failSave = false;
      await second.retry();
      expect(
        (await sql.notebook(original.id))!.blocks.single.text,
        'Second private revision',
      );
      expect(
        (await sql.drafts()).single.notebook.blocks.single.text,
        'First private revision',
      );
      firstRepository.failSave = false;
      await first.retry();
      expect(first.hasConflict, isTrue);
      await first.recoverDraftAsNewNotebook();
      expect(first.notebook!.blocks.single.text, 'First private revision');
      expect(
        (await sql.notebook(original.id))!.blocks.single.text,
        'Second private revision',
      );
      expect(await sql.drafts(), isEmpty);
    },
  );

  test(
    'editing a recovered conflict persists a new private journal before explicit copy resolution',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final Notebook original = _document();
      await database.saveNotebook(original, expectedRevision: null);
      final Notebook recovered = original
          .edit(title: 'Old private draft', now: original.updatedAt)
          .edit(title: 'Old private draft', now: original.updatedAt);
      await database.saveNotebookDraft(
        recovered,
        expectedRevision: 1,
        editorId: 'old',
      );
      await database.saveNotebook(
        original.edit(title: 'Newer saved document', now: original.updatedAt),
        expectedRevision: 1,
      );
      final NotebookController first = NotebookController(
        SqlNotebookRepository(database),
        autosaveDelay: const Duration(hours: 1),
      );
      await first.load();
      expect(first.hasConflict, isTrue);
      first.updateBlockText('block', 'Further private edits during conflict');
      expect(await first.flush(), isFalse);
      expect(
        (await database.getNotebook(original.id))!.title,
        'Newer saved document',
      );
      expect(
        (await database.getNotebookDrafts()).map(
          (NotebookDraft draft) => draft.notebook.blocks.single.text,
        ),
        contains('Further private edits during conflict'),
      );
      first.dispose();
      final NotebookController restored = NotebookController(
        SqlNotebookRepository(database),
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(
        restored.notebook!.blocks.single.text,
        'Further private edits during conflict',
      );
      expect(restored.hasConflict, isTrue);
    },
  );

  test(
    'durability distinguishes failed journal writes from safely retained failed activation',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final _ControlledRepository repository = _ControlledRepository(
        SqlNotebookRepository(database),
      );
      final NotebookController controller = NotebookController(
        repository,
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(controller.dispose);
      await controller.createNotebook();
      expect(controller.hasUndurableDrafts, isFalse);
      repository.failJournal = true;
      controller.updateBlockText(
        controller.notebook!.blocks.single.id,
        'Latest private revision needs a durable journal',
      );
      expect(controller.hasUndurableDrafts, isTrue);
      expect(await controller.flush(), isFalse);
      expect(controller.hasUndurableDrafts, isTrue);
      expect(await database.getNotebookDrafts(), isEmpty);
      expect(
        controller.notebook!.blocks.single.text,
        'Latest private revision needs a durable journal',
      );
      repository.failJournal = false;
      repository.failSave = true;
      expect(await controller.flush(), isFalse);
      expect(controller.hasUnsavedDrafts, isTrue);
      expect(controller.hasUndurableDrafts, isFalse);
      expect(
        (await database.getNotebookDrafts()).single.notebook.blocks.single.text,
        'Latest private revision needs a durable journal',
      );
      controller.updateBlockText(
        controller.notebook!.blocks.single.id,
        'A newer revision is not covered by the old journal',
      );
      expect(controller.hasUndurableDrafts, isTrue);
      expect(await controller.flush(), isFalse);
      expect(controller.hasUndurableDrafts, isFalse);
      repository.failSave = false;
      await controller.retry();
      expect(controller.hasUnsavedDrafts, isFalse);
      expect(controller.hasUndurableDrafts, isFalse);
    },
  );

  test(
    'loaded unchanged journals remain durable if a new journal write fails, while later private edits require durability',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final Notebook original = _document();
      await database.saveNotebook(original, expectedRevision: null);
      await database.saveNotebookDraft(
        original.edit(
          title: 'Durable recovered title',
          now: original.updatedAt,
        ),
        expectedRevision: 1,
        editorId: 'recovered',
      );
      final _ControlledRepository repository = _ControlledRepository(
        SqlNotebookRepository(database),
      )..failJournal = true;
      final NotebookController controller = NotebookController(
        repository,
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.hasUnsavedDrafts, isTrue);
      expect(controller.hasUndurableDrafts, isFalse);
      expect(await controller.flush(), isFalse);
      expect(controller.hasUndurableDrafts, isFalse);
      controller.updateTitle('New private title not yet journaled');
      expect(controller.hasUndurableDrafts, isTrue);
      expect(await controller.flush(), isFalse);
      expect(controller.hasUndurableDrafts, isTrue);
      expect(
        (await database.getNotebookDrafts()).single.notebook.title,
        'Durable recovered title',
      );
      repository.failJournal = false;
      expect(await controller.flush(), isTrue);
      expect(controller.hasUndurableDrafts, isFalse);
      expect(
        (await database.getNotebook(original.id))!.title,
        'New private title not yet journaled',
      );
    },
  );
}

Notebook _document() => Notebook(
  id: 'notebook',
  title: 'My sermon',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  revision: 1,
  blocks: <NotebookBlock>[
    NotebookBlock(
      id: 'block',
      text: 'My study',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
  ],
);

Future<void> _seedPrivateData(QueryExecutor old, int version) async {
  await old.runCustom(
    'INSERT INTO marking_groups VALUES(?, ?, ?, ?, ?, ?)',
    <Object?>['mine', 'My private group', '#123456', 0, 0, 111],
  );
  await old.runCustom(
    'INSERT INTO markings VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      'range-original',
      'fx',
      900000123,
      3,
      7,
      2,
      5,
      'A😀',
      'Extended 3:7',
      'mine',
      111,
    ],
  );
  await old.runCustom(
    'INSERT INTO notes VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      'canonical-original',
      '900000123/3/7',
      'fx',
      900000123,
      3,
      7,
      'Extended 3:7',
      'Private unchanged 😃',
      111,
      222,
    ],
  );
  await old.runCustom('INSERT INTO settings VALUES(?, ?, ?)', <Object?>[
    'reader',
    '{"private":"same"}',
    111,
  ]);
  await old.runCustom(
    'INSERT INTO cache_entries(cache_key, kind, sha, payload, checked_at, cached_at) VALUES(?, ?, ?, ?, ?, ?)',
    <Object?>[
      version == 1 ? 'chapter:fx:1:1' : 'bible:v2:s1:chapter:fx:1:1',
      'chapter',
      'source',
      '{"saved":"unchanged"}',
      111,
      111,
    ],
  );
}

final class _FixtureUser extends QueryExecutorUser {
  _FixtureUser(this.version);
  final int version;
  @override
  int get schemaVersion => version;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    await executor.ensureOpen(this);
    if (details.wasCreated) {
      final String sql = File(
        'test/fixtures/database_schema_v$version.sql',
      ).readAsStringSync();
      for (final String statement
          in sql
              .split(';')
              .where((String statement) => statement.trim().isNotEmpty)) {
        await executor.runCustom(statement);
      }
    }
  }
}

final class _ControlledRepository implements NotebookRepository {
  _ControlledRepository(this.delegate);
  final NotebookRepository delegate;
  bool failSave = false;
  bool failJournal = false;
  Completer<void>? pause;
  Completer<void>? started;
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
      throw StateError('Draft journal storage temporarily unavailable');
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
  }) async {
    if (failSave) throw StateError('Storage temporarily unavailable');
    final Completer<void>? gate = pause;
    if (gate != null) {
      pause = null;
      started!.complete();
      await gate.future;
    }
    await delegate.save(
      notebook,
      expectedRevision: expectedRevision,
      editorId: editorId,
    );
  }

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
