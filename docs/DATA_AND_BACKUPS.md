# Local data and backup contracts

SQLite stores cache entries, marking groups, markings, notes, and settings. Reader preferences, last position, and daily Scripture are versioned JSON values in settings.

## Identity rules

- Notes: canonical book/chapter/verse; visible across translations.
- Whole-verse markings: canonical book/chapter/verse, group and personal/shared origin; visible across translations. A verse may belong to several groups, and a linked group may contain independent personal and shared memberships for the same verse.
- Selected text: translation + book/chapter/verse + character range.
- Groups: stable string IDs; imported collisions must not overwrite distinct groups.

## Backup import

`BackupData` accepts website-compatible schema versions 1 and 2. The `colors`, `markings`, and optional `notes` arrays are validated before mutation. Imports merge by semantic identity, keep the newer note on canonical conflicts, and create safe IDs when unrelated records collide.

Export emits schema version 2 and website-compatible `value`/`colorId` fields. Flutter-only preferences are additive and may be ignored by the website.

Current website groups and whole-verse markings may contain
`source: {"type": "shared-bookmark", "topicId": "faith"}`. That typed source
round-trips through import, SQLite and export; editing a group's local label or
color does not remove it. A group's source never implies that all its markings
are shared. Personal membership in a linked group remains independent, and
identical labels/colors do not merge groups with different source identities.
Distinct group IDs also remain distinct when their editable names/colors match;
repeated import reuses an identical earlier collision-renamed group.
Invalid source objects or shared selected-text ranges reject the complete backup.

Older website imports are recognized only by the exact deterministic marking ID
`getbible-topic:<topic>:<book>:<chapter>:<verse>` in its matching
`getbible-topic:<topic>` group. Backup merging captures that provenance before
collision renaming or group remapping. An arbitrary personal marking in that
group remains personal. Ordinary older backups with no sources still import.

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

## Database schema 3

The forward schema 1/2 → 3 migration adds local notebooks, ordered blocks and independent durable draft journals. Canonical notes, their IDs and timestamps, private markings, preferences and cached Scripture remain intact. Saves and document reads are atomic; optimistic base revisions prevent overwriting newer local edits. Independent editor journals retain failed drafts for restart and explicit conflict copying. Both released schemas have SQLite fixtures, rollback checks and actual file-reopen tests. See [Notebooks](notebooks.md).

Website-compatible backups still contain verse notes and markings only. Notebook export/import belongs to step 12 and is explicitly disclosed in the notebook UI. Existing reader-data replacement/reset preserves notebook tables, and cache cleanup never deletes private notebooks. Public-topic copying uses a separate additive transaction with scoped provenance and duplicate checks; it does not replace private groups.

## Database schema 4

The forward schema 1/2/3 → 4 migration adds nullable `source_json` columns to
`marking_groups` and `markings` in the existing migration transaction. It does
not rewrite private IDs, group names/colors, quotes, ranges, timestamps, notes,
notebooks, draft journals, preferences or cached Scripture. A failed upgrade
rolls back the added columns and schema version. The schema-3 fixture records
the released structure; earlier schema fixtures and migration tests remain.

Whole-verse assignment now adds one personal membership per group without
deleting another group's membership or an independent shared origin. Repeating
the same assignment is idempotent. The verse menu names the personal group to
remove and offers an explicitly labelled all-personal removal when there are
multiple groups. Shared origins survive these personal actions and remain
individually removable in saved markings. A personal whole-verse color takes
precedence over a later shared import in both line and paragraph rendering.

This preserves the current website's backup provenance and whole-verse membership
contract. Automatic global catalogue/group reconciliation, its unified management
UI, exact per-topic ranged removal, notebook portability and Flutter's scoped
private-copy/follow preferences remain separate parity work. Flutter's explicit
private topic copies remain private; they are not reclassified as live shared
memberships merely from a group label.

`test/bookmark_preservation_test.dart` exercises the current web v2 fixture,
source validation, collisions, legacy remapping, SQLite restart, schema-3 upgrade
and rollback, independent membership removal, personal color precedence and the
actual reader context menu. The fixture follows `lib/markings.ts` and
`lib/shared-bookmarks.ts` at web commit
`22172efd7ed46722c8f0da42b58222c8f1bc2360`.
