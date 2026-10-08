# Local data and backup contracts

SQLite stores cache entries, marking groups, markings, notes, and settings. Reader preferences, last position, and daily Scripture are versioned JSON values in settings.

## Identity rules

- Notes: canonical book/chapter/verse; visible across translations.
- Whole-verse markings: canonical book/chapter/verse; visible across translations.
- Selected text: translation + book/chapter/verse + character range.
- Groups: stable string IDs; imported collisions must not overwrite distinct groups.

## Backup import

`BackupData` accepts website-compatible schema versions 1 and 2. The `colors`, `markings`, and optional `notes` arrays are validated before mutation. Imports merge by semantic identity, keep the newer note on canonical conflicts, and create safe IDs when unrelated records collide.

Export emits schema version 2 and website-compatible `value`/`colorId` fields. Flutter-only preferences are additive and may be ignored by the website.

The historical on-device database identifier remains `getbible_life` so an application-name or repository rename never strands existing local reader data.

## Migration procedure

1. Increment the database schema version.
2. Add forward-only transactional SQL.
3. Add a fixture representing every prior schema.
4. Verify data and cache survival after migration.
5. Update this document and the release notes.

## Database schema 2

The schema 1 → 2 migration runs transactionally and keeps the historical `getbible_life` database identity. It adds `fresh_until` and `must_revalidate` to cache bookkeeping, and partitions existing Scripture cache keys under `bible:v2:s1:`. Payloads and source hashes are retained. New Bible v3 model/cache serialization uses `bible:v3:s2:` and respects HTTP cache policy. Notes, marking groups, markings, saved quotes/ranges, preferences and last reading position are not rewritten.

`test/fixtures/database_schema_v1.sql` records the released schema. Migration regressions reopen an actual schema-one SQLite file, verify every private table and legacy cache payload, and prove that a failed migration rolls back columns, keys and schema version. Exact-prefix tests preserve neighbouring numeric IDs and literal wildcard characters.

Selected-text offsets are **UTF-16 code-unit positions, end exclusive**, matching Flutter/Dart selection and the existing website backup contract. Source word/token coordinates are separate metadata and must be mapped onto the unchanged verse text before use. A changed or unavailable quote remains a saved private record; it must not mark unrelated replacement text.
