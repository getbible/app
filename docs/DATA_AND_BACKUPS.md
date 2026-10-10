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
a free incoming ID is kept before considering any collision-like suffix.
When the original ID is occupied, repeated import reuses an identical
`-imported-N` candidate. This legacy collision convention is not public-topic
provenance; only the explicit source or exact historical source ID establishes
a shared membership.
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

Website-compatible backups retain the v1/v2 verse-note and marking contract. Complete private backups use the separate versioned envelope described below and include notebooks and durable journals. Existing reader-data replacement/reset preserves notebook tables, and cache cleanup never deletes private notebooks. Public-topic copying uses a separate additive transaction with scoped provenance and duplicate checks; it does not replace private groups.

## Database schema 4

The forward schema 1/2/3 → 4 migration adds nullable `source_json` columns to
`marking_groups` and `markings` in the existing migration transaction. It does
not rewrite private IDs, group names/colors, quotes, ranges, timestamps, notes,
notebooks, draft journals, preferences or cached Scripture. A failed upgrade
rolls back the added columns and schema version. The schema-3 fixture records
the released structure; earlier schema fixtures and migration tests remain.

Whole-verse assignment now adds one personal membership per group without
deleting another group's membership or an independent shared origin. Repeating
the same assignment is idempotent, including overlapping requests. SQLite checks
membership identities inside the same transaction as the writes; an ID collision
with an unrelated record rolls back the complete batch. Selected-text identity
includes its original quote, so re-marking revised source text retains both the
previous private record and the newly selected quotation. The verse menu names the personal group to
remove and offers an explicitly labelled all-personal removal when there are
multiple groups. Shared origins survive these personal actions and remain
individually removable in saved markings. A personal whole-verse color takes
precedence over a later shared import in both line and paragraph rendering.
Menu and group-picker choices retain their opening passage/chapter ownership;
navigation while either route is open cannot apply its old action to another
chapter. Imported group IDs are kept separate from reserved menu actions.

Schema 4 established this provenance and membership contract. The current unified
bookmark catalog reconciliation and contextual assignment UI extend it using the
same columns; their transaction is described below. Explicit private topic copies
remain personal memberships and are not reclassified as shared from a label.

`test/bookmark_preservation_test.dart` exercises the current web v2 fixture,
source validation, collisions, legacy remapping, SQLite restart, schema-3 upgrade
and rollback, independent membership removal, personal color precedence and the
actual reader context menu. The fixture follows `lib/markings.ts` and
`lib/shared-bookmarks.ts` at web commit
`22172efd7ed46722c8f0da42b58222c8f1bc2360`.


## Complete private-data portability (step 12)

The **Complete private backup** JSON envelope has
`format: "getbible-private-backup"` and `version: 1`. Its `reader` member is the
website v2 reader contract with additional group order/starter/timestamp fields
retained inside this complete envelope. Separate `notebooks`, `drafts` and `settings`
arrays retain notebook/block identities, ordered text, saved quotations and
attribution, creation/update times, document revisions, journal owner and base
revision, reading position, reader preferences, selected notebook, remembered
Study resources, topic Follow/Hide, the six recent bookmark topics and scoped
private-copy provenance.

A website-compatible export remains available and is labelled as excluding
notebooks/drafts and complete app settings. Both website schema versions 1 and 2
remain accepted. The complete app envelope is not represented as a format the
reference website can restore. Human-readable Markdown is an export for reading
and sharing, not a replacement for the complete restorable JSON backup.

Files are limited to 64 MiB UTF-8 and 100,000 combined private records, including
notebook blocks. Existing per-document limits also apply. The full file is
parsed and validated before any storage mutation. SQLite count and raw-byte
preflight checks also bound locally accumulated data before snapshot bodies are
loaded; the final JSON encoder checks the exact serialized byte limit. Unknown complete schema
versions, duplicate identities, invalid ownership, unsupported private setting
keys and dangling group/notebook references are rejected. Public cache rows,
daily Scripture, installation data and downloaded public corpora are excluded.
No backup is uploaded to a GetBible service.

