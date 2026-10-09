import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/notebook_controller.dart';
import 'package:getbible_live/application/portability_controller.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/data/repositories/sql_notebook_repository.dart';
import 'package:getbible_live/data/repositories/sql_private_data_repository.dart';
import 'package:getbible_live/domain/models/annotations.dart';
import 'package:getbible_live/domain/models/backup.dart';
import 'package:getbible_live/domain/models/notebook.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/preferences.dart';
import 'package:getbible_live/domain/models/private_backup.dart';
import 'package:getbible_live/domain/repositories/private_data_repository.dart';

final DateTime _created = DateTime.utc(2026, 1, 1);
final DateTime _updated = DateTime.utc(2026, 1, 2);

void main() {
  test(
    'complete backup restores original annotations, notebook, two journals and choices after SQLite reopen',
    () async {
      final LocalDatabase source = await LocalDatabase.memory();
      addTearDown(source.close);
      await _seed(source);
      final PrivateBackup exported = await source.privateSnapshot();
      final PrivateBackup parsed = decodePrivateBackup(
        encodePrivateBackup(exported),
      );
      final Directory directory = await Directory.systemTemp.createTemp(
        'getbible-private-restore-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final File file = File('${directory.path}/getbible.sqlite');
      LocalDatabase destination = await LocalDatabase.fromExecutor(
        NativeDatabase(file),
      );
      final PrivateImportResult result = await destination.importPrivateBackup(
        parsed,
      );
      expect(result.notebooksAdded, 1);
      expect(result.draftsAdded, 2);
      await destination.close();
      destination = await LocalDatabase.fromExecutor(NativeDatabase(file));
      addTearDown(destination.close);
      final PrivateBackup restored = await destination.privateSnapshot();
      expect(
        restored.reader.groups.map((MarkingGroup item) => item.toJson()),
        exported.reader.groups.map((MarkingGroup item) => item.toJson()),
      );
      final Marking range = restored.reader.markings.single;
      expect(range.id, 'range');
      expect(range.quote, 'A😀');
      expect((range.start, range.end), (2, 5));
      expect(range.createdAt, _created);
      expect(restored.reader.notes.single.text, 'Private canonical note');
      expect(
        restored.notebooks.single.toJson(),
        exported.notebooks.single.toJson(),
      );
      expect(
        restored.drafts.map(privateDraftToJson),
        exported.drafts.map(privateDraftToJson),
      );
      expect(
        restored.settings.map((PrivateSetting item) => item.toJson()),
        exported.settings.map((PrivateSetting item) => item.toJson()),
      );
      expect(await destination.readCache('public-test'), isNull);
      expect(await destination.readSetting('dailyScripture'), isNull);
      final PrivateImportResult repeated = await destination
          .importPrivateBackup(parsed);
      expect(repeated.notebooksAdded, 0);
      expect(repeated.draftsAdded, 0);
      expect(repeated.markingsAdded, 0);
    },
  );

  test(
    'conflicting notebook and global block IDs fork without overwriting and repeated imports survive local edits',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      await database.saveNotebook(
        _notebook(text: 'Existing local'),
        expectedRevision: null,
      );
      final Notebook incoming = _notebook(text: 'Imported different work');
      final PrivateBackup backup = _backup(
        notebooks: <Notebook>[incoming],
        drafts: <NotebookDraft>[
          NotebookDraft(
            notebook: incoming.edit(
              now: _updated,
              blocks: <NotebookBlock>[
                incoming.blocks.single.withText('Retained draft', _updated),
              ],
            ),
            baseRevision: 1,
            editorId: 'remote',
          ),
        ],
      );
      final PrivateImportResult first = await database.importPrivateBackup(
        backup,
      );
      expect(first.notebookConflicts, 1);
      expect(
        (await database.getNotebook('notebook'))!.blocks.single.text,
        'Existing local',
      );
      final Notebook imported = (await database.privateSnapshot()).notebooks
          .singleWhere((Notebook item) => item.id != 'notebook');
      expect(imported.blocks.single.id, isNot('block'));
      expect(imported.createdAt, incoming.createdAt);
      expect(
        (await database.getNotebookDrafts()).single.notebook.id,
        imported.id,
      );
      expect(
        (await database.getNotebookDrafts()).single.notebook.blocks.single.id,
        imported.blocks.single.id,
      );
      await database.saveNotebook(
        imported.edit(now: _updated, title: 'Edited locally after import'),
        expectedRevision: 1,
        editorId: 'local',
      );
      final PrivateImportResult repeated = await database.importPrivateBackup(
        backup,
      );
      expect(repeated.notebooksAdded, 0);
      expect(repeated.draftsAdded, 0);
      expect((await database.getNotebooks()).length, 2);
      expect(
        (await database.getNotebook(imported.id))!.title,
        'Edited locally after import',
      );
    },
  );

  test(
    'repeating an activated journal never recreates stale private work, while full deletion allows restore',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final Notebook saved = _notebook();
      final Notebook journal = saved.edit(
        now: _updated,
        title: 'Recovered work',
      );
      final PrivateBackup backup = _backup(
        notebooks: <Notebook>[saved],
        drafts: <NotebookDraft>[
          NotebookDraft(
            notebook: journal,
            baseRevision: 1,
            editorId: 'imported-editor',
          ),
        ],
      );
      await database.importPrivateBackup(backup);
      await database.saveNotebook(
        journal,
        expectedRevision: 1,
        editorId: 'imported-editor',
      );
      await database.saveNotebook(
        journal.edit(now: _updated, title: 'More recent local edit'),
        expectedRevision: 2,
      );
      expect((await database.importPrivateBackup(backup)).draftsAdded, 0);
      expect(await database.getNotebookDrafts(), isEmpty);
      expect(
        (await database.getNotebook('notebook'))!.title,
        'More recent local edit',
      );
      await database.deleteNotebook('notebook');
      expect((await database.importPrivateBackup(backup)).draftsAdded, 1);
      expect(
        (await database.getNotebookDrafts()).single.notebook.title,
        'Recovered work',
      );
    },
  );

  test(
    'new blocks in an imported draft cannot collide with another saved notebook',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final Notebook existing = Notebook(
        id: 'other-notebook',
        title: 'Other work',
        createdAt: _created,
        updatedAt: _created,
        revision: 1,
        blocks: <NotebookBlock>[
          NotebookBlock(
            id: 'new-block',
            text: 'Existing owner',
            createdAt: _created,
            updatedAt: _created,
          ),
        ],
      );
      await database.saveNotebook(existing, expectedRevision: null);
      final Notebook saved = _notebook();
      final Notebook incomingDraft = saved.edit(
        now: _updated,
        blocks: <NotebookBlock>[
          ...saved.blocks,
          NotebookBlock(
            id: 'new-block',
            text: 'Imported draft addition',
            createdAt: _updated,
            updatedAt: _updated,
          ),
        ],
      );
      await database.importPrivateBackup(
        _backup(
          notebooks: <Notebook>[saved],
          drafts: <NotebookDraft>[
            NotebookDraft(
              notebook: incomingDraft,
              baseRevision: 1,
              editorId: 'remote',
            ),
          ],
        ),
      );
      final NotebookDraft restored =
          (await database.getNotebookDrafts()).single;
      expect(restored.notebook.blocks.last.id, isNot('new-block'));
      await database.saveNotebook(
        restored.notebook,
        expectedRevision: restored.baseRevision,
        editorId: restored.editorId,
      );
      expect(
        (await database.getNotebook('notebook'))!.blocks.last.text,
        'Imported draft addition',
      );
      expect(
        (await database.getNotebook('other-notebook'))!.blocks.single.text,
        'Existing owner',
      );
    },
  );

  test('conflicting journal owners preserve both complete drafts', () async {
    final LocalDatabase database = await LocalDatabase.memory();
    addTearDown(database.close);
    final Notebook saved = _notebook();
    await database.saveNotebook(saved, expectedRevision: null);
    await database.saveNotebookDraft(
      saved.edit(now: _updated, title: 'Local journal'),
      expectedRevision: 1,
      editorId: 'editor',
    );
    final PrivateBackup incoming = _backup(
      notebooks: <Notebook>[saved],
      drafts: <NotebookDraft>[
        NotebookDraft(
          notebook: saved.edit(now: _updated, title: 'Remote journal'),
          baseRevision: 1,
          editorId: 'editor',
        ),
      ],
    );
    await database.importPrivateBackup(incoming);
    final List<NotebookDraft> drafts = await database.getNotebookDrafts();
    expect(
      drafts.map((NotebookDraft item) => item.notebook.title),
      unorderedEquals(<String>['Local journal', 'Remote journal']),
    );
    expect(drafts.map((NotebookDraft item) => item.editorId).toSet().length, 2);
    expect((await database.getNotebook(saved.id))!.title, saved.title);
    await database.importPrivateBackup(incoming);
    expect((await database.getNotebookDrafts()).length, 2);
  });

  test(
    'group collisions remap active preference and topic copy while retaining local copy provenance',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      await database.saveGroup(_group('Local group'));
      final String key =
          'topic-copy:v1:${Uri.encodeComponent('https://bookmarks.getbible.net/v1/|faith')}';
      await database.writeSetting(key, <String, Object?>{
        'version': 1,
        'groupId': 'group',
      });
      final PrivateBackup incoming = _backup(
        groups: <MarkingGroup>[_group('Incoming group')],
        settings: <PrivateSetting>[
          PrivateSetting(
            key: 'readerPreferences',
            value: const ReaderPreferences(
              activeMarkingGroupId: 'group',
            ).toJson(),
            updatedAt: _updated,
          ),
          PrivateSetting(
            key: key,
            value: <String, Object?>{'version': 1, 'groupId': 'group'},
            updatedAt: _updated,
          ),
        ],
      );
      await database.importPrivateBackup(incoming);
      final PrivateBackup result = await database.privateSnapshot();
      expect(
        result.reader.preferences!.activeMarkingGroupId,
        'group-imported-1',
      );
      expect(
        (jsonDecode((await database.readSetting(key))!)
            as Map<String, Object?>)['groupId'],
        'group',
      );
      final PrivateSetting alternate = result.settings.singleWhere(
        (PrivateSetting item) => item.key.startsWith('topic-copy-alternate:'),
      );
      expect((alternate.value! as Map)['groupId'], 'group-imported-1');
      expect(
        decodePrivateBackup(
          encodePrivateBackup(result),
        ).settings.any((PrivateSetting item) => item.key == alternate.key),
        isTrue,
      );
    },
  );

  test(
    'alternate copy provenance collisions preserve the canonical topic scope',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      const String alternate = 'topic-copy-alternate:v1:fixture';
      final String canonical =
          'topic-copy:v1:${Uri.encodeComponent('https://bookmarks.getbible.net/v1/|faith')}';
      await database.saveGroup(_group('Local group'));
      await database.writeSetting(alternate, <String, Object?>{
        'version': 1,
        'groupId': 'group',
        'provenanceKey': canonical,
      });
      final PrivateBackup incoming = _backup(
        groups: <MarkingGroup>[_group('Other group')],
        settings: <PrivateSetting>[
          PrivateSetting(
            key: alternate,
            value: <String, Object?>{
              'version': 1,
              'groupId': 'group',
              'provenanceKey': canonical,
            },
            updatedAt: _updated,
          ),
        ],
      );
      await database.importPrivateBackup(incoming);
      final List<PrivateSetting> copies = (await database.privateSnapshot())
          .settings
          .where((PrivateSetting item) => item.isTopicCopy)
          .toList();
      expect(copies.length, 2);
      expect(
        copies
            .map((PrivateSetting item) => (item.value! as Map)['provenanceKey'])
            .toSet(),
        <String>{canonical},
      );
      expect(
        copies
            .map((PrivateSetting item) => (item.value! as Map)['groupId'])
            .toSet(),
        <String>{'group', 'group-imported-1'},
      );
      await database.importPrivateBackup(incoming);
      expect(
        (await database.privateSnapshot()).settings
            .where((PrivateSetting item) => item.isTopicCopy)
            .length,
        2,
      );
    },
  );

  test(
    'complete files reject invalid note coordinates and inverted timestamps',
    () {
      for (final Map<String, Object?> invalid in <Map<String, Object?>>[
        <String, Object?>{'verse': 0},
        <String, Object?>{'updatedAt': 0},
      ]) {
        final Map<String, Object?> json = _backup().toJson();
        final Map<String, Object?> reader =
            json['reader']! as Map<String, Object?>;
        reader['notes'] = <Object?>[
          <String, Object?>{
            'id': 'invalid',
            'passage': const Passage(
              translation: 'fx',
              book: 1,
              chapter: 1,
            ).toJson(),
            'verse': 1,
            'reference': 'Genesis 1:1',
            'text': 'Keep local work',
            'createdAt': _created.millisecondsSinceEpoch,
            'updatedAt': _updated.millisecondsSinceEpoch,
            ...invalid,
          },
        ];
        expect(
          () => decodePrivateBackup(jsonEncode(json)),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'snapshot rejects excessive stored record counts before loading document bodies',
    () async {
      final NativeDatabase executor = NativeDatabase.memory();
      final LocalDatabase database = await LocalDatabase.fromExecutor(executor);
      addTearDown(database.close);
      await executor.runCustom(
        "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 100001) INSERT INTO notes(id, canonical_key, translation, book_nr, chapter_nr, verse_nr, reference, text, created_at, updated_at) SELECT 'n-'||x, '1/1/'||x, 'fx', 1, 1, x, 'Reference', 'Saved private work', 0, 0 FROM n",
      );
      await expectLater(database.privateSnapshot(), throwsException);
      expect(
        (await executor.runSelect(
          'SELECT COUNT(*) AS count FROM notes',
          <Object?>[],
        )).single['count'],
        100001,
      );
    },
  );

  test(
    'invalid complete files reject before mutation and preserve existing data',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      await _seed(database);
      final String before = encodePrivateBackup(
        await database.privateSnapshot(),
      );
      final Map<String, Object?> json = _backup().toJson();
      json['settings'] = <Object?>[
        <String, Object?>{
          'key': 'offline:malicious',
          'value': true,
          'updatedAt': 0,
        },
      ];
      expect(() => PrivateBackup.fromJson(json), throwsFormatException);
      json['version'] = 2;
      expect(() => PrivateBackup.fromJson(json), throwsFormatException);
      final Map<String, Object?> unchanged =
          jsonDecode(encodePrivateBackup(await database.privateSnapshot()))
              as Map<String, Object?>;
      final Map<String, Object?> original =
          jsonDecode(before) as Map<String, Object?>;
      (unchanged['reader']! as Map)['exportedAt'] =
          (original['reader']! as Map)['exportedAt'];
      expect(unchanged, original);
    },
  );

  test(
    'a late storage failure rolls back reader merge, documents and import aliases together',
    () async {
      final NativeDatabase executor = NativeDatabase.memory();
      final LocalDatabase database = await LocalDatabase.fromExecutor(executor);
      addTearDown(database.close);
      await database.saveGroup(_group('Original'));
      await executor.runCustom(
        "CREATE TRIGGER reject_private_import BEFORE INSERT ON notebook_blocks WHEN NEW.text = 'Reject this write' BEGIN SELECT RAISE(ABORT, 'injected storage failure'); END",
      );
      final PrivateBackup incoming = _backup(
        groups: <MarkingGroup>[_group('Incoming')],
        notebooks: <Notebook>[_notebook(text: 'Reject this write')],
      );
      await expectLater(
        database.importPrivateBackup(incoming),
        throwsException,
      );
      expect(
        (await database.getGroups()).where(
          (MarkingGroup item) => item.name == 'Incoming',
        ),
        isEmpty,
      );
      expect(
        (await database.getGroups())
            .singleWhere((MarkingGroup item) => item.id == 'group')
            .name,
        'Original',
      );
      expect(await database.getNotebooks(), isEmpty);
      expect(
        await database.readSetting('portability:v1:import-aliases'),
        isNull,
      );
    },
  );

  test(
    'legacy v1/v2 merge remains readable and web export stays v2 without notebooks',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      await database.saveNotebook(_notebook(), expectedRevision: null);
      final Map<String, Object?> legacy = _backup(
        groups: <MarkingGroup>[_group('Legacy')],
      ).reader.toJson();
      legacy['version'] = 1;
      final PrivateBackup parsed = decodePrivateBackup(jsonEncode(legacy));
      expect(parsed.isLegacy, isTrue);
      await database.importPrivateBackup(parsed);
      expect((await database.getNotebooks()).single.id, 'notebook');
      final Map<String, Object?> website = (await database.privateSnapshot())
          .reader
          .toJson();
      expect(website['version'], 2);
      expect(website.containsKey('notebooks'), isFalse);
      expect(
        BackupData.fromJson(
          website,
        ).groups.any((MarkingGroup group) => group.name == 'Legacy'),
        isTrue,
      );
    },
  );

  test(
    'controller validates preview without writes and flushes before confirmed atomic merge',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      int flushed = 0;
      int refreshed = 0;
      final PortabilityController controller = PortabilityController(
        repository: SqlPrivateDataRepository(database),
        beforeSnapshot: () async {
          flushed++;
        },
        afterImport: () async {
          refreshed++;
        },
      );
      addTearDown(controller.dispose);
      await controller.prepareImport(
        encodePrivateBackup(_backup(notebooks: <Notebook>[_notebook()])),
      );
      expect(controller.preparedImport!.notebooks.length, 1);
      expect(await database.getNotebooks(), isEmpty);
      expect(flushed, 0);
      await controller.confirmImport();
      expect(controller.importResult!.notebooksAdded, 1);
      expect(flushed, 1);
      expect(refreshed, 1);
      expect(controller.preparedImport, isNull);
      await controller.prepareImport('{broken');
      expect(controller.error, isNotNull);
      expect((await database.getNotebooks()).length, 1);
    },
  );

  test(
    'notebook refresh discovers imported work without dropping a conflicted open draft',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      final NotebookController controller = NotebookController(
        SqlNotebookRepository(database),
        autosaveDelay: const Duration(hours: 1),
      );
      addTearDown(() async {
        await controller.flush();
        controller.dispose();
        await database.close();
      });
      final Notebook original = _notebook();
      await database.saveNotebook(original, expectedRevision: null);
      await controller.load();
      controller.updateTitle('My conflicted draft');
      await database.saveNotebook(
        original.edit(now: _updated, title: 'Another local editor'),
        expectedRevision: 1,
        editorId: 'other',
      );
      expect(await controller.flush(), isFalse);
      expect(controller.hasUndurableDrafts, isFalse);
      await database.importPrivateBackup(
        _backup(notebooks: <Notebook>[_notebook(text: 'Imported work')]),
      );
      await controller.reloadAfterImport();
      expect(controller.notebook!.title, 'My conflicted draft');
      expect(controller.hasConflict, isTrue);
      expect(controller.notebooks.length, 2);
      expect(
        (await database.getNotebookDrafts()).single.notebook.title,
        'My conflicted draft',
      );
      expect(
        (await database.getNotebook('notebook'))!.title,
        'Another local editor',
      );
    },
  );

  test(
    'controller shutdown waits for active snapshot and can resume after another shutdown gate fails',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final Completer<PrivateBackup> pending = Completer<PrivateBackup>();
      final PortabilityController controller = PortabilityController(
        repository: _PausedRepository(
          SqlPrivateDataRepository(database),
          pending.future,
        ),
      );
      addTearDown(controller.dispose);
      final Future<String?> export = controller.exportComplete();
      bool closed = false;
      final Future<void> closing = controller.close().then((_) {
        closed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      pending.complete(await database.privateSnapshot());
      expect(await export, isNotNull);
      await closing;
      expect(closed, isTrue);
      expect(await controller.exportComplete(), isNull);
      controller.resume();
      expect(await controller.exportComplete(), isNotNull);
    },
  );
}

