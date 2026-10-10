import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/errors.dart';
import '../../core/json.dart';
import '../../core/starter_marking_groups.dart';
import '../../domain/models/annotations.dart';
import '../../domain/models/backup.dart';
import '../../domain/models/notebook.dart';
import '../../domain/models/offline_resource.dart';
import '../../domain/models/passage.dart';
import '../../domain/models/preferences.dart';
import '../../domain/models/private_backup.dart';
import '../../domain/models/public_topic.dart';
import '../../domain/models/unified_bookmarks.dart';
import '../../domain/repositories/offline_resource_repository.dart';
import 'database_connection.dart';

part 'offline_resource_store.dart';
part 'private_data_store.dart';
part 'unified_bookmark_store.dart';

const int localDatabaseSchemaVersion = 5;

final class CacheRecord {
  const CacheRecord({
    required this.key,
    required this.kind,
    required this.sha,
    required this.json,
    required this.checkedAt,
    required this.cachedAt,
    this.freshUntil,
    this.mustRevalidate = true,
  });

  final String key;
  final String kind;
  final String sha;
  final String json;
  final DateTime checkedAt;
  final DateTime cachedAt;
  final DateTime? freshUntil;
  final bool mustRevalidate;
}

final class LocalDatabase {
  LocalDatabase._(this._executor);

  static Future<LocalDatabase> open() async {
    return fromExecutor(await openDatabaseExecutor());
  }

  static Future<LocalDatabase> memory() async =>
      fromExecutor(await openMemoryDatabaseExecutor());

