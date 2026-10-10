part of 'local_database.dart';

/// Complete exports and imports use one SQLite transaction. They never include
/// or clear public caches/installations, and never activate a retained draft.
extension PrivateDataStore on LocalDatabase {
  Future<PrivateBackup> privateSnapshot() => _transaction(_readPrivateSnapshot);

  Future<PrivateImportResult> importPrivateBackup(PrivateBackup backup) async {
    // Reparse to validate programmatically constructed/mutable nested values as
    // well as external JSON before entering a write transaction.
    final PrivateBackup imported = PrivateBackup.fromJson(
      backup.isLegacy ? backup.reader.toJson() : backup.toJson(),
    );
    return _transaction((QueryExecutor transaction) async {
      final PrivateBackup current = await _readPrivateSnapshot(transaction);
      final ReaderBackupMerge readerMerge =
          !imported.isLegacy &&
              imported.reader.groups.isNotEmpty &&
              _hasOnlyUntouchedStarterGroups(current)
          ? ReaderBackupMerge(imported.reader, <String, String>{
              for (final MarkingGroup item in imported.reader.groups)
                item.id: item.id,
            })
          : mergeReaderBackup(current.reader, imported.reader);
      final BackupData reader = readerMerge.data;
      final Map<String, Notebook> notebooks = <String, Notebook>{
        for (final Notebook item in current.notebooks) item.id: item,
      };
      final Set<String> previouslySavedNotebooks = notebooks.keys.toSet();
      final Set<String> blockIds = current.notebooks
          .expand(
            (Notebook item) =>
                item.blocks.map((NotebookBlock block) => block.id),
          )
          .toSet();
      final Map<String, String> notebookIds = <String, String>{};
      final Map<String, String> aliases = await _readPrivateImportAliases(
        transaction,
      );
      final List<Notebook> addedNotebooks = <Notebook>[];
      int conflicts = 0;
      for (final Notebook source in imported.notebooks) {
        final String identity = _privateDigest(<String, Object?>{
          'kind': 'notebook',
          'source': source.toJson(),
        });
        final String? remembered = aliases[identity];
        if (remembered != null && notebooks.containsKey(remembered)) {
          notebookIds[source.id] = remembered;
          continue;
        }
        final Notebook? existing = notebooks[source.id];
        if (existing != null &&
            _samePrivateJson(existing.toJson(), source.toJson())) {
          notebookIds[source.id] = existing.id;
          aliases[identity] = existing.id;
          continue;
        }
        final bool collision = existing != null;
        final String id = collision
            ? _allocatePrivateId(source.id, identity, notebooks.keys.toSet())
            : source.id;
        if (collision) conflicts++;
        final Notebook next = _remapPrivateNotebook(source, id, blockIds);
        notebooks[id] = next;
        notebookIds[source.id] = id;
        aliases[identity] = id;
        addedNotebooks.add(next);
      }

      final Map<String, NotebookDraft> drafts = <String, NotebookDraft>{
        for (final NotebookDraft item in current.drafts)
          '${item.notebook.id}/${item.editorId}': item,
      };
      final List<NotebookDraft> addedDrafts = <NotebookDraft>[];
      final Map<String, String> draftBlockRemaps = <String, String>{};
      for (final NotebookDraft source in imported.drafts) {
        final String identity = _privateDigest(<String, Object?>{
          'kind': 'draft',
          'source': privateDraftToJson(source),
        });
        final String? remembered = aliases[identity];
        if (remembered != null) {
          final String rememberedNotebook = remembered.split('/').first;
          if (drafts.containsKey(remembered) ||
              previouslySavedNotebooks.contains(rememberedNotebook)) {
            // A successfully recovered/discarded journal is not new work when
            // the same file is imported again. Keep its receipt while its
            // destination document exists; deleting that document allows restore.
            notebookIds.putIfAbsent(
              source.notebook.id,
              () => rememberedNotebook,
            );
            continue;
          }
        }
        final String id = notebookIds[source.notebook.id] ?? source.notebook.id;
        // Draft block identities are intentionally independent of saved blocks.
        // They are remapped consistently to the imported saved notebook when it
        // exists, but journals never overwrite the active document here.
        final Notebook? savedSource = imported.notebooks
            .where((Notebook item) => item.id == source.notebook.id)
            .firstOrNull;
        final Notebook? savedTarget = notebooks[id];
        final Map<String, String> remappedBlocks = <String, String>{};
        if (savedSource != null && savedTarget != null) {
          for (
            int index = 0;
            index < savedSource.blocks.length &&
                index < savedTarget.blocks.length;
            index++
          ) {
            // An alias may point to a locally edited document. Match a stable
            // source block ID, or its deterministic imported identity, not rank.
            final NotebookBlock block = savedSource.blocks[index];
            final String blockDigest = _privateDigest(<String, Object?>{
              'notebook': id,
              'block': block.id,
            });
            final String expected = _privateIdCandidate(
              block.id,
              blockDigest,
              0,
            );
            final NotebookBlock? target = savedTarget.blocks
                .where(
                  (NotebookBlock item) =>
                      item.id == block.id || item.id == expected,
                )
                .firstOrNull;
            if (target != null) remappedBlocks[block.id] = target.id;
          }
        }
        final Notebook remapped = _copyPrivateNotebook(
          source.notebook,
          id,
          source.notebook.blocks.map(
            (NotebookBlock block) =>
                _copyPrivateBlock(block, remappedBlocks[block.id] ?? block.id),
          ),
        );
        // A draft-only backup cannot prove that a same-ID local document is
        // its base. Fork its identity so it can only enter explicit recovery.
        final bool orphanCollision = savedSource == null && savedTarget != null;
        final String draftId = orphanCollision
            ? _allocatePrivateId(id, identity, <String>{
                ...notebooks.keys,
                ...drafts.values.map((NotebookDraft item) => item.notebook.id),
              })
            : id;
        final Set<String> targetBlockIds =
            savedTarget?.blocks
                .map((NotebookBlock block) => block.id)
                .toSet() ??
            <String>{};
        final Set<String> reservedBlocks = <String>{
          ...blockIds,
          ...remapped.blocks.map((NotebookBlock block) => block.id),
        };
        final Notebook draftNotebook = _copyPrivateNotebook(
          remapped,
          draftId,
          remapped.blocks.map((NotebookBlock block) {
            final String key = '$draftId/${block.id}';
            final String? previous = draftBlockRemaps[key];
            if (previous != null) return _copyPrivateBlock(block, previous);
            String id = block.id;
            if (blockIds.contains(id) && !targetBlockIds.contains(id)) {
              final String fingerprint = _privateDigest(<String, Object?>{
                'notebook': draftId,
                'block': block.id,
              });
              final String expected = _privateIdCandidate(
                block.id,
                fingerprint,
                0,
              );
              id = targetBlockIds.contains(expected)
                  ? expected
                  : _allocatePrivateId(block.id, fingerprint, reservedBlocks);
            }
            draftBlockRemaps[key] = id;
            reservedBlocks.add(id);
            blockIds.add(id);
            return _copyPrivateBlock(block, id);
          }),
        );
        String owner = source.editorId;
        String key = '$draftId/$owner';
        final NotebookDraft candidate = NotebookDraft(
          notebook: draftNotebook,
          baseRevision: source.baseRevision,
          editorId: owner,
        );
        final NotebookDraft? existing = drafts[key];
        if (existing != null &&
            _samePrivateJson(
              privateDraftToJson(existing),
              privateDraftToJson(candidate),
            )) {
          aliases[identity] = key;
          continue;
        }
        if (existing != null) {
          owner = _allocatePrivateId(
            owner,
            identity,
            drafts.values
                .where((NotebookDraft item) => item.notebook.id == draftId)
                .map((NotebookDraft item) => item.editorId)
                .toSet(),
          );
          key = '$draftId/$owner';
        }
        final NotebookDraft next = NotebookDraft(
          notebook: draftNotebook,
          baseRevision: source.baseRevision,
          editorId: owner,
        );
        drafts[key] = next;
        aliases[identity] = key;
        addedDrafts.add(next);
        notebookIds.putIfAbsent(source.notebook.id, () => draftId);
      }

      final Map<String, PrivateSetting> settings = <String, PrivateSetting>{
        for (final PrivateSetting item in current.settings) item.key: item,
      };
      int restoredSettings = 0;
      for (final PrivateSetting source in imported.settings) {
        Object? value = source.value;
        if (source.key == 'readerPreferences') {
          final ReaderPreferences preference = ReaderPreferences.fromJson(
            value,
          );
          value = preference
              .copyWith(
                activeMarkingGroupId:
                    readerMerge.importedGroupIds[preference
                        .activeMarkingGroupId] ??
                    preference.activeMarkingGroupId,
              )
              .toJson();
        } else if (source.key == 'bookmarks:v1:recent') {
          value = (value! as List)
              .cast<String>()
              .map((id) => readerMerge.importedGroupIds[id] ?? id)
              .toSet()
              .take(6)
              .toList();
        } else if (source.key == 'notebooks:v1:selected') {
          value = notebookIds[value] ?? value;
        } else if (source.isTopicCopy) {
          final JsonMap provenance = requireJsonMap(value, 'topic copy');
          value = <String, Object?>{
            ...provenance,
            'groupId':
                readerMerge.importedGroupIds[provenance['groupId']] ??
                provenance['groupId'],
          };
        }
        final PrivateSetting next = PrivateSetting(
          key: source.key,
          value: value,
          updatedAt: source.updatedAt,
        );
        final PrivateSetting? previous = settings[source.key];
        if (source.isTopicCopy &&
            previous != null &&
            !_samePrivateJson(previous.value, value)) {
          // Both independent private groups survive. One service/topic can have
          // one active copy destination; retain the current local destination
          // and preserve the imported provenance as an explicit alternate.
          final JsonMap provenance = requireJsonMap(value, 'topic copy');
          final String provenanceKey =
              source.key.startsWith('topic-copy-alternate:')
              ? requireString(provenance, 'provenanceKey')
              : source.key;
          final String alternateKey =
              'topic-copy-alternate:v1:${_privateDigest(<String, Object?>{'key': provenanceKey, 'value': value})}';
          settings[alternateKey] = PrivateSetting(
            key: alternateKey,
            value: <String, Object?>{
              ...provenance,
              'provenanceKey': provenanceKey,
            },
            updatedAt: source.updatedAt,
          );
          restoredSettings++;
        } else if (previous == null ||
            source.updatedAt.isAfter(previous.updatedAt)) {
          settings[source.key] = next;
          restoredSettings++;
        }
      }
      if (imported.isLegacy && imported.reader.preferences != null) {
        settings['readerPreferences'] = PrivateSetting(
          key: 'readerPreferences',
          value: reader.preferences!.toJson(),
          updatedAt: DateTime.now().toUtc(),
        );
        restoredSettings++;
      }

      // Build and validate the whole merged snapshot before the first mutation.
      PrivateBackup(
        reader: reader,
        notebooks: notebooks.values,
        drafts: drafts.values,
        settings: settings.values,
      );
      await transaction.runCustom('DELETE FROM markings');
      await transaction.runCustom('DELETE FROM notes');
      await transaction.runCustom('DELETE FROM marking_groups');
      for (final MarkingGroup item in reader.groups) {
        await _saveGroup(transaction, item);
      }
      for (final Marking item in reader.markings) {
        await _saveMarking(transaction, item);
      }
      for (final VerseNote item in reader.notes) {
        await _saveNote(transaction, item);
      }
      for (final Notebook notebook in addedNotebooks) {
        await _insertPrivateNotebook(transaction, notebook);
      }
      for (final NotebookDraft draft in addedDrafts) {
        await transaction.runCustom(
          'INSERT INTO notebook_drafts(id, editor_id, revision, payload, updated_at, base_revision) VALUES(?, ?, ?, ?, ?, ?)',
          <Object?>[
            draft.notebook.id,
            draft.editorId,
            draft.notebook.revision,
            jsonEncode(draft.notebook.toJson()),
            draft.notebook.updatedAt.millisecondsSinceEpoch,
            draft.baseRevision,
          ],
        );
      }
      for (final PrivateSetting setting in settings.values) {
        await transaction.runCustom(
          'INSERT INTO settings(setting_key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(setting_key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at',
          <Object?>[
            setting.key,
            jsonEncode(setting.value),
            setting.updatedAt.millisecondsSinceEpoch,
          ],
        );
      }
      await transaction.runCustom(
        'INSERT INTO settings(setting_key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(setting_key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at',
        <Object?>[
          'portability:v1:import-aliases',
          jsonEncode(aliases),
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
      final Map<String, VerseNote> originalNotes = <String, VerseNote>{
        for (final VerseNote item in current.reader.notes)
          item.canonicalKey: item,
      };
      return PrivateImportResult(
        groupsAdded: reader.groups
            .where(
              (MarkingGroup item) => !current.reader.groups.any(
                (MarkingGroup old) => old.id == item.id,
              ),
            )
            .length,
        markingsAdded: reader.markings.length - current.reader.markings.length,
        notesChanged: reader.notes
            .where(
              (VerseNote item) =>
                  originalNotes[item.canonicalKey] == null ||
                  !_samePrivateJson(
                    originalNotes[item.canonicalKey]!.toJson(),
                    item.toJson(),
                  ),
            )
            .length,
        notebooksAdded: addedNotebooks.length,
        draftsAdded: addedDrafts.length,
        notebookConflicts: conflicts,
        settingsRestored: restoredSettings,
      );
    });
  }
}

bool _hasOnlyUntouchedStarterGroups(PrivateBackup snapshot) {
  if (snapshot.reader.markings.isNotEmpty ||
      snapshot.reader.notes.isNotEmpty ||
      snapshot.notebooks.isNotEmpty ||
      snapshot.drafts.isNotEmpty) {
    return false;
  }
  final Map<String, MarkingGroup> defaults = <String, MarkingGroup>{
    for (final MarkingGroup item in starterMarkingGroups()) item.id: item,
  };
  return snapshot.reader.groups.length == defaults.length &&
      snapshot.reader.groups.every(
        (MarkingGroup item) =>
            defaults[item.id] != null &&
            _samePrivateJson(item.toJson(), defaults[item.id]!.toJson()),
      );
}

Future<PrivateBackup> _readPrivateSnapshot(QueryExecutor transaction) async {
  await _checkPrivateSnapshotBounds(transaction);
  final List<MarkingGroup> groups = (await transaction.runSelect(
    'SELECT * FROM marking_groups ORDER BY sort_order, id',
    const <Object?>[],
  )).map(_groupFromRow).toList();
  final List<Marking> markings = (await transaction.runSelect(
    'SELECT * FROM markings ORDER BY id',
    const <Object?>[],
  )).map(_markingFromRow).toList();
  final List<VerseNote> notes = (await transaction.runSelect(
    'SELECT * FROM notes ORDER BY canonical_key',
    const <Object?>[],
  )).map(_noteFromRow).toList();
  final List<Map<String, Object?>> notebookRows = await transaction.runSelect(
    'SELECT * FROM notebooks ORDER BY id',
    const <Object?>[],
  );
  final List<Map<String, Object?>> blockRows = await transaction.runSelect(
    'SELECT * FROM notebook_blocks ORDER BY notebook_id, rank',
    const <Object?>[],
  );
  final Map<String, List<NotebookBlock>> blocks =
      <String, List<NotebookBlock>>{};
  for (final Map<String, Object?> row in blockRows) {
    blocks
        .putIfAbsent(row['notebook_id']! as String, () => <NotebookBlock>[])
        .add(
          NotebookBlock(
            id: row['id']! as String,
            text: row['text']! as String,
            createdAt: _storedTime(row['created_at']),
            updatedAt: _storedTime(row['updated_at']),
            reference: row['reference_json'] == null
                ? null
                : NotebookReference.fromJson(
                    jsonDecode(row['reference_json']! as String),
                  ),
          ),
        );
  }
  final List<Notebook> notebooks = notebookRows
      .map(
        (Map<String, Object?> row) => Notebook(
          id: row['id']! as String,
          title: row['title']! as String,
          createdAt: _storedTime(row['created_at']),
          updatedAt: _storedTime(row['updated_at']),
          revision: row['revision']! as int,
          blocks: blocks[row['id']] ?? const <NotebookBlock>[],
        ),
      )
      .toList();
  final List<NotebookDraft> drafts =
      (await transaction.runSelect(
            'SELECT * FROM notebook_drafts ORDER BY id, editor_id',
            const <Object?>[],
          ))
          .map(
            (Map<String, Object?> row) => NotebookDraft(
              notebook: Notebook.fromJson(
                jsonDecode(row['payload']! as String),
              ),
              baseRevision: row['base_revision'] as int?,
              editorId: row['editor_id']! as String,
            ),
          )
          .toList();
  final Set<String> groupIds = groups
      .map((MarkingGroup item) => item.id)
      .toSet();
  final Set<String> notebookIds = <String>{
    ...notebooks.map((Notebook item) => item.id),
    ...drafts.map((NotebookDraft item) => item.notebook.id),
  };
  final List<PrivateSetting> settings = <PrivateSetting>[];
  for (final Map<String, Object?> row in await transaction.runSelect(
    'SELECT * FROM settings WHERE $_portableSettingPredicate ORDER BY setting_key',
    const <Object?>[],
  )) {
    final String key = row['setting_key']! as String;
    if (!PrivateSetting.isPortableKey(key)) continue;
    final PrivateSetting setting = PrivateSetting(
      key: key,
      value: jsonDecode(row['value']! as String),
      updatedAt: _storedTime(row['updated_at']),
    );
    // Deleting a private group deliberately leaves its historical provenance;
    // it is not an extant copy and must not create a dangling backup reference.
    if (setting.isTopicCopy &&
        !groupIds.contains(
          requireJsonMap(setting.value, 'topic copy')['groupId'],
        )) {
      continue;
    }
    if (key == 'notebooks:v1:selected' &&
        !notebookIds.contains(setting.value)) {
      continue;
    }
    settings.add(setting);
  }
  final PrivateSetting? preferences = settings
      .where((PrivateSetting item) => item.key == 'readerPreferences')
      .firstOrNull;
  return PrivateBackup(
    reader: BackupData(
      version: 2,
      exportedAt: DateTime.now().toUtc(),
      groups: groups,
      markings: markings,
      notes: notes,
      preferences: preferences == null
          ? null
          : ReaderPreferences.fromJson(preferences.value),
    ),
    notebooks: notebooks,
    drafts: drafts,
    settings: settings,
  );
}

const String _portableSettingPredicate =
    "setting_key IN ('readerPreferences', 'lastReadingPosition', 'notebooks:v1:selected', 'bookmarks:v1:recent') "
    "OR substr(setting_key, 1, 20) = 'study:v1:dictionary:' "
    "OR substr(setting_key, 1, 20) = 'study:v1:commentary:' "
    "OR substr(setting_key, 1, 24) = 'study:v1:topic-followed:' "
    "OR substr(setting_key, 1, 22) = 'study:v1:topic-hidden:' "
    "OR substr(setting_key, 1, 14) = 'topic-copy:v1:' "
    "OR substr(setting_key, 1, 24) = 'topic-copy-alternate:v1:'";

/// Bound the on-device source before materializing its potentially large text
/// fields. The final JSON encoder enforces the exact 64 MiB serialized bound.
Future<void> _checkPrivateSnapshotBounds(QueryExecutor executor) async {
  const Map<String, List<String>> fields = <String, List<String>>{
    'marking_groups': <String>['id', 'name', 'color', 'source_json'],
    'markings': <String>[
      'id',
      'translation',
      'quote',
      'reference',
      'group_id',
      'source_json',
    ],
    'notes': <String>[
      'id',
      'canonical_key',
      'translation',
      'reference',
      'text',
    ],
    'notebooks': <String>['id', 'title'],
    'notebook_blocks': <String>['id', 'notebook_id', 'text', 'reference_json'],
    'notebook_drafts': <String>['id', 'editor_id', 'payload'],
    'settings': <String>['setting_key', 'value'],
  };
  final String scans = fields.entries
      .map((MapEntry<String, List<String>> table) {
        final String bytes = table.value
            .map(
              (String column) => 'COALESCE(length(CAST($column AS BLOB)), 0)',
            )
            .join(' + ');
        final String where = table.key == 'settings'
            ? ' WHERE $_portableSettingPredicate'
            : '';
        return 'SELECT COUNT(*) AS records, COALESCE(SUM($bytes), 0) AS bytes FROM ${table.key}$where';
      })
      .join(' UNION ALL ');
  final Map<String, Object?> sizes = (await executor.runSelect(
    'SELECT SUM(records) AS records, SUM(bytes) AS bytes FROM ($scans)',
    const <Object?>[],
  )).single;
  if ((sizes['records']! as int) > maxPrivateBackupRecords ||
      (sizes['bytes']! as int) > maxPrivateBackupBytes) {
    throw const FormatException(
      'The private data exceeds the complete backup limit of 64 MiB or 100,000 records. No data was changed.',
    );
  }
}

Future<Map<String, String>> _readPrivateImportAliases(
  QueryExecutor executor,
) async {
  final List<Map<String, Object?>> rows = await executor.runSelect(
    'SELECT value FROM settings WHERE setting_key = ?',
    <Object?>['portability:v1:import-aliases'],
  );
  if (rows.isEmpty) return <String, String>{};
  final JsonMap json = requireJsonMap(
    jsonDecode(rows.single['value']! as String),
    'private import identities',
  );
  return json.map(
    (String key, Object? value) => MapEntry(key, value! as String),
  );
}

String _privateDigest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
bool _samePrivateJson(Object? left, Object? right) =>
    jsonEncode(left) == jsonEncode(right);
String _privateIdCandidate(String source, String fingerprint, int suffix) =>
    '${source.substring(0, source.length > 48 ? 48 : source.length)}-imported-${fingerprint.substring(0, 32)}${suffix == 0 ? '' : '-$suffix'}';
String _allocatePrivateId(
  String source,
  String fingerprint,
  Set<String> occupied,
) {
  for (int index = 0; index < maxPrivateBackupRecords; index++) {
    final String candidate = _privateIdCandidate(source, fingerprint, index);
    if (!occupied.contains(candidate)) return candidate;
  }
  throw const FormatException('Unable to allocate a private import identity.');
}

NotebookBlock _copyPrivateBlock(NotebookBlock block, String id) =>
    NotebookBlock(
      id: id,
      text: block.text,
      createdAt: block.createdAt,
      updatedAt: block.updatedAt,
      reference: block.reference,
    );
Notebook _copyPrivateNotebook(
  Notebook source,
  String id,
  Iterable<NotebookBlock> blocks,
) => Notebook(
  id: id,
  title: source.title,
  createdAt: source.createdAt,
  updatedAt: source.updatedAt,
  revision: source.revision,
  blocks: blocks,
);
Notebook _remapPrivateNotebook(
  Notebook source,
  String id,
  Set<String> occupiedBlocks,
) => _copyPrivateNotebook(
  source,
  id,
  source.blocks.map((NotebookBlock block) {
    final String next = occupiedBlocks.contains(block.id)
        ? _allocatePrivateId(
            block.id,
            _privateDigest(<String, Object?>{
              'notebook': id,
              'block': block.id,
            }),
            occupiedBlocks,
          )
        : block.id;
    occupiedBlocks.add(next);
    return _copyPrivateBlock(block, next);
  }),
);
Future<void> _insertPrivateNotebook(
  QueryExecutor executor,
  Notebook notebook,
) async {
  await executor.runCustom(
    'INSERT INTO notebooks(id, title, created_at, updated_at, revision) VALUES(?, ?, ?, ?, ?)',
    <Object?>[
      notebook.id,
      notebook.title,
      notebook.createdAt.millisecondsSinceEpoch,
      notebook.updatedAt.millisecondsSinceEpoch,
      notebook.revision,
    ],
  );
  for (int rank = 0; rank < notebook.blocks.length; rank++) {
    final NotebookBlock block = notebook.blocks[rank];
    await executor.runCustom(
      'INSERT INTO notebook_blocks(id, notebook_id, rank, text, created_at, updated_at, reference_json) VALUES(?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        block.id,
        notebook.id,
        rank,
        block.text,
        block.createdAt.millisecondsSinceEpoch,
        block.updatedAt.millisecondsSinceEpoch,
        block.reference == null ? null : jsonEncode(block.reference!.toJson()),
      ],
    );
  }
}
