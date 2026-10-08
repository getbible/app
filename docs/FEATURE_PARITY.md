# Feature-parity ledger

Status meanings: **Implemented** exists in source; **Partial** needs remaining UX/integration work; **Pending verification** requires platform/device confirmation.

| Area | Status | Implementation / remaining gate |
|---|---|---|
| Typed Bible v3 and dynamic indexes | Implemented core | `GetBibleApiClient`, lossless source models and `CachedBibleRepository`; discovered extended book IDs, introduction-only content, exact-byte SHA activation and versioned legacy fallback. Live/device verification remains separate. |
| Query v3 reference previews | Implemented core | Selected-translation lookup, atomic bounded batches, native rich Scripture, Copy, exact-verse Open, bounded history and cancellable routes shared by dictionaries, commentaries, topics and notebook citations. Device/browser runtime remains a separate gate. |
| SQLite notes/markings/preferences/cache | Implemented | `LocalDatabase` and SQL repositories |
| SHA verification and offline chapter fallback | Implemented | Three freshness states shown by reader |
| Native line/paragraph reader | Implemented | `ReaderScreen`; no WebView |
| Rich Scripture and original-text range mapping | Implemented core | Source headings/paragraphs, titles/introductions, reversible source styling and layered private markings render natively. UTF-16 end-exclusive ranges and exact quotes preserve selection/Copy; mismatched saved quotes stay stored without coloring replacement text. Rich/plain, Unicode/RTL and 200% text suites exist; device/screen-reader QA remains required. |
| Translation/book/chapter selection | Implemented | Dynamic selectors |
| Last passage persistence | Implemented | Exact verse restoration/centering needs expanded widget integration |
| Swipe and cross-book navigation | Implemented core | Shared cross-book turn operation, horizontal swipe, Alt+arrow shortcuts, arrows/mobile row, and tested deliberate double-boundary intent; device gesture QA remains |
| Deep links/shareable links | Partial | Parser exists; GoRouter/platform association needs integration tests |
| RTL and appearance modes | Implemented | Device selection behavior still requires QA |
| Contextual selection toolbar | Partial | Verse-number and native selected-text menus expose the active group, searchable compact all-group palette, note/removal actions, and preserve native copy controls; exact overlay-positioning widget tests remain |
| Whole/text markings and overlap rules | Implemented core | Whole-verse recolor/removal, selected-range marking/removal, overlap rendering, active group memory, searchable Study card grid, per-marking open/delete, and add/edit/recolor/delete group UI exist; full journey tests and backup UI remain |
| Inline notes | Implemented core | Add/edit/delete editor opens under its verse and saved note folds inline; keyboard-shortcut and full widget journey tests remain |
| Online Search v3 | Implemented core | Native advanced filters, ranked paginated results, complete reference responses, cancellation, revision/cooldown handling, original-text arrival emphasis and exact-verse navigation. Complete installed offline search remains step 14. |
| Adaptive Study workspace | Implemented core | Captured word/phrase/verse/chapter context, responsive side panel/sheet, keyboard/Escape, native selection precedence and six usable tabs. Large-text and nested-dialog regressions complement composed journeys; device/screen-reader QA remains. |
| Dictionaries, commentaries and public topics | Implemented core | Typed on-demand discovery, published indexes/coverage/citations and explicit additive private topic copying. Complete offline installations remain step 15. |
| Personal study/sermon notebooks | Implemented core | Ordered private blocks and references, durable draft journals, revision conflicts, lifecycle flush and schema 3 migrations. Notebook import/export remains step 12. |
| Website-compatible backups | Implemented core | Model validation/merge exists; native file picker/share UI remains |
| Markdown generation | Implemented core | Native copy/share/save UI remains |
| Complete website localization | Partial | All 69 compact website locale packs are mirrored and contract-tested; Flutter runtime message loading and full widget adoption remain |
| Approved GetBible branding | Implemented | Supplied artwork is installed for Android, iOS, macOS, Windows, Linux, web, splash, and the reader header; CI verifies exact hashes |
| Accessibility | Partial | Safe area, semantics, scaling foundations; full focus/screen-reader audit remains |
| CI | Implemented | Format, analyze, tests, Android debug artifact |
| Signed store distribution | External | Requires Apple/Google credentials and store review |

This ledger is intentionally candid. “Ready for distribution” means every Partial row applicable to mobile is completed, automated checks pass, release artifacts build, and the manual QA matrix is signed off.

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
