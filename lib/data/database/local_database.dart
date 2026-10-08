import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/errors.dart';
import '../../core/json.dart';
import '../../core/starter_marking_groups.dart';
import '../../domain/models/annotations.dart';
import '../../domain/models/passage.dart';
import 'database_connection.dart';

const int localDatabaseSchemaVersion = 2;

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
    await executor.ensureOpen(_DatabaseUser());
    await database._ensureStarterGroups();
    return database;
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
      'SELECT id, name, color, sort_order, is_starter, updated_at FROM marking_groups ORDER BY sort_order, name COLLATE NOCASE',
      const <Object?>[],
    );
    return rows.map(_groupFromRow).toList(growable: false);
  }

  Future<void> saveGroup(MarkingGroup group) => _executor.runCustom(
    'INSERT INTO marking_groups(id, name, color, sort_order, is_starter, updated_at) '
    'VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, '
    'color=excluded.color, sort_order=excluded.sort_order, updated_at=excluded.updated_at',
    <Object?>[
      group.id,
      group.name,
      group.color,
      group.sortOrder,
      group.isStarter ? 1 : 0,
      group.updatedAt.millisecondsSinceEpoch,
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
      'quote, reference, group_id, created_at FROM markings $where '
      'ORDER BY book_nr, chapter_nr, verse_nr, COALESCE(start_offset, -1), created_at',
      args,
    );
    return rows.map(_markingFromRow).toList(growable: false);
  }

  Future<void> saveMarking(Marking marking) => _saveMarking(_executor, marking);

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

  Future<void> _transaction(
    Future<void> Function(QueryExecutor executor) action,
  ) async {
    final TransactionExecutor transaction = _executor.beginTransaction();
    await transaction.ensureOpen(_DatabaseUser());
    try {
      await action(transaction);
      await transaction.send();
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
);

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
  'INSERT INTO marking_groups(id, name, color, sort_order, is_starter, updated_at) VALUES(?, ?, ?, ?, ?, ?)',
  <Object?>[
    group.id,
    group.name,
    group.color,
    group.sortOrder,
    group.isStarter ? 1 : 0,
    group.updatedAt.millisecondsSinceEpoch,
  ],
);

Future<void> _saveMarking(
  QueryExecutor executor,
  Marking marking,
) => executor.runCustom(
  'INSERT INTO markings(id, translation, book_nr, chapter_nr, verse_nr, start_offset, end_offset, quote, reference, group_id, created_at) '
  'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET group_id=excluded.group_id, '
  'start_offset=excluded.start_offset, end_offset=excluded.end_offset, quote=excluded.quote, reference=excluded.reference',
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
