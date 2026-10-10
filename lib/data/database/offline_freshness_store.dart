part of 'local_database.dart';

Future<void> createOfflineFreshnessTable(QueryExecutor executor) async {
  await executor.runCustom(
    'CREATE TABLE offline_freshness('
    'resource_key TEXT PRIMARY KEY NOT NULL, '
    'checked_generation TEXT, checked_at INTEGER, '
    'last_attempt_at INTEGER, retry_after INTEGER, '
    'CHECK((checked_generation IS NULL) = (checked_at IS NULL)), '
    'CHECK((last_attempt_at IS NULL) = (retry_after IS NULL)), '
    'CHECK(retry_after IS NULL OR retry_after >= last_attempt_at))',
  );
  await executor.runCustom(
    'CREATE TABLE offline_exclusions(resource_key TEXT PRIMARY KEY NOT NULL)',
  );
  await executor.runCustom(
    'CREATE TABLE offline_automatic_catalogues('
    'kind TEXT NOT NULL, source_uri TEXT NOT NULL, descriptors TEXT NOT NULL, '
    'PRIMARY KEY(kind,source_uri))',
  );
}

/// Source-scoped scheduling survives restarts, including failed first downloads.
/// This table contains no user-authored content and is excluded from backups.
final class SqlOfflineFreshnessStore implements OfflineFreshnessStore {
  const SqlOfflineFreshnessStore(this.database);
  final LocalDatabase database;

  @override
  Future<OfflineFreshness?> read(String resourceKey) async {
    final rows = await database._executor.runSelect(
      'SELECT * FROM offline_freshness WHERE resource_key=?',
      [resourceKey],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    DateTime? date(String field) => row[field] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row[field]! as int, isUtc: true);
    return OfflineFreshness(
      checkedGeneration: row['checked_generation'] as String?,
      checkedAt: date('checked_at'),
      lastAttemptAt: date('last_attempt_at'),
      retryAfter: date('retry_after'),
    );
  }

  @override
  Future<void> recordAttempt(
    String resourceKey,
    DateTime attemptedAt,
    DateTime retryAfter,
  ) {
    _validateKey(resourceKey);
    if (retryAfter.isBefore(attemptedAt)) {
      throw ArgumentError('A retry cannot precede its attempt.');
    }
    return database._executor.runCustom(
      'INSERT INTO offline_freshness(resource_key,last_attempt_at,retry_after) '
      'VALUES(?,?,?) ON CONFLICT(resource_key) DO UPDATE SET '
      'last_attempt_at=excluded.last_attempt_at,retry_after=excluded.retry_after',
      [
        resourceKey,
        attemptedAt.toUtc().millisecondsSinceEpoch,
        retryAfter.toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  @override
  Future<void> recordSuccess(
    String resourceKey,
    String generation,
    DateTime checkedAt,
  ) {
    _validateKey(resourceKey);
    if (generation.isEmpty || generation.length > 256) {
      throw ArgumentError('Invalid checked generation.');
    }
    // A late result must not resurrect bookkeeping after clear or certify a
    // replacement generation. The predicate and write are one SQL operation.
    return database._executor.runCustom(
      'INSERT INTO offline_freshness(resource_key,checked_generation,checked_at) '
      'SELECT resource_key,generation,? FROM offline_active '
      'WHERE resource_key=? AND generation=? '
      'ON CONFLICT(resource_key) DO UPDATE SET '
      'checked_generation=excluded.checked_generation,checked_at=excluded.checked_at,'
      'last_attempt_at=NULL,retry_after=NULL',
      [checkedAt.toUtc().millisecondsSinceEpoch, resourceKey, generation],
    );
  }

  @override
  Future<void> recordCatalogueSuccess(String catalogueKey, DateTime checkedAt) {
    _validateKey(catalogueKey);
    if (!catalogueKey.startsWith('catalogue|')) {
      throw ArgumentError('A catalogue check requires a catalogue key.');
    }
    return database._executor.runCustom(
      "INSERT INTO offline_freshness(resource_key,checked_generation,checked_at) "
      "VALUES(?,'catalogue',?) ON CONFLICT(resource_key) DO UPDATE SET "
      'checked_generation=excluded.checked_generation,checked_at=excluded.checked_at,'
      'last_attempt_at=NULL,retry_after=NULL',
      [catalogueKey, checkedAt.toUtc().millisecondsSinceEpoch],
    );
  }

  @override
  Future<Set<String>> readExcludedKeys() async => {
    for (final row in await database._executor.runSelect(
      'SELECT resource_key FROM offline_exclusions',
      [],
    ))
      row['resource_key']! as String,
  };

  @override
  Future<void> setExcluded(String resourceKey, bool excluded) {
    _validateKey(resourceKey);
    return database._executor.runCustom(
      excluded
          ? 'INSERT OR IGNORE INTO offline_exclusions(resource_key) VALUES(?)'
          : 'DELETE FROM offline_exclusions WHERE resource_key=?',
      [resourceKey],
    );
  }

  @override
  Future<List<OfflineResourceDescriptor>> readAutomaticResources() async {
    final rows = await database._executor.runSelect(
      'SELECT kind,source_uri,descriptors FROM offline_automatic_catalogues '
      'ORDER BY kind,source_uri',
      [],
    );
    return [
      for (final row in rows)
        for (final item in requireJsonList(
          jsonDecode(row['descriptors']! as String),
          'automatic catalogue',
        ))
          _scopedDescriptor(
            item,
            row['kind']! as String,
            row['source_uri']! as String,
          ),
    ];
  }

  @override
  Future<void> saveAutomaticResources(
    OfflineResourceKind kind,
    Uri sourceUri,
    List<OfflineResourceDescriptor> resources,
  ) {
    // Validate the complete replacement before touching a previous plan.
    final ids = <String>{};
    for (final resource in resources) {
      if (resource.kind != kind ||
          resource.sourceUri != sourceUri ||
          !ids.add(resource.id)) {
        throw ArgumentError(
          'Automatic catalogue has mixed scopes or duplicate IDs.',
        );
      }
    }
    return database._executor.runCustom(
      'INSERT INTO offline_automatic_catalogues(kind,source_uri,descriptors) '
      'VALUES(?,?,?) ON CONFLICT(kind,source_uri) DO UPDATE SET '
      'descriptors=excluded.descriptors',
      [
        kind.name,
        sourceUri.toString(),
        jsonEncode([for (final resource in resources) resource.toJson()]),
      ],
    );
  }

  OfflineResourceDescriptor _scopedDescriptor(
    Object? value,
    String kind,
    String source,
  ) {
    final resource = OfflineResourceDescriptor.fromJson(value);
    if (resource.kind.name != kind || resource.sourceUri.toString() != source) {
      throw const FormatException(
        'Stored automatic catalogue has an invalid source.',
      );
    }
    return resource;
  }

  @override
  Future<void> remove(String resourceKey) => database._executor.runCustom(
    'DELETE FROM offline_freshness WHERE resource_key=?',
    [resourceKey],
  );

  @override
  Future<void> clear() =>
      database._executor.runCustom('DELETE FROM offline_freshness');

  void _validateKey(String key) {
    if (key.isEmpty || key.length > 4096) {
      throw ArgumentError('Invalid offline resource key.');
    }
  }
}