final class _PausedRepository implements PrivateDataRepository {
  const _PausedRepository(this.delegate, this.pending);
  final PrivateDataRepository delegate;
  final Future<PrivateBackup> pending;
  @override
  Future<PrivateBackup> snapshot() => pending;
  @override
  Future<PrivateImportResult> importBackup(PrivateBackup backup) =>
      delegate.importBackup(backup);
}

PrivateBackup _backup({
  List<MarkingGroup> groups = const <MarkingGroup>[],
  List<Notebook> notebooks = const <Notebook>[],
  List<NotebookDraft> drafts = const <NotebookDraft>[],
  List<PrivateSetting> settings = const <PrivateSetting>[],
}) => PrivateBackup(
  reader: BackupData(
    version: 2,
    exportedAt: _updated,
    groups: groups,
    markings: const <Marking>[],
    notes: const <VerseNote>[],
  ),
  notebooks: notebooks,
  drafts: drafts,
  settings: settings,
);
MarkingGroup _group(String name) => MarkingGroup(
  id: 'group',
  name: name,
  color: '#336699',
  sortOrder: 0,
  updatedAt: _created,
);
Notebook _notebook({String text = 'My private study'}) => Notebook(
  id: 'notebook',
  title: 'Sermon',
  createdAt: _created,
  updatedAt: _created,
  revision: 1,
  blocks: <NotebookBlock>[
    NotebookBlock(
      id: 'block',
      text: text,
      createdAt: _created,
      updatedAt: _created,
      reference: NotebookReference(
        passage: const Passage(
          translation: 'fx',
          book: 900000123,
          chapter: 3,
          verse: 7,
        ),
        label: 'Extended 3:7',
        quotation: '  Exact 😃 quotation\n',
        direction: 'RTL',
      ),
    ),
  ],
);
Future<void> _seed(LocalDatabase database) async {
  await database.saveGroup(_group('My group'));
  await database.saveMarking(
    Marking(
      id: 'range',
      passage: const Passage(translation: 'fx', book: 900000123, chapter: 3),
      verse: 7,
      start: 2,
      end: 5,
      quote: 'A😀',
      reference: 'Extended 3:7',
      groupId: 'group',
      createdAt: _created,
    ),
  );
  await database.saveNote(
    VerseNote(
      id: 'note',
      passage: const Passage(translation: 'fx', book: 900000123, chapter: 3),
      verse: 7,
      reference: 'Extended 3:7',
      text: 'Private canonical note',
      createdAt: _created,
      updatedAt: _updated,
    ),
  );
  final Notebook notebook = _notebook();
  await database.saveNotebook(notebook, expectedRevision: null);
  await database.saveNotebookDraft(
    notebook.edit(now: _updated, title: 'Draft one'),
    expectedRevision: 1,
    editorId: 'one',
  );
  await database.saveNotebookDraft(
    notebook.edit(now: _updated, title: 'Draft two'),
    expectedRevision: 1,
    editorId: 'two',
  );
  await database.writeSetting(
    'readerPreferences',
    const ReaderPreferences(activeMarkingGroupId: 'group').toJson(),
  );
  await database.writeSetting(
    'lastReadingPosition',
    LastReadingPosition(
      passage: const Passage(translation: 'fx', book: 900000123, chapter: 3),
      verse: 7,
      updatedAt: _updated,
    ).toJson(),
  );
  await database.selectNotebook('notebook');
  await database.writeSetting(
    'study:v1:topic-followed:${Uri.encodeComponent('https://bookmarks.getbible.net/v1/|faith')}',
    true,
  );
  await database.writeSetting(
    'topic-copy:v1:${Uri.encodeComponent('https://bookmarks.getbible.net/v1/|faith')}',
    <String, Object?>{'version': 1, 'groupId': 'group'},
  );
  await database.writeSetting('dailyScripture', <String, Object?>{
    'public': true,
  });
  await database.writeCache(
    key: 'public-test',
    kind: 'public',
    sha: '',
    payload: <String, Object?>{'not': 'private'},
    checkedAt: _updated,
  );
}
