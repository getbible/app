# Contextual commentaries

The Study commentary tab browses public Commentary v1 resources online. It reads
the discovered catalogue, the selected resource's metadata and sparse book/chapter
coverage, then one covered chapter. It requests no verse endpoint, whole book or
whole commentary. Opening this tab does not change Scripture, install a resource,
or write private annotations.

`CommentaryRepository` defines the typed boundary. `ApiCommentaryRepository` uses
the shared transport/cache/cancellation policy and strict `CommentaryAdapter`
parsers. Invalid documents evict their own transport snapshot so Retry can fetch
a corrected document. Module identities are encoded as individual path segments;
book/chapter requests follow the commentary's published coverage. Commentary's
83-book coordinates do not restrict Bible v3's independently discovered books.

`CommentaryController` owns the captured Study context, active module, loading,
failure and request lifetime. A newer module/context, tab change, panel replacement
or dismissal invalidates late responses. Widget teardown cancels synchronously
without notifying a tree that is being rebuilt. Compatible resource choices are
remembered per Bible language;
preference writes are ordered, and a storage failure is visible without blocking
the resource. A language mismatch requires explicit selection and is labelled
with the actual source language. Missing coverage and a covered chapter with no
matching verse are distinct successful outcomes. The controller never switches
to another commentary or chapter to fill a gap.

Chapter mode includes introductions and all source entries in their original
order. Verse mode includes every entry whose published `verses` contains the
selected verse, or whose single `verse` matches it. A range anchored at an earlier
verse therefore remains visible. Chapter 0 means a book introduction; verse 0
means a chapter introduction. Neither becomes a Scripture coordinate. Entry text,
OSIS, full range and structured references remain intact in immutable models.
Consecutive identical quotations share one displayed text block while retaining
every ordered source anchor, coverage and citation. Distinct and nonconsecutive
comments remain separate.

`CommentaryPanel` renders native selectable plain text, including paragraph breaks,
with resource attribution and citation buttons. It never renders source text as
HTML. Citation buttons reuse `StudyCitation` and the shared Query preview in the
selected Bible. Explicit verse coordinates use discovered selected-Bible book
names; whole-chapter references retain the original source citation. Metadata's
`getbible-v2` reference resolution and source versification remain visible and
unchanged. A preview request does not claim automatic versification conversion;
unavailable coordinates/spellings produce the shared truthful error. Introduction
references have no invented Scripture preview.

## Verification

`test/commentary_test.dart` covers sparse books/chapters; chapter/verse zero; ranges
anchored earlier; multiple comments; missing references; repeated cross-chapter
quotations; source ordering, OSIS and v2 provenance; module/request dismissal
races; compatible choice persistence and save failure; malformed fresh-cache
retry; endpoint paths; plain text/citation widgets; and narrow RTL presentation
at 200% text scaling.

The six documents in `test/fixtures/commentary_v1.json` were independently checked
against the current live Commentary v1 OpenAPI schemas on 2026-10-08. The adapters
also parsed live Abbott metadata, 27-book coverage and John 3 (17 entries). These
checks establish contract compatibility, not physical-device or store readiness.
The composed Study/reader journey and platform builds are recorded separately.

## Installed commentary modules

An explicit **Set up offline use** installation downloads the published whole
`{commentary}.json`, its metadata and sparse coverage, and verifies every exact
byte digest against `hashes.json` before and after the operation. Book/chapter
identities, language, names and entry totals must agree throughout the nested
module. Native and browser workers build chapter indexes in bounded batches;
activation occurs only after complete validation. A failed update leaves the
previous installed snapshot intact.

`InstalledCommentaryRepository` preserves the online repository contract.
Installed resources open after restart without fetching their catalogue or
chapters. The saved discovery also retains online-only choices. An installed
chapter preserves its entire original source document, including chapter/verse
zero introductions, overlapping ranges, repeated anchors, structured references,
plain text and v2 source provenance. No conversion into a verse-keyed map drops
source entries. The panel identifies installed versus online resources and
provides **Set up offline use**. Scripture preview still requires the selected
Bible's Query result or complete installed Bible; installing commentary does
not imply installing Scripture.

Complete-module and failed-update regressions are in
`test/installed_study_test.dart`. Native host and browser release checks remain
necessary in addition to these source-contract tests.

On 9 October 2026 the complete-module processor also validated the generated
source repository's current `spurious.json` against its real metadata and sparse
coverage: 24,688 bytes produced 82 local documents. This independently checks
the nested whole-book/chapter format used by installation. Source:
[`getbible/commentaries`](https://github.com/getbible/commentaries/tree/main/v1).
