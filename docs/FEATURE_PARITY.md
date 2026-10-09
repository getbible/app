# Feature-parity ledger

Status meanings: **Implemented core** has native implementation and focused tests;
**Partial** has a known product/workflow gap; **Missing** has no equivalent
workflow; **Pending verification** requires platform/device confirmation. An
implemented core is not automatically equivalent to the current reference app.

The current comparison is the [9 October 2026 source audit](PARITY_AUDIT_2026-10.md)
against web commit `22172efd7ed46722c8f0da42b58222c8f1bc2360`. Its unified bookmark
model supersedes the July baseline. Complete parity remains unfinished.

| Area | Status | Implementation / remaining gate |
|---|---|---|
| Typed Bible v3 and dynamic indexes | Implemented core | `GetBibleApiClient`, lossless source models and `CachedBibleRepository`; discovered extended book IDs, introduction-only content, exact-byte SHA activation and versioned legacy fallback. Live/device verification remains separate. |
| Query v3 reference previews | Implemented core | Selected-translation lookup, atomic bounded batches, native rich Scripture, Copy, exact-verse Open, bounded history and cancellable routes shared by dictionaries, commentaries, topics and notebook citations. Device/browser runtime remains a separate gate. |
| SQLite notes/markings/preferences/cache | Implemented | `LocalDatabase` and SQL repositories |
| SHA verification and offline chapter fallback | Implemented | Three freshness states shown by reader |
| Native line/paragraph reader | Implemented | `ReaderScreen`; no WebView |
| Rich Scripture and original-text range mapping | Implemented core | Source headings/paragraphs, titles/introductions, reversible source styling and layered private markings render natively. UTF-16 end-exclusive ranges and exact quotes preserve selection/Copy; mismatched saved quotes stay stored without coloring replacement text. Rich/plain, Unicode/RTL and 200% text suites exist; device/screen-reader QA remains required. |
| Translation/book/chapter selection | Implemented | Dynamic selectors |
| Last passage persistence | Implemented core | Saved position and reader centering exist; full target lifecycle/restore validation remains. |
| Daily Scripture | Implemented correction; pending verification | Query alias resolution, complete daily verse selection, truthful unavailable outcomes and retry ownership now have regression cases; see the current testing evidence. |
| Swipe and cross-book navigation | Implemented core | Shared cross-book turn operation, horizontal swipe, Alt+arrow shortcuts, arrows/mobile row, and tested deliberate double-boundary intent; device gesture QA remains |
| Deep links/shareable links | Partial | Parser exists; GoRouter/platform association needs integration tests |
| RTL and appearance modes | Implemented | Device selection behavior still requires QA |
| Contextual selection/bookmark menu | Partial | Native Copy, markings, notes and Study entry points exist. The current web assignment menu, separate displayed origins, recent topics and return-to-verse path need full native equivalents. |
| Whole/text markings and memberships | Partial | Canonical whole verses, UTF-16 selections, overlap rendering and private group management exist. Typed source provenance, additive whole-verse membership, scoped personal removal and schema-4 migration are added with regression cases. The full unified list/menu/migration remains missing; see the October audit. |
| Unified global/personal topic list | Missing | Flutter still separates public Topics and My markings; API-based defaults, automatic legacy group reconciliation, G badges and origin-aware global-download management are not implemented. |
| Inline notes | Implemented core | Add/edit/delete editor opens under its verse and saved note folds inline; keyboard-shortcut and full widget journey tests remain |
| Online Search v3 | Implemented core; interaction differs | Advanced filters, ranked pagination, complete references, cancellation/cooldown and exact-verse opening exist. Flutter requires submission after edits; the web searches with a debounce. Installed offline search remains step 14 and is not supplied by the current website. |
| Adaptive Study workspace | Implemented core | Captured word/phrase/verse/chapter context, responsive side panel/sheet, keyboard/Escape, native selection precedence and six usable tabs. Large-text and nested-dialog regressions complement composed journeys; device/screen-reader QA remains. |
| Dictionaries and commentaries | Partial | Typed on-demand indexes/coverage/citations work. The current web cross-resource chooser of confirmed definitions is absent. Complete offline installation remains step 15. |
| Public topic browsing and private copies | Implemented core; workflow differs | Lazy browsing, local Follow/Hide and explicit private copies work. They are different from the reference's unified global-download workflow. |
| Source annotations and references | Partial | Rich source data and styled text survive; the web's below-verse source-note/citation controls and red Jesus quotation presentation are not reproduced. |
| Personal study/sermon notebooks | Implemented core | Ordered private blocks and references, durable draft journals, revision conflicts, lifecycle flush and schema 3 migrations. Notebook import/export remains step 12. |
| Website-compatible backups | Partial | Legacy v1/v2 validation/merge exists; current shared-bookmark provenance now has a shared fixture and preservation regressions. Complete native file import/export and notebook/journal/Study portability remain step 12. |
| Markdown generation | Partial | Native preview and clipboard exist; save/download and operating-system sharing are incomplete. |
| Complete website localization | Partial | Runtime loading and 69 bundled packs exist, but only some widgets use them. At audit time packs contain 199 messages versus 218 in the reference; the current test checks internal consistency only. |
| Approved GetBible branding | Implemented | Supplied artwork is installed for Android, iOS, macOS, Windows, Linux, web, splash, and the reader header; CI verifies exact hashes |
| Accessibility | Partial | Safe area, semantics, scaling foundations; full focus/screen-reader audit remains |
| CI and versioned packages | Pending target evidence | See [Testing](TESTING.md) and [Deployment](DEPLOYMENT.md) for the current supported-host matrix, downloadable packages and actual run evidence. Passing one target is not validation of another. |
| Signed store distribution | External | Requires Apple/Google credentials and store review |

