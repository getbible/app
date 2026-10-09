part of 'local_database.dart';

/// Public installations use separate tables and immutable generations. Neither
/// cache cleanup nor private-data import/reset addresses these tables.
Future<void> createOfflineResourceTables(QueryExecutor executor) async {
  for (final statement in <String>[
    'CREATE TABLE offline_generations(generation TEXT PRIMARY KEY NOT NULL, resource_key TEXT NOT NULL, descriptor TEXT NOT NULL, byte_count INTEGER NOT NULL DEFAULT 0 CHECK(byte_count >= 0), updated_at INTEGER NOT NULL)',
    'CREATE INDEX offline_generations_resource ON offline_generations(resource_key)',
    'CREATE TABLE offline_active(resource_key TEXT PRIMARY KEY NOT NULL, generation TEXT NOT NULL UNIQUE REFERENCES offline_generations(generation) ON DELETE CASCADE, installed_at INTEGER NOT NULL)',
    'CREATE TABLE offline_documents(generation TEXT NOT NULL REFERENCES offline_generations(generation) ON DELETE CASCADE, path TEXT NOT NULL, payload TEXT NOT NULL, byte_count INTEGER NOT NULL, PRIMARY KEY(generation,path))',
    'CREATE TABLE offline_search(generation TEXT NOT NULL REFERENCES offline_generations(generation) ON DELETE CASCADE, book INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL, book_name TEXT NOT NULL, direction TEXT NOT NULL, verse_json TEXT NOT NULL, text TEXT NOT NULL, normalized_text TEXT NOT NULL, byte_count INTEGER NOT NULL, PRIMARY KEY(generation,book,chapter,verse))',
    'CREATE TABLE offline_attempts(resource_key TEXT PRIMARY KEY NOT NULL, generation TEXT, descriptor TEXT NOT NULL, state TEXT NOT NULL, message TEXT NOT NULL, updated_at INTEGER NOT NULL)',
  ]) {
    await executor.runCustom(statement);
  }
}

