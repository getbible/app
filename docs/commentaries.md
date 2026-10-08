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
failure and request lifetime. A newer module/context or dismissal invalidates
late responses. Compatible resource choices are remembered per Bible language;
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