“Ready for distribution” requires every applicable Partial/Missing row to be resolved, automated checks and supported-host builds to pass, versioned packages to be verified, and the target manual QA matrix to be signed off. Mobile, desktop and browser are separate validation targets.

## Search v3 increment

Online Search now uses service-native paginated requests and preserves ranked original-text results. Filters, reference responses, revision consistency, cancellation, rate limits and native narrow RTL/200% layouts have 29 focused automated checks. See [Search v3](search-v3.md). Whole-translation search remains an explicit offline service, rather than the online reader path. Composed reader and platform evidence is recorded with the completed Study increment.

## On-demand dictionary increment

Typed dictionary lookup now discovers catalogues, metadata, published indexes and exact entries on demand. Native lookup preserves original words and lexical metadata, duplicate definitions, source attribution and bounded history. Eighteen focused tests and nineteen live-schema-validated fixtures cover this resource boundary; the adaptive reader entry points are composed in the Study increment. See [Dictionaries](dictionaries.md).

## Commentary resource increment

Native commentary reading requests only discovered coverage and the chosen chapter. It distinguishes introductions from Scripture, includes earlier-anchored ranges and multiple source entries, and preserves source OSIS, attribution and v2 citation provenance. Fourteen focused checks cover sparse availability, request ownership, dismissal, preferences and RTL/200% native layouts; six resource fixtures match the current live contract. See [Commentaries](commentaries.md).

## Local notebook storage increment

Independent titled study/sermon notebooks complement canonical inline verse notes. Ordered blocks, captured quotations, serialized autosave, durable editor journals and explicit conflict recovery preserve private content. Twenty-eight notebook, native-input and migration checks cover schema 1/2 upgrades, actual SQLite restart, simultaneous local editors and 200% RTL editing. Website-compatible backups continue to omit notebooks until step 12; the UI states this boundary. See [Notebooks](notebooks.md).

## Public topic increment

Read-only public topic discovery, sparse reverse associations and locale fallback remain separate from private starter marking groups. Follow/Hide save scoped local choices; only explicit previewed Copy creates an independent private UUID group and additive canonical markings. Fifteen focused tests cover published identities, missing selected-Bible coordinates, collisions, repeat copies, source revisions, private-data preservation and native 200% layouts. Seven resource fixtures match the live Bookmarks contract. See [Public topics](public-topics.md).

## Current reference alignment

The web application has changed since the first parity implementation. Its latest
bookmark topics share one list, can have both personal and global membership at
the same coordinate, and automatically reconcile older groups using stable source
identity and unambiguous names/aliases/locales. Flutter's independent private
copy must not be relabelled as that workflow. The [October audit](PARITY_AUDIT_2026-10.md)
records concrete source paths, preservation risks, the 33 executed reference
bookmark tests, remaining UX work and the order of implementation.

Build/package fixes do not close these product gaps. Steps 12–15 continue to own
complete private-data portability and installed offline resources; step 16 covers
complete localization and integrated parity/accessibility, and step 17 validates
supported hosts/devices and distribution. Specific correctness bugs, such as
losing a bookmark's origin during a backup round trip, must be corrected before
those larger increments are declared finished.