final class SqlOfflineResourceStore implements OfflineResourceStore {
  SqlOfflineResourceStore(this.database, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final LocalDatabase database;
  final DateTime Function() _clock;
  static const _lease = Duration(minutes: 2);
  int get _now => _clock().toUtc().millisecondsSinceEpoch;

  @override
  Future<List<OfflineInstalledResource>> listInstalled() async {
    final rows = await database._executor.runSelect(
      'SELECT g.*, a.installed_at FROM offline_active a JOIN offline_generations g ON a.generation=g.generation ORDER BY g.resource_key',
      [],
    );
    return rows.map(_installed).toList(growable: false);
  }

  @override
  Future<OfflineInstalledResource?> find(
    OfflineResourceKind kind,
    String id,
    Uri sourceUri,
  ) async {
    final key = OfflineResourceDescriptor(
      kind: kind,
      id: id,
      title: id,
      sourceUri: sourceUri,
      revision: '',
    ).key;
    final rows = await database._executor.runSelect(
      'SELECT g.*, a.installed_at FROM offline_active a JOIN offline_generations g ON a.generation=g.generation WHERE a.resource_key=?',
      [key],
    );
    return rows.isEmpty ? null : _installed(rows.single);
  }

  OfflineInstalledResource _installed(Map<String, Object?> row) =>
      OfflineInstalledResource(
        resource: OfflineResourceDescriptor.fromJson(
          jsonDecode(row['descriptor']! as String),
        ),
        generation: row['generation']! as String,
        byteCount: row['byte_count']! as int,
        installedAt: DateTime.fromMillisecondsSinceEpoch(
          row['installed_at']! as int,
          isUtc: true,
        ),
      );

  @override
  Future<String?> readDocument(
    String resourceKey,
    String path, {
    String? generation,
  }) async {
    final rows = await database._executor.runSelect(
      'SELECT d.payload FROM offline_documents d JOIN offline_active a ON a.generation=d.generation WHERE a.resource_key=? AND d.path=?${generation == null ? '' : ' AND a.generation=?'}',
      [resourceKey, path, ?generation],
    );
    return rows.isEmpty ? null : rows.single['payload']! as String;
  }

  @override
  Future<List<String>> listDocumentPaths(
    String resourceKey, {
    String prefix = '',
    int offset = 0,
    int limit = 100,
    String? generation,
  }) async {
    _page(offset, limit);
    final rows = await database._executor.runSelect(
      'SELECT d.path FROM offline_documents d JOIN offline_active a ON a.generation=d.generation WHERE a.resource_key=? AND substr(d.path,1,?)=?${generation == null ? '' : ' AND a.generation=?'} ORDER BY d.path LIMIT ? OFFSET ?',
      [resourceKey, prefix.length, prefix, ?generation, limit, offset],
    );
    return rows.map((row) => row['path']! as String).toList(growable: false);
  }

  @override
  Future<List<OfflineSearchVerse>> readSearchVerses(
    String resourceKey, {
    List<String> terms = const [],
    List<int>? books,
    bool matchAny = false,
    bool caseSensitive = false,
    int offset = 0,
    int limit = 100,
    String? generation,
  }) async {
    _page(offset, limit);
    if (terms.length > 50 ||
        terms.any((t) => t.isEmpty || t.runes.take(501).length > 500) ||
        (books != null && (books.length > 1000 || books.any((b) => b < 1)))) {
      throw ArgumentError('Invalid offline search bounds.');
    }
    if (books != null && books.isEmpty) return [];
    // instr is literal and case-sensitive. Unicode lowercasing is performed by
    // Dart when indexing and querying, avoiding SQLite's ASCII-only lower().
    final column = caseSensitive ? 's.text' : 's.normalized_text';
    final clauses = <String>[
      'a.resource_key=?',
      if (generation != null) 'a.generation=?',
      if (books != null)
        's.book IN (${List.filled(books.length, '?').join(',')})',
      if (terms.isNotEmpty)
        '(${List.filled(terms.length, 'instr($column,?)>0').join(matchAny ? ' OR ' : ' AND ')})',
    ];
    final rows = await database._executor.runSelect(
      'SELECT s.* FROM offline_search s JOIN offline_active a ON a.generation=s.generation WHERE ${clauses.join(' AND ')} ORDER BY s.book,s.chapter,s.verse LIMIT ? OFFSET ?',
      [
        resourceKey,
        ?generation,
        ...?books,
        ...terms.map((term) => caseSensitive ? term : term.toLowerCase()),
        limit,
        offset,
      ],
    );
    return rows
        .map(
          (row) => OfflineSearchVerse(
            book: row['book']! as int,
            chapter: row['chapter']! as int,
            verse: row['verse']! as int,
            bookName: row['book_name']! as String,
            direction: row['direction']! as String,
            verseJson: row['verse_json']! as String,
            text: row['text']! as String,
            normalizedText: row['normalized_text']! as String,
          ),
        )
        .toList(growable: false);
  }

  void _page(int offset, int limit) {
    if (offset < 0 || limit < 1 || limit > 500) {
      throw ArgumentError('Invalid offline page bounds.');
    }
  }

  @override
  Future<List<OfflineInstallAttempt>> listAttempts() async {
    final rows = await database._executor.runSelect(
      'SELECT * FROM offline_attempts ORDER BY updated_at DESC',
      [],
    );
    return rows
        .map(
          (row) => OfflineInstallAttempt(
            resource: OfflineResourceDescriptor.fromJson(
              jsonDecode(row['descriptor']! as String),
            ),
            state: OfflineAttemptState.values.byName(row['state']! as String),
            message: row['message']! as String,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              row['updated_at']! as int,
              isUtc: true,
            ),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<int> usedBytes() => _used(database._executor);
  Future<int> _used(QueryExecutor executor) async {
    final rows = await executor.runSelect(
      'SELECT COALESCE(SUM(byte_count),0) AS bytes FROM offline_generations',
      [],
    );
    return rows.single['bytes']! as int;
  }

  Future<void> _quota(
    QueryExecutor executor,
    int additional,
    int quotaBytes,
  ) async {
    if (quotaBytes < 1 ||
        additional < 0 ||
        await _used(executor) + additional > quotaBytes) {
      throw const OfflineStorageException(
        'The offline storage budget is full. Remove an installed public resource, then retry. Your existing data is unchanged.',
      );
    }
  }

  @override
  Future<void> begin(
    OfflineResourceDescriptor resource,
    String generation, {
    required int quotaBytes,
  }) async {
    await recoverInterrupted();
    await database._transaction((executor) async {
      final existing = await executor.runSelect(
        "SELECT resource_key FROM offline_attempts WHERE resource_key=? AND state='running'",
        [resource.key],
      );
      if (existing.isNotEmpty) {
        throw const OfflineStorageException(
          'This resource is already being installed in another window. Wait for it to finish or retry after two minutes.',
        );
      }
      await _quota(executor, resource.estimatedBytes ?? 0, quotaBytes);
      await executor.runCustom(
        'INSERT INTO offline_generations(generation,resource_key,descriptor,updated_at) VALUES(?,?,?,?)',
        [generation, resource.key, jsonEncode(resource.toJson()), _now],
      );
      await executor.runCustom(
        'INSERT INTO offline_attempts(resource_key,generation,descriptor,state,message,updated_at) VALUES(?,?,?,?,?,?) ON CONFLICT(resource_key) DO UPDATE SET generation=excluded.generation,descriptor=excluded.descriptor,state=excluded.state,message=excluded.message,updated_at=excluded.updated_at',
        [
          resource.key,
          generation,
          jsonEncode(resource.toJson()),
          'running',
          'Preparing download',
          _now,
        ],
      );
    });
  }

  Future<void> _stage(QueryExecutor executor, String generation) async {
    final rows = await executor.runSelect(
      "SELECT resource_key FROM offline_attempts WHERE generation=? AND state='running'",
      [generation],
    );
    if (rows.isEmpty) {
      throw const OfflineStorageException(
        'This installation is no longer active. Retry the resource.',
      );
    }
  }

  @override
  Future<int> writeDocument(
    String generation,
    String path,
    String rawJson, {
    required int quotaBytes,
  }) => writeDocuments(generation, {path: rawJson}, quotaBytes: quotaBytes);

  @override
  Future<int> writeDocuments(
    String generation,
    Map<String, String> documents, {
    required int quotaBytes,
  }) async {
    if (documents.isEmpty || documents.length > 32) {
      throw ArgumentError('Write between 1 and 32 documents per batch.');
    }
    var bytes = 0;
    final sizes = <String, int>{};
    for (final entry in documents.entries) {
      if (entry.key.isEmpty ||
          entry.key.length > 2048 ||
          entry.value.length > 8 * 1024 * 1024) {
        throw ArgumentError('Invalid offline document bounds.');
      }
      final size = utf8.encode(entry.value).length;
      bytes += size;
      sizes[entry.key] = size;
      if (bytes > 8 * 1024 * 1024) {
        throw ArgumentError('Offline document batch exceeds 8 MiB.');
      }
    }
    return database._transaction((executor) async {
      await _stage(executor, generation);
      await _quota(executor, bytes, quotaBytes);
      // Duplicate logical paths indicate an incomplete or malformed build.
      for (final entry in documents.entries) {
        await executor.runCustom(
          'INSERT INTO offline_documents(generation,path,payload,byte_count) VALUES(?,?,?,?)',
          [generation, entry.key, entry.value, sizes[entry.key]],
        );
      }
      await executor.runCustom(
        'UPDATE offline_generations SET byte_count=byte_count+?,updated_at=? WHERE generation=?',
        [bytes, _now, generation],
      );
      return bytes;
    });
  }

  @override
  Future<int> writeSearchVerses(
    String generation,
    List<OfflineSearchVerse> verses, {
    required int quotaBytes,
  }) async {
    if (verses.length > 200) {
      throw ArgumentError('Write at most 200 indexed verses per batch.');
    }
    var bytes = 0;
    final sizes = <int>[];
    for (final verse in verses) {
      if (verse.book < 1 ||
          verse.chapter < 1 ||
          verse.verse < 1 ||
          verse.verseJson.length > 128 * 1024 ||
          verse.text.length > 128 * 1024 ||
          verse.normalizedText != verse.text.toLowerCase()) {
        throw ArgumentError('Invalid offline verse index record.');
      }
      final size =
          utf8.encode(verse.verseJson).length +
          utf8.encode(verse.text).length +
          utf8.encode(verse.normalizedText).length +
          utf8.encode(verse.bookName).length +
          64;
      sizes.add(size);
      bytes += size;
    }
    return database._transaction((executor) async {
      await _stage(executor, generation);
      await _quota(executor, bytes, quotaBytes);
      for (var index = 0; index < verses.length; index++) {
        final verse = verses[index];
        await executor.runCustom(
          'INSERT INTO offline_search(generation,book,chapter,verse,book_name,direction,verse_json,text,normalized_text,byte_count) VALUES(?,?,?,?,?,?,?,?,?,?)',
          [
            generation,
            verse.book,
            verse.chapter,
            verse.verse,
            verse.bookName,
            verse.direction,
            verse.verseJson,
            verse.text,
            verse.normalizedText,
            sizes[index],
          ],
        );
      }
      await executor.runCustom(
        'UPDATE offline_generations SET byte_count=byte_count+?,updated_at=? WHERE generation=?',
        [bytes, _now, generation],
      );
      return bytes;
    });
  }

  @override
  Future<void> updateDescriptor(
    String generation,
    OfflineResourceDescriptor resource,
  ) => database._transaction((executor) async {
    await _stage(executor, generation);
    final rows = await executor.runSelect(
      'SELECT resource_key FROM offline_generations WHERE generation=?',
      [generation],
    );
    if (rows.single['resource_key'] != resource.key) {
      throw ArgumentError('An installer cannot change resource identity.');
    }
    await executor.runCustom(
      'UPDATE offline_generations SET descriptor=?,updated_at=? WHERE generation=?',
      [jsonEncode(resource.toJson()), _now, generation],
    );
    await executor.runCustom(
      'UPDATE offline_attempts SET descriptor=?,updated_at=? WHERE generation=?',
      [jsonEncode(resource.toJson()), _now, generation],
    );
  });

  @override
  Future<void> heartbeat(String generation) => database._executor.runCustom(
    "UPDATE offline_attempts SET updated_at=? WHERE generation=? AND state='running'",
    [_now, generation],
  );

  @override
  Future<void> activate(String generation) => database._transaction((
    executor,
  ) async {
    await _stage(executor, generation);
    final rows = await executor.runSelect(
      'SELECT * FROM offline_generations WHERE generation=?',
      [generation],
    );
    final row = rows.single;
    if ((row['byte_count']! as int) == 0) {
      throw const OfflineStorageException(
        'An empty resource cannot be activated.',
      );
    }
    final key = row['resource_key']! as String;
    await executor.runCustom(
      'INSERT INTO offline_active(resource_key,generation,installed_at) VALUES(?,?,?) ON CONFLICT(resource_key) DO UPDATE SET generation=excluded.generation,installed_at=excluded.installed_at',
      [key, generation, _now],
    );
    await executor.runCustom(
      'DELETE FROM offline_attempts WHERE resource_key=? AND generation=?',
      [key, generation],
    );
    await executor.runCustom(
      'DELETE FROM offline_generations WHERE resource_key=? AND generation<>?',
      [key, generation],
    );
  });

  @override
  Future<void> abandon(
    String generation,
    OfflineAttemptState state,
    String message,
  ) => database._transaction((executor) async {
    if (state == OfflineAttemptState.running) {
      throw ArgumentError('Cannot abandon as running.');
    }
    await executor.runCustom(
      "UPDATE offline_attempts SET state=?,message=?,updated_at=?,generation=NULL WHERE generation=? AND state='running'",
      [state.name, message, _now, generation],
    );
    await executor.runCustom(
      'DELETE FROM offline_generations WHERE generation=? AND generation NOT IN (SELECT generation FROM offline_active)',
      [generation],
    );
  });

  @override
  Future<void> recoverInterrupted() => database._transaction((executor) async {
    final stale = await executor.runSelect(
      "SELECT generation FROM offline_attempts WHERE state='running' AND updated_at<?",
      [_now - _lease.inMilliseconds],
    );
    for (final row in stale) {
      final generation = row['generation'];
      await executor.runCustom(
        "UPDATE offline_attempts SET state='interrupted',message='Download interrupted. Retry to restart safely.',generation=NULL,updated_at=? WHERE generation=?",
        [_now, generation],
      );
      await executor.runCustom(
        'DELETE FROM offline_generations WHERE generation=? AND generation NOT IN (SELECT generation FROM offline_active)',
        [generation],
      );
    }
  });

  @override
  Future<void> remove(String resourceKey) => database._transaction((
    executor,
  ) async {
    final running = await executor.runSelect(
      "SELECT resource_key FROM offline_attempts WHERE resource_key=? AND state='running'",
      [resourceKey],
    );
    if (running.isNotEmpty) {
      throw const OfflineStorageException(
        'Cancel the download before removing this resource.',
      );
    }
    await executor.runCustom(
      'DELETE FROM offline_active WHERE resource_key=?',
      [resourceKey],
    );
    await executor.runCustom(
      'DELETE FROM offline_generations WHERE resource_key=?',
      [resourceKey],
    );
    await executor.runCustom(
      'DELETE FROM offline_attempts WHERE resource_key=?',
      [resourceKey],
    );
  });
}