Opening a backup presents its contents before an explicit **Merge backup**.
The controller first makes open notebook edits durable; a failed journal write
prevents the operation. A snapshot reads all private tables in one transaction.
Import re-reads current private state and merges all changes in one transaction;
a late write failure rolls back reader annotations, notebooks, journals,
preferences and internal import identity bookkeeping together.

Existing group, marking and canonical-note merge rules are retained. On an
installation containing only unchanged bundled starter groups and no private
annotations/documents, complete restore retains the exported group order and
timestamps exactly. Merging into an existing private collection keeps its local
ordering and appends genuinely new groups. Incoming
active-group preferences, recent bookmark topics and private-copy destinations
follow collision remaps.
Different notebook contents with the same ID become a separate document with
collision-safe notebook/block IDs, preserving both bodies and original times.
A locally edited imported copy is not overwritten by repeating the same import.
Incoming journals never activate a document during import: distinct owners and
conflicting journal bodies remain recoverable independently, with their base
revisions. Repeated imports reuse remembered destinations and do not duplicate
unchanged documents or journals. A consumed journal receipt prevents repeating
a backup from resurrecting an already recovered draft while its document still
exists; deleting the entire document permits a deliberate later restoration.

Settings restore when absent or newer; current settings win equal timestamps.
If both devices have different private copy groups for the same public topic,
both groups survive. The current destination remains active and the imported
provenance is retained as a typed alternate in the complete backup. Removing
public resources has no effect on these private copies or backup history.

`test/private_portability_test.dart` exercises an actual file-backed SQLite
export/restore/reopen, multiple retained drafts, ID collisions, reimport after
local edits, legacy imports, original Unicode ranges, provenance remapping,
validation-before-mutation and late-write rollback. Native picker/save/share
execution is verified separately from the storage contract.

## Database schema 5

The forward schema 1/2/3/4 → 5 migration transaction adds `offline_generations`,
`offline_active`, `offline_documents`, `offline_search` and `offline_attempts`.
Every existing private/cache table and the historical database identity remain
unchanged. The released schema-4 fixture is
`test/fixtures/database_schema_v4.sql`; `offline_resource_store_test.dart`
verifies migration with private notes and source provenance. Ordinary caches,
complete private backups and explicit installed-resource removal remain separate
operations with separate ownership.


## Unified bookmark reconciliation (step 16)

Opening the bookmark list or contextual picker loads API topic metadata lazily.
This does not create any global verse memberships. Only explicit global download
adds those records. A fresh database's unchanged bundled fallback groups are
replaced by API groups; an existing private collection undergoes conservative
identity reconciliation instead.

Explicit source IDs outrank labels. Unscoped historical sources belong to the
official Bookmarks v1 service; an optional `sourceScope` source member identifies
a configured alternate provider. Semantic global identity includes that provider
and topic as well as canonical coordinate and group. A renamed linked group cannot
be matched to another topic by name, and a different provider cannot absorb it.
Canonical/localized names and aliases use Unicode NFKD matching. Ambiguous matches
and independent personal groups sharing a label are preserved without guessing.

When an old imported public group is absorbed into one unambiguous local group,
the local group's ID, name, color, ordering and timestamp survive. Every personal
marking ID, timestamp, quote and original UTF-16 range survives. Legacy source
inference happens before remapping; personal and global records at the same verse
remain independent. Only redundant global semantic memberships are collapsed.
The catalog transaction remaps active/recent group choices and private-copy
destinations together with groups and memberships. It does not replace notes,
notebooks, notebook blocks or independent draft journals. A late SQL failure rolls
back every reconciliation/download write.

Recent choices use the existing settings table under `bookmarks:v1:recent`, a
validated list of at most six group IDs. Complete backup import remaps those IDs
with its group collision map. This additive setting and source metadata use the
existing schema 5 structure; there is no SQL schema version change in step 16.

Global removal targets only explicit/historical global origins for the selected
provider, optionally one topic. Personal origin removal targets one group and
exact verse/range. Neither action deletes topic metadata, personal work in other
origins, notes or notebooks. Saved global memberships are part of private reader
backups, while a separately installed public-topic corpus remains excluded.
See [Unified bookmarks and public topics](public-topics.md) for operation limits,
UI ownership and the automated coverage added for these behaviors.
