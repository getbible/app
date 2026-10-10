# Unified bookmarks and public topics

**Bookmarks** is one native list for personal topics and published GetBible topics.
The verse and selected-text bookmark menus use that same list. A group can hold
both personal memberships and downloaded global memberships at the same verse;
their origins remain separate in storage. A visible whole-verse row combines
those origins and prefers the user's saved quotation. Selected-text rows retain
their translation and exact original UTF-16 range.

## Catalog metadata and migration

Opening Bookmarks or its contextual assignment menu discovers the public
[GetBible Bookmarks v1 API](https://getbible.net/api/bookmarks/v1/) catalog and
localized topic-name documents. This is lazy metadata loading: it does not fetch
verse membership documents, download Scripture, or install an offline corpus.
Locale requests have a concurrency limit of four. Revision checks surround the
metadata read; a failed or changing catalog leaves saved private groups readable.
On a pristine installation, unchanged bundled fallback groups are replaced by
actual API topic metadata without assigning any verses.

`UnifiedBookmarksController` owns public request cancellation, progress, recent
topic choices and operation lifetime. `UnifiedBookmarksRepository` is the domain
boundary. `SqlUnifiedBookmarksRepository` applies the pure reconciliation plan
to the latest SQLite snapshot inside one transaction. Widgets perform no HTTP,
raw JSON parsing or SQL. Shutdown cancels and drains public requests and pending
local writes before the database closes.

Matching uses an explicit source topic identity first, then a historical stable
ID, then an unambiguous canonical/localized name or alias. Label comparison uses
the reference app's Unicode NFKD, combining-mark removal, lowercase and
letter/number normalization; the pinned `unorm_dart` package supplies Unicode
normalization. This transformation is never applied to Scripture or saved quotes.
An explicit different topic ID or provider scope cannot be overridden by a label.
Ambiguous aliases and multiple independent personal groups with the same label
stay separate. The app does not guess which private identity to discard.

An earlier imported public group can be absorbed into one unambiguous existing
private group. Its surviving local ID, name, color, order and timestamp are kept.
Marking IDs, original timestamps, quotes and selected ranges remain unchanged;
only group membership references and missing historical origin metadata change.
Identical legacy global memberships may be collapsed; personal records are never
collapsed by catalog reconciliation. Active and recent group settings, plus
independent copy destinations, follow the same remap in the transaction. Notes,
notebooks and unactivated draft journals are not rewritten. Repeating migration
is idempotent. This is a data reconciliation using schema 5's existing columns,
not an in-place change to a released SQL schema.

## Explicit download and removal

Expand **Global bookmarks** in the unified list or a topic to access public
download, removal, retry and status controls. Keeping this section collapsed
initially leaves private search and saved topics reachable on short screens with
large text, including when the public service is unavailable.

**Download all global bookmarks** and **Download this topic's global bookmarks**
fetch public coordinates only after the user requests them. Per-topic reads run
in bounded batches and the complete result is validated before one additive
transaction. A catalog revision change, malformed response, cancellation or
storage failure cannot commit a partial collection. Existing global semantic
memberships are reused, including across translations; a colliding record ID
receives a free ID without replacing the occupied personal record.

**Remove global bookmarks** requires confirmation and removes only downloaded
memberships belonging to the current public provider, optionally narrowed to one
topic. Names, colors, personal memberships, notes and notebooks remain. This
operation is independent of uninstalling a public API corpus in **Set up offline
use**. The contextual menu separately offers **Remove personal bookmark** and
**Remove global bookmark**, each for the selected group and exact verse/range.
Selecting another topic adds a personal membership without deleting other topics.
The six most recently selected topics are persisted and shown first in the picker.

Public origins without a provider field are the historical official GetBible
source. Custom providers use the additive `sourceScope` member in source JSON.
Matching, deduplication and bulk removal respect that scope. Renaming a topic or
editing its color never removes its source identity or turns personal memberships
into global ones.

## Study browsing and independent copies

The Study Topics workspace still supports on-demand browsing, Follow/Hide,
chapter reverse associations and selected-Bible reference previews. Follow and
Hide are local settings keyed by service root and stable public topic ID. They do
not assign verses. Study offers global download into the unified list and an
**Open saved topic** action. Public coordinates cover books 1–66; this dataset
limit does not restrict Bible v3 navigation or extended-book reading.

The additional **Copy to my markings** action remains available for an explicitly
independent private copy. Confirmation previews its destination and new/already
present counts. Copied memberships are personal, have collision-safe identities,
and are never removed by global-bookmark cleanup. Repeated copies add only missing
canonical coordinates; public updates do not synchronize or delete private copies.
Scoped provenance keeps the copy destination stable through restart and backup.

Complete private backups contain saved personal/global memberships, source fields,
recent topics, reader preferences, Follow/Hide and private-copy provenance.
Website-compatible v2 exports retain supported source fields and reader data,
but omit the complete app settings and notebooks. Public cached/installed API
corpora are separate from these saved memberships and are excluded from private
backups. Removing a public corpus does not remove saved bookmarks of either origin.

## Complete offline public topics

**Set up offline use** explicitly downloads `all.json` with `index.json` and
`checksums.json`. The index checksum must equal the exact full-body SHA-256, and
requested paths must retain their manifest hashes through final verification.
Workers validate the dataset and derive summaries, individual topics, localized
name maps and chapter reverse associations before atomic activation. Partial
locale documents retain English fallback; unknown identities stay unavailable.

`InstalledPublicTopicsRepository` serves that complete source-scoped snapshot
without HTTP after restart. Its metadata and per-topic reads also support unified
bookmark reconciliation/download without network access. Public topics contain
coordinates, not Scripture; previews still require the chosen Bible to be
available. Resource removal preserves saved memberships and independent copies.

## Verification

`test/unified_bookmarks_test.dart` covers Unicode/name/alias/source matching,
ambiguous private identities, mixed origins, idempotent SQL reconciliation and
download, active/recent remaps, actual SQLite reopen, late-write rollback,
malformed batches, request cancellation and unchanged notebook/draft data.
`test/bookmark_assignment_menu_test.dart` exercises independent origin removal
and a narrow contextual surface at 200% text. Existing preservation, public-topic,
private-backup and installed-Study suites cover their respective boundaries.
Test execution results are recorded in [TESTING.md](TESTING.md); physical-device
selection and accessibility acceptance remain separate from automated coverage.