  static Future<LocalDatabase> fromExecutor(QueryExecutor executor) async {
    final LocalDatabase database = LocalDatabase._(executor);
    try {
      await executor.ensureOpen(_DatabaseUser());
      await database._ensureStarterGroups();
      return database;
    } on Object catch (error, stack) {
      // A failed open/migration must release its worker and file lock before
      // startup offers Retry. Never reset or replace the existing database.
      try {
        await executor.close();
      } on Object {
        // Preserve the original initialization failure if cleanup also fails.
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  final QueryExecutor _executor;

  Future<CacheRecord?> readCache(String key) async {
    final List<Map<String, Object?>> rows = await _executor.runSelect(
      'SELECT cache_key, kind, sha, payload, checked_at, cached_at, fresh_until, must_revalidate FROM cache_entries WHERE cache_key = ?',
      <Object?>[key],
    );
    if (rows.isEmpty) return null;
    final Map<String, Object?> row = rows.single;
    return CacheRecord(
      key: row['cache_key']! as String,
      kind: row['kind']! as String,
      sha: row['sha']! as String,
      json: row['payload']! as String,
      checkedAt: DateTime.fromMillisecondsSinceEpoch(
        row['checked_at']! as int,
        isUtc: true,
      ),
      freshUntil: row['fresh_until'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              row['fresh_until']! as int,
              isUtc: true,
            ),
      mustRevalidate: (row['must_revalidate']! as int) == 1,
      cachedAt: DateTime.fromMillisecondsSinceEpoch(
        row['cached_at']! as int,
        isUtc: true,
      ),
    );
  }

  Future<void> writeCache({
    required String key,
    required String kind,
    required String sha,
    required Object payload,
    required DateTime checkedAt,
    String? rawJson,
    DateTime? freshUntil,
    bool mustRevalidate = true,
  }) async {
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _executor.runCustom(
      'INSERT INTO cache_entries(cache_key, kind, sha, payload, checked_at, cached_at, fresh_until, must_revalidate) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(cache_key) DO UPDATE SET '
      'kind=excluded.kind, sha=excluded.sha, payload=excluded.payload, '
      'checked_at=excluded.checked_at, cached_at=excluded.cached_at, '
      'fresh_until=excluded.fresh_until, must_revalidate=excluded.must_revalidate',
      <Object?>[
        key,
        kind,
        sha,
        rawJson ?? jsonEncode(payload),
        checkedAt.millisecondsSinceEpoch,
        now,
        freshUntil?.millisecondsSinceEpoch,
        mustRevalidate ? 1 : 0,
      ],
    );
  }

  Future<void> touchCache(String key, DateTime checkedAt) =>
      _executor.runCustom(
        'UPDATE cache_entries SET checked_at = ? WHERE cache_key = ?',
        <Object?>[checkedAt.millisecondsSinceEpoch, key],
      );

  Future<void> deleteCache(String key) => _executor.runCustom(
    'DELETE FROM cache_entries WHERE cache_key = ?',
    <Object?>[key],
  );

  /// Matches an exact key or delimiter-separated descendants. substr is literal
  /// (unlike LIKE), so numeric neighbours and %, _ and \ are never wildcards.
  Future<void> deleteCachePrefix(String prefix) {
    final String descendants = prefix.endsWith(':') ? prefix : '$prefix:';
    return _executor.runCustom(
      'DELETE FROM cache_entries WHERE cache_key = ? OR substr(cache_key, 1, ?) = ?',
      <Object?>[prefix, descendants.length, descendants],
    );
  }

  /// Expire verification while retaining readable last-known-good Scripture.
  Future<void> invalidateCachePrefix(String prefix) {
    final String descendants = prefix.endsWith(':') ? prefix : '$prefix:';
    return _executor.runCustom(
      'UPDATE cache_entries SET sha = ?, checked_at = 0, fresh_until = NULL, must_revalidate = 1 '
      'WHERE cache_key = ? OR substr(cache_key, 1, ?) = ?',
      <Object?>['', prefix, descendants.length, descendants],
    );
  }

  Future<void> clearScriptureCache() => _executor.runCustom(
    "DELETE FROM cache_entries WHERE substr(cache_key, 1, 6) = 'bible:' "
    "OR kind IN ('translations', 'books', 'chapters', 'chapter', 'fullTranslation')",
  );

  Future<void> clearCache() => _executor.runCustom('DELETE FROM cache_entries');

  Future<List<MarkingGroup>> getGroups() async {
    final List<Map<String, Object?>> rows = await _executor.runSelect(
      'SELECT id, name, color, sort_order, is_starter, updated_at, source_json FROM marking_groups ORDER BY sort_order, name COLLATE NOCASE',
      const <Object?>[],
    );
    return rows.map(_groupFromRow).toList(growable: false);
  }

  Future<void> saveGroup(MarkingGroup group) => _executor.runCustom(
    'INSERT INTO marking_groups(id, name, color, sort_order, is_starter, updated_at, source_json) '
    'VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, '
    'color=excluded.color, sort_order=excluded.sort_order, updated_at=excluded.updated_at, source_json=excluded.source_json',
    <Object?>[
      group.id,
      group.name,
      group.color,
      group.sortOrder,
      group.isStarter ? 1 : 0,
      group.updatedAt.millisecondsSinceEpoch,
      group.source == null ? null : jsonEncode(group.source!.toJson()),
    ],
  );

  Future<void> deleteGroup(String id) =>
      _transaction((QueryExecutor transaction) async {
        await transaction.runCustom(
          'DELETE FROM markings WHERE group_id = ?',
          <Object?>[id],
        );
        await transaction.runCustom(
          'DELETE FROM marking_groups WHERE id = ?',
          <Object?>[id],
        );
      });

  Future<List<Marking>> getMarkings({Passage? passage}) async {
    final List<Object?> args = <Object?>[];
    String where = '';
    if (passage != null) {
      where =
          'WHERE (book_nr = ? AND chapter_nr = ?) AND '
          '((start_offset IS NULL AND end_offset IS NULL) OR translation = ?)';
      args.addAll(<Object?>[
        passage.book,
        passage.chapter,
        passage.translation,
      ]);
    }
    final List<Map<String, Object?>> rows = await _executor.runSelect(
      'SELECT id, translation, book_nr, chapter_nr, verse_nr, start_offset, end_offset, '
      'quote, reference, group_id, created_at, source_json FROM markings $where '
      'ORDER BY book_nr, chapter_nr, verse_nr, COALESCE(start_offset, -1), created_at',
      args,
    );
    return rows.map(_markingFromRow).toList(growable: false);
  }

  Future<void> saveMarking(Marking marking) => _saveMarking(_executor, marking);

  /// Recheck semantic identities under SQLite's write transaction, rather than
  /// trusting a possibly stale reader snapshot. Overlapping editor requests
  /// cannot duplicate a membership or replace an unrelated record by ID.
  Future<void> addMarkingMemberships(List<Marking> markings) => _transaction((
    QueryExecutor transaction,
  ) async {
    for (final Marking marking in markings) {
      final List<Map<String, Object?>> rows = await transaction.runSelect(
        'SELECT id, translation, book_nr, chapter_nr, verse_nr, start_offset, end_offset, '
        'quote, reference, group_id, created_at, source_json FROM markings '
        'WHERE group_id = ? AND book_nr = ? AND chapter_nr = ? AND verse_nr = ?',
        <Object?>[
          marking.groupId,
          marking.passage.book,
          marking.passage.chapter,
          marking.verse,
        ],
      );
      if (rows.any(
        (Map<String, Object?> row) =>
            _markingFromRow(row).identity == marking.identity,
      )) {
        continue;
      }
      final List<Map<String, Object?>> collision = await transaction.runSelect(
        'SELECT id FROM markings WHERE id = ?',
        <Object?>[marking.id],
      );
      if (collision.isNotEmpty) {
        throw const StorageException(
          'The marking identity already belongs to another membership.',
        );
      }
      await _saveMarking(transaction, marking);
    }
  });

  Future<void> replaceMarkings(List<Marking> remove, List<Marking> add) =>
      _transaction((QueryExecutor transaction) async {
        for (final Marking marking in remove) {
          await transaction.runCustom(
            'DELETE FROM markings WHERE id = ?',
            <Object?>[marking.id],
          );
        }
        for (final Marking marking in add) {
          await _saveMarking(transaction, marking);
        }
      });

  Future<void> deleteMarking(String id) =>
      _executor.runCustom('DELETE FROM markings WHERE id = ?', <Object?>[id]);

  Future<void> deleteAllMarkings() =>
      _executor.runCustom('DELETE FROM markings');

  Future<List<VerseNote>> getNotes({Passage? passage}) async {
    final String where = passage == null
        ? ''
        : 'WHERE book_nr = ? AND chapter_nr = ?';
    final List<Object?> args = passage == null
        ? const <Object?>[]
        : <Object?>[passage.book, passage.chapter];
    final List<Map<String, Object?>> rows = await _executor.runSelect(
      'SELECT id, translation, book_nr, chapter_nr, verse_nr, reference, text, created_at, updated_at '
      'FROM notes $where ORDER BY book_nr, chapter_nr, verse_nr',
      args,
    );
    return rows.map(_noteFromRow).toList(growable: false);
  }

  Future<void> saveNote(VerseNote note) => _executor.runCustom(
    'INSERT INTO notes(id, canonical_key, translation, book_nr, chapter_nr, verse_nr, reference, text, created_at, updated_at) '
    'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(canonical_key) DO UPDATE SET '
    'id=excluded.id, translation=excluded.translation, reference=excluded.reference, text=excluded.text, updated_at=excluded.updated_at',
    <Object?>[
      note.id,
      note.canonicalKey,
      note.passage.translation,
      note.passage.book,
      note.passage.chapter,
      note.verse,
      note.reference,
      note.text,
      note.createdAt.millisecondsSinceEpoch,
      note.updatedAt.millisecondsSinceEpoch,
    ],
  );

  Future<void> deleteNote(String canonicalKey) => _executor.runCustom(
    'DELETE FROM notes WHERE canonical_key = ?',
    <Object?>[canonicalKey],
  );

  Future<List<NotebookSummary>> getNotebooks() async {
    final List<Map<String, Object?>> rows = await _executor.runSelect(
      'SELECT id, title, created_at, updated_at, revision, '
      '(SELECT COUNT(*) FROM notebook_blocks WHERE notebook_id = notebooks.id) AS block_count '
      'FROM notebooks ORDER BY updated_at DESC, created_at DESC, id',
      const <Object?>[],
    );
    return rows
        .map(
          (Map<String, Object?> row) => NotebookSummary(
            id: row['id']! as String,
            title: row['title']! as String,
            createdAt: _storedTime(row['created_at']),
            updatedAt: _storedTime(row['updated_at']),
            revision: row['revision']! as int,
            blockCount: row['block_count']! as int,
          ),
        )
        .toList(growable: false);
  }

  Future<Notebook?> getNotebook(String id) => _transaction((
    QueryExecutor transaction,
  ) async {
    final List<Map<String, Object?>> rows = await transaction.runSelect(
      'SELECT id, title, created_at, updated_at, revision FROM notebooks WHERE id = ?',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    final Map<String, Object?> row = rows.single;
    final List<Map<String, Object?>> blocks = await transaction.runSelect(
      'SELECT id, text, created_at, updated_at, reference_json FROM notebook_blocks WHERE notebook_id = ? ORDER BY rank',
      <Object?>[id],
    );
    return Notebook(
      id: id,
      title: row['title']! as String,
      createdAt: _storedTime(row['created_at']),
      updatedAt: _storedTime(row['updated_at']),
      revision: row['revision']! as int,
      blocks: blocks.map(
        (Map<String, Object?> block) => NotebookBlock(
          id: block['id']! as String,
          text: block['text']! as String,
          createdAt: _storedTime(block['created_at']),
          updatedAt: _storedTime(block['updated_at']),
          reference: block['reference_json'] == null
              ? null
              : NotebookReference.fromJson(
                  decodeStoredJson(
                    block['reference_json']! as String,
                    'notebook reference',
                  ),
                ),
        ),
      ),
    );
  });

  Future<List<NotebookDraft>> getNotebookDrafts() async {
    final List<Map<String, Object?>> rows = await _executor.runSelect(
      'SELECT payload, base_revision, editor_id FROM notebook_drafts ORDER BY updated_at DESC, editor_id',
      const <Object?>[],
    );
    return rows
        .map(
          (Map<String, Object?> row) => NotebookDraft(
            notebook: Notebook.fromJson(
              decodeStoredJson(row['payload']! as String, 'notebook draft'),
            ),
            baseRevision: row['base_revision'] as int?,
            editorId: row['editor_id']! as String,
          ),
        )
        .toList(growable: false);
  }

  Future<void> saveNotebookDraft(
    Notebook notebook, {
    required int? expectedRevision,
    String editorId = 'primary',
  }) => _executor.runCustom(
    'INSERT INTO notebook_drafts(id, revision, payload, updated_at, base_revision, editor_id) VALUES(?, ?, ?, ?, ?, ?) '
    'ON CONFLICT(id, editor_id) DO UPDATE SET revision=excluded.revision, payload=excluded.payload, updated_at=excluded.updated_at, base_revision=excluded.base_revision WHERE excluded.revision >= notebook_drafts.revision',
    <Object?>[
      notebook.id,
      notebook.revision,
      jsonEncode(notebook.toJson()),
      notebook.updatedAt.millisecondsSinceEpoch,
      expectedRevision,
      editorId,
    ],
  );

  /// Parent and ordered blocks activate together. Drafts are independently
  /// durable before activation; a failed transaction leaves them recoverable.
  Future<void> saveNotebook(
    Notebook notebook, {
    required int? expectedRevision,
    String editorId = 'primary',
  }) => _transaction((QueryExecutor transaction) async {
    final List<Map<String, Object?>> previous = await transaction.runSelect(
      'SELECT revision, created_at FROM notebooks WHERE id = ?',
      <Object?>[notebook.id],
    );
    if ((previous.isEmpty && expectedRevision != null) ||
        (previous.isNotEmpty &&
            previous.single['revision'] != expectedRevision)) {
      throw const NotebookConflictException();
    }
    if (previous.isNotEmpty &&
        (notebook.revision <= expectedRevision! ||
            notebook.createdAt.millisecondsSinceEpoch !=
                previous.single['created_at'])) {
      throw const StorageException(
        'A notebook update must preserve its creation time and advance its revision.',
      );
    }
    await transaction.runCustom(
      'INSERT INTO notebooks(id, title, created_at, updated_at, revision) VALUES(?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET title=excluded.title, updated_at=excluded.updated_at, revision=excluded.revision',
      <Object?>[
        notebook.id,
        notebook.title,
        notebook.createdAt.millisecondsSinceEpoch,
        notebook.updatedAt.millisecondsSinceEpoch,
        notebook.revision,
      ],
    );
    await transaction.runCustom(
      'DELETE FROM notebook_blocks WHERE notebook_id = ?',
      <Object?>[notebook.id],
    );
    for (int rank = 0; rank < notebook.blocks.length; rank++) {
      final NotebookBlock block = notebook.blocks[rank];
      await transaction.runCustom(
        'INSERT INTO notebook_blocks(id, notebook_id, rank, text, created_at, updated_at, reference_json) VALUES(?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          block.id,
          notebook.id,
          rank,
          block.text,
          block.createdAt.millisecondsSinceEpoch,
          block.updatedAt.millisecondsSinceEpoch,
          block.reference == null
              ? null
              : jsonEncode(block.reference!.toJson()),
        ],
      );
    }
    await transaction.runCustom(
      'DELETE FROM notebook_drafts WHERE id = ? AND editor_id = ? AND revision <= ?',
      <Object?>[notebook.id, editorId, notebook.revision],
    );
  });

  Future<void> discardNotebookDraft(
    String id,
    int revision, {
    String editorId = 'primary',
  }) => _executor.runCustom(
    'DELETE FROM notebook_drafts WHERE id = ? AND revision = ? AND editor_id = ?',
    <Object?>[id, revision, editorId],
  );

  Future<void> deleteNotebook(String id) =>
      _transaction((QueryExecutor transaction) async {
        await transaction.runCustom(
          'DELETE FROM notebook_drafts WHERE id = ?',
          <Object?>[id],
        );
        await transaction.runCustom(
          'DELETE FROM notebooks WHERE id = ?',
          <Object?>[id],
        );
        await transaction.runCustom(
          'DELETE FROM settings WHERE setting_key = ? AND value = ?',
          <Object?>['notebooks:v1:selected', jsonEncode(id)],
        );
      });

  Future<String?> selectedNotebook() async {
    final String? value = await readSetting('notebooks:v1:selected');
    if (value == null) return null;
    final Object? decoded = jsonDecode(value);
    if (decoded is! String) {
      throw const StorageException('The saved notebook selection is invalid.');
    }
    return decoded;
  }

  Future<void> selectNotebook(String? id) => id == null
      ? _executor.runCustom(
          'DELETE FROM settings WHERE setting_key = ?',
          <Object?>['notebooks:v1:selected'],
        )
      : writeSetting('notebooks:v1:selected', id);

  /// A public topic is copied only after an explicit preview. Public refreshes
  /// never call this transaction or mutate private annotations.
  Future<int> commitPublicTopicCopy({
    required String provenanceKey,
    required String groupId,
    required MarkingGroup? newGroup,
    required List<Marking> newMarkings,
  }) => _transaction((QueryExecutor transaction) async {
    int added = 0;
    final List<Map<String, Object?>> provenance = await transaction.runSelect(
      'SELECT value FROM settings WHERE setting_key = ?',
      <Object?>[provenanceKey],
    );
    if (provenance.isNotEmpty) {
      final JsonMap saved = decodeStoredJson(
        provenance.single['value']! as String,
        'public topic provenance',
      );
      final String previousId = requireString(saved, 'groupId');
      if (requireInt(saved, 'version') != 1) {
        throw const StorageException(
          'This public topic provenance format is unsupported.',
        );
      }
      if (previousId != groupId) {
        final List<Map<String, Object?>> previousGroup = await transaction
            .runSelect('SELECT id FROM marking_groups WHERE id = ?', <Object?>[
              previousId,
            ]);
        if (previousGroup.isNotEmpty) {
          throw const StorageException(
            'This public topic was already copied to another private group.',
          );
        }
      }
    }
    final List<Map<String, Object?>> existingGroup = await transaction
        .runSelect('SELECT id FROM marking_groups WHERE id = ?', <Object?>[
          groupId,
        ]);
    if (newGroup != null) {
      if (newGroup.id != groupId || existingGroup.isNotEmpty) {
        throw const StorageException(
          'The private group identity already exists.',
        );
      }
      await _saveGroup(transaction, newGroup);
    } else if (existingGroup.isEmpty) {
      throw const StorageException(
        'The private copy destination no longer exists.',
      );
    }
    for (final Marking marking in newMarkings) {
      if (marking.groupId != groupId || !marking.isWholeVerse) {
        throw const StorageException(
          'A public topic copy contains an invalid private marking.',
        );
      }
      final List<Map<String, Object?>> duplicate = await transaction.runSelect(
        'SELECT id FROM markings WHERE group_id = ? AND book_nr = ? AND chapter_nr = ? AND verse_nr = ? AND start_offset IS NULL AND end_offset IS NULL',
        <Object?>[
          groupId,
          marking.passage.book,
          marking.passage.chapter,
          marking.verse,
        ],
      );
      if (duplicate.isNotEmpty) continue;
      final List<Map<String, Object?>> collision = await transaction.runSelect(
        'SELECT id FROM markings WHERE id = ?',
        <Object?>[marking.id],
      );
      if (collision.isNotEmpty) {
        throw const StorageException(
          'The private marking identity already exists.',
        );
      }
      await _saveMarking(transaction, marking);
      added++;
    }
    await transaction.runCustom(
      'INSERT INTO settings(setting_key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(setting_key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at',
      <Object?>[
        provenanceKey,
        jsonEncode(<String, Object?>{'version': 1, 'groupId': groupId}),
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
    return added;
  });

  Future<String?> readSetting(String key) async {
    final List<Map<String, Object?>> rows = await _executor.runSelect(
      'SELECT value FROM settings WHERE setting_key = ?',
      <Object?>[key],
    );
    return rows.isEmpty ? null : rows.single['value']! as String;
  }

  Future<void> writeSetting(String key, Object value) => _executor.runCustom(
    'INSERT INTO settings(setting_key, value, updated_at) VALUES(?, ?, ?) '
    'ON CONFLICT(setting_key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at',
    <Object?>[
      key,
      jsonEncode(value),
      DateTime.now().toUtc().millisecondsSinceEpoch,
    ],
  );

  Future<void> deleteSettings() => _executor.runCustom('DELETE FROM settings');

  Future<void> replaceReaderData({
    required List<MarkingGroup> groups,
    required List<Marking> markings,
    required List<VerseNote> notes,
  }) => _transaction((QueryExecutor transaction) async {
    await transaction.runCustom('DELETE FROM markings');
    await transaction.runCustom('DELETE FROM notes');
    await transaction.runCustom('DELETE FROM marking_groups');
    for (final MarkingGroup group in groups) {
      await _saveGroup(transaction, group);
    }
    for (final Marking marking in markings) {
      await _saveMarking(transaction, marking);
    }
    for (final VerseNote note in notes) {
      await _saveNote(transaction, note);
    }
  });

  Future<void> clearAllReaderData() async {
    await _transaction((QueryExecutor transaction) async {
      await transaction.runCustom('DELETE FROM markings');
      await transaction.runCustom('DELETE FROM notes');
      await transaction.runCustom('DELETE FROM marking_groups');
      await transaction.runCustom('DELETE FROM settings');
    });
    await _ensureStarterGroups();
  }

  Future<void> close() => _executor.close();

  Future<void> _ensureStarterGroups() async {
    final List<Map<String, Object?>> rows = await _executor.runSelect(
      'SELECT COUNT(*) AS group_count FROM marking_groups',
      const <Object?>[],
    );
    if ((rows.single['group_count']! as int) > 0) return;
    await _transaction((QueryExecutor transaction) async {
      for (final MarkingGroup group in starterMarkingGroups()) {
        await _saveGroup(transaction, group);
      }
    });
  }

  Future<T> _transaction<T>(
    Future<T> Function(QueryExecutor executor) action,
  ) async {
    final TransactionExecutor transaction = _executor.beginTransaction();
    await transaction.ensureOpen(_DatabaseUser());
    try {
      final T result = await action(transaction);
      await transaction.send();
      return result;
    } catch (error) {
      await transaction.rollback();
      throw StorageException('The local database transaction failed.', error);
    }
  }
}

final class _DatabaseUser extends QueryExecutorUser {
  @override
  int get schemaVersion => localDatabaseSchemaVersion;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    await executor.ensureOpen(this);
    await executor.runCustom('PRAGMA foreign_keys = ON');
    final int from = details.versionBefore ?? 0;
    if (from < localDatabaseSchemaVersion) {
      await executor.runCustom('BEGIN IMMEDIATE');
      try {
        if (details.wasCreated || from < 1) await _createVersionOne(executor);
        if (from < 2) await _migrateVersionTwo(executor);
        if (from < 3) await _migrateVersionThree(executor);
        if (from < 4) await _migrateVersionFour(executor);
        if (from < 5) await createOfflineResourceTables(executor);
        await executor.runCustom(
          'PRAGMA user_version = $localDatabaseSchemaVersion',
        );
        await executor.runCustom('COMMIT');
      } catch (_) {
        await executor.runCustom('ROLLBACK');
        rethrow;
      }
    }
  }
}

/// Additive provenance columns leave all previous annotation values untouched.
/// Legacy deterministic source IDs are recognized by the domain model; other
/// existing records remain private rather than guessing from a group's label.
Future<void> _migrateVersionFour(QueryExecutor executor) async {
  await executor.runCustom(
    'ALTER TABLE marking_groups ADD COLUMN source_json TEXT',
  );
  await executor.runCustom('ALTER TABLE markings ADD COLUMN source_json TEXT');
}

Future<void> _migrateVersionThree(QueryExecutor executor) async {
  const List<String> statements = <String>[
    'CREATE TABLE notebooks(id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL CHECK(length(title) <= 200), created_at INTEGER NOT NULL CHECK(created_at >= 0), updated_at INTEGER NOT NULL CHECK(updated_at >= created_at), revision INTEGER NOT NULL CHECK(revision > 0))',
    'CREATE INDEX notebooks_recent ON notebooks(updated_at DESC, created_at DESC, id)',
    'CREATE TABLE notebook_blocks(id TEXT PRIMARY KEY NOT NULL, notebook_id TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE, rank INTEGER NOT NULL CHECK(rank >= 0), text TEXT NOT NULL CHECK(length(text) <= 100000), created_at INTEGER NOT NULL CHECK(created_at >= 0), updated_at INTEGER NOT NULL CHECK(updated_at >= created_at), reference_json TEXT, UNIQUE(notebook_id, rank))',
    'CREATE TABLE notebook_drafts(id TEXT NOT NULL, editor_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), payload TEXT NOT NULL, updated_at INTEGER NOT NULL, base_revision INTEGER CHECK(base_revision > 0), PRIMARY KEY(id, editor_id))',
  ];
  for (final String statement in statements) {
    await executor.runCustom(statement);
  }
}

/// Forward migration keeps private tables, offsets, settings and database
/// identity intact. Legacy payloads retain their original v2 provenance.
Future<void> _migrateVersionTwo(QueryExecutor executor) async {
  await executor.runCustom(
    'ALTER TABLE cache_entries ADD COLUMN fresh_until INTEGER',
  );
  await executor.runCustom(
    'ALTER TABLE cache_entries ADD COLUMN must_revalidate INTEGER NOT NULL DEFAULT 1',
  );
  await executor.runCustom(
    "UPDATE cache_entries SET cache_key = 'bible:v2:s1:' || cache_key "
    "WHERE kind IN ('translations', 'books', 'chapters', 'chapter', 'fullTranslation') "
    "AND substr(cache_key, 1, 6) != 'bible:'",
  );
}

Future<void> _createVersionOne(QueryExecutor executor) async {
  const List<String> statements = <String>[
    'CREATE TABLE IF NOT EXISTS cache_entries('
        'cache_key TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, sha TEXT NOT NULL DEFAULT "", '
        'payload TEXT NOT NULL, checked_at INTEGER NOT NULL, cached_at INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS cache_entries_kind ON cache_entries(kind)',
    'CREATE TABLE IF NOT EXISTS marking_groups('
        'id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL, sort_order INTEGER NOT NULL, '
        'is_starter INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL)',
    'CREATE TABLE IF NOT EXISTS markings('
        'id TEXT PRIMARY KEY NOT NULL, translation TEXT NOT NULL, book_nr INTEGER NOT NULL, chapter_nr INTEGER NOT NULL, '
        'verse_nr INTEGER NOT NULL, start_offset INTEGER, end_offset INTEGER, quote TEXT NOT NULL, reference TEXT NOT NULL, '
        'group_id TEXT NOT NULL REFERENCES marking_groups(id) ON DELETE CASCADE, created_at INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS markings_canonical ON markings(book_nr, chapter_nr, verse_nr)',
    'CREATE INDEX IF NOT EXISTS markings_translation ON markings(translation, book_nr, chapter_nr, verse_nr)',
    'CREATE INDEX IF NOT EXISTS markings_group ON markings(group_id, book_nr, chapter_nr, verse_nr)',
    'CREATE TABLE IF NOT EXISTS notes('
        'id TEXT PRIMARY KEY NOT NULL, canonical_key TEXT NOT NULL UNIQUE, translation TEXT NOT NULL, '
        'book_nr INTEGER NOT NULL, chapter_nr INTEGER NOT NULL, verse_nr INTEGER NOT NULL, reference TEXT NOT NULL, '
        'text TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS notes_order ON notes(book_nr, chapter_nr, verse_nr)',
    'CREATE TABLE IF NOT EXISTS settings('
        'setting_key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL, updated_at INTEGER NOT NULL)',
  ];
  for (final String statement in statements) {
    await executor.runCustom(statement);
  }
}

MarkingGroup _groupFromRow(Map<String, Object?> row) => MarkingGroup(
  id: row['id']! as String,
  name: row['name']! as String,
  color: row['color']! as String,
  sortOrder: row['sort_order']! as int,
  isStarter: (row['is_starter']! as int) == 1,
  updatedAt: DateTime.fromMillisecondsSinceEpoch(
    row['updated_at']! as int,
    isUtc: true,
  ),
  source: _bookmarkSourceFromRow(row),
);

Marking _markingFromRow(Map<String, Object?> row) => Marking(
  id: row['id']! as String,
  passage: Passage(
    translation: row['translation']! as String,
    book: row['book_nr']! as int,
    chapter: row['chapter_nr']! as int,
  ),
  verse: row['verse_nr']! as int,
  start: row['start_offset'] as int?,
  end: row['end_offset'] as int?,
  quote: row['quote']! as String,
  reference: row['reference']! as String,
  groupId: row['group_id']! as String,
  createdAt: DateTime.fromMillisecondsSinceEpoch(
    row['created_at']! as int,
    isUtc: true,
  ),
  source: _bookmarkSourceFromRow(row),
);

SharedBookmarkSource? _bookmarkSourceFromRow(Map<String, Object?> row) =>
    row['source_json'] == null
    ? null
    : SharedBookmarkSource.fromJson(jsonDecode(row['source_json']! as String));

VerseNote _noteFromRow(Map<String, Object?> row) => VerseNote(
  id: row['id']! as String,
  passage: Passage(
    translation: row['translation']! as String,
    book: row['book_nr']! as int,
    chapter: row['chapter_nr']! as int,
  ),
  verse: row['verse_nr']! as int,
  reference: row['reference']! as String,
  text: row['text']! as String,
  createdAt: DateTime.fromMillisecondsSinceEpoch(
    row['created_at']! as int,
    isUtc: true,
  ),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(
    row['updated_at']! as int,
    isUtc: true,
  ),
);

Future<void> _saveGroup(
  QueryExecutor executor,
  MarkingGroup group,
) => executor.runCustom(
  'INSERT INTO marking_groups(id, name, color, sort_order, is_starter, updated_at, source_json) VALUES(?, ?, ?, ?, ?, ?, ?)',
  <Object?>[
    group.id,
    group.name,
    group.color,
    group.sortOrder,
    group.isStarter ? 1 : 0,
    group.updatedAt.millisecondsSinceEpoch,
    group.source == null ? null : jsonEncode(group.source!.toJson()),
  ],
);

Future<void> _saveMarking(
  QueryExecutor executor,
  Marking marking,
) => executor.runCustom(
  'INSERT INTO markings(id, translation, book_nr, chapter_nr, verse_nr, start_offset, end_offset, quote, reference, group_id, created_at, source_json) '
  'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET group_id=excluded.group_id, '
  'start_offset=excluded.start_offset, end_offset=excluded.end_offset, quote=excluded.quote, reference=excluded.reference, source_json=excluded.source_json',
  <Object?>[
    marking.id,
    marking.passage.translation,
    marking.passage.book,
    marking.passage.chapter,
    marking.verse,
    marking.start,
    marking.end,
    marking.quote,
    marking.reference,
    marking.groupId,
    marking.createdAt.millisecondsSinceEpoch,
    marking.sharedSource == null
        ? null
        : jsonEncode(marking.sharedSource!.toJson()),
  ],
);

Future<void> _saveNote(
  QueryExecutor executor,
  VerseNote note,
) => executor.runCustom(
  'INSERT INTO notes(id, canonical_key, translation, book_nr, chapter_nr, verse_nr, reference, text, created_at, updated_at) '
  'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
  <Object?>[
    note.id,
    note.canonicalKey,
    note.passage.translation,
    note.passage.book,
    note.passage.chapter,
    note.verse,
    note.reference,
    note.text,
    note.createdAt.millisecondsSinceEpoch,
    note.updatedAt.millisecondsSinceEpoch,
  ],
);

JsonMap decodeStoredJson(String value, String label) {
  try {
    return requireJsonMap(jsonDecode(value), label);
  } on FormatException catch (error) {
    throw StorageException('Stored $label data is malformed.', error);
  }
}

DateTime _storedTime(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch(value! as int, isUtc: true);
