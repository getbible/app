# Feature-parity ledger

Status meanings: **Implemented core** has native implementation and focused tests;
**Partial** has a known product/workflow gap; **Missing** has no equivalent
workflow; **Pending verification** requires platform/device confirmation. An
implemented core is not automatically equivalent to the current reference app.

The integrated candidate compares against web commit
`098eeaa06c75efde4a3c75a9984d66ac987add30` (10 October 2026). The
[9 October source audit](PARITY_AUDIT_2026-10.md) records the earlier gaps and
preservation findings; its baseline descriptions are historical. The rows below
describe current code. Candidate run evidence belongs in [Testing](TESTING.md),
and physical-device acceptance remains distinct from implemented behavior.

The [10 October reader alignment contract](READER_ALIGNMENT.md) corrects the
product name, destinations and presentation against the maintainers' screenshots.
Its current code changes do not inherit earlier release/build acceptance; use
the exact-run evidence in Testing and retain the outstanding human QA gates.

| Area | Status | Implementation / remaining gate |
|---|---|---|
| Typed Bible v3 and dynamic indexes | Implemented core | `getBibleApiClient`, lossless source models and `CachedBibleRepository`; discovered extended book IDs, introduction-only content, exact-byte SHA activation and versioned legacy fallback. Live/device verification remains separate. |
| Query v3 reference previews | Implemented core | Selected-translation lookup, atomic bounded batches, native rich Scripture, Copy, exact-verse Open, bounded history and cancellable routes shared by dictionaries, commentaries, topics and notebook citations. Device/browser runtime remains a separate gate. |
| SQLite notes/markings/preferences/cache | Implemented | `LocalDatabase` and SQL repositories |
| SHA verification and offline chapter fallback | Implemented candidate; target verification required | Three freshness states; the icon toggles an inline dismissible explanation below the chapter header and links to the Bible API documentation. Licensing ends with book artwork and general-documentation attribution. |
| Native line/paragraph reader | Implemented | `ReaderScreen`; no WebView |
| Rich Scripture and original-text range mapping | Implemented core | Source headings/paragraphs, titles/introductions, reversible source styling and layered private markings render natively. UTF-16 end-exclusive ranges and exact quotes preserve selection/Copy; mismatched saved quotes stay stored without coloring replacement text. Rich/plain, Unicode/RTL and 200% text suites exist; device/screen-reader QA remains required. |
| Translation/book/chapter selection | Implemented | Dynamic selectors |
| Last passage persistence | Implemented core | Saved position and reader centering exist; full target lifecycle/restore validation remains. |
| Daily Scripture | Implemented correction; pending verification | Query alias resolution, complete daily verse selection, truthful unavailable outcomes and retry ownership now have regression cases; see the current testing evidence. |
| Swipe and cross-book navigation | Implemented core | Shared cross-book turn operation, horizontal swipe, Alt+arrow shortcuts, arrows/mobile row, and tested deliberate double-boundary intent; device gesture QA remains |
| Deep links/shareable links | Implemented core; target verification required | Persistent GoRouter page, friendly passage paths, browser history and custom `getbible:` cold/warm links. Generated Scripture links use the central `https://app.getbible.life` origin. Invalid/unavailable links never substitute a passage. OS-verified HTTPS app associations require domain and signing-team configuration. |
| RTL and appearance modes | Implemented | Device selection behavior still requires QA |
| Contextual selection/bookmark menu | Implemented candidate; target verification required | Direct per-verse action, clickable topic memberships and expandable searchable/scrollable Add another topic picker. Assignment remains additive; personal/global removal stays separate. All topics and Back to verse retain the originating reader position. Native selection and assistive-technology focus require device acceptance. |
| Whole/text markings and memberships | Implemented core | Canonical whole verses, translation-specific UTF-16 ranges, additive topic assignment and scoped origin removal. Source-scoped identity prevents unrelated providers from merging. Private IDs, custom labels/colors, exact quotes and timestamps survive transactional reconciliation. |
| Unified global/personal topic list | Implemented core | One topic list, G badges, API metadata reconciliation, explicit global download/removal and independent private copies. API metadata loads on first bookmark use; bundled private starter choices remain usable offline. Ambiguous independent private groups remain separate. |
| Inline notes | Implemented core; target verification required | Inline add/edit/delete, retained drafts across layout and failed saves, Ctrl/Cmd+Enter, navigation guarding and saved-note folding. Actual platform keyboard/IME behavior remains a device gate. |
| Online Search v3 | Implemented core | Advanced filters, ranked pagination, complete references, cancellation/cooldown and exact-verse opening. Edits debounce 250 ms; submit flushes immediately. Explicit Installed search has its documented local filter subset, an additional capability beyond the current website. |
| Adaptive Study workspace | Implemented candidate; target verification required | Centered wide dialog or compact keyboard-aware sheet; contextual Study shows passage/selection, Search selection and two resource tabs. Personal tools use a separate selector. Native selection precedence, Escape/focus restoration and large-text/RTL handling remain required. |
| Dictionaries and commentaries | Implemented candidate; target verification required | Confirmed-definition choices persist through related-entry navigation; actionable lexical IDs and repeated definitions remain visible. Bounded discovery separates suggestions, failures and retry. Installed-first scope uses explicit online expansion; the unbound browser retains catalogue access. Sparse commentary preserves introductions and shared citations. |
| Public topic browsing and private copies | Implemented candidate; target verification required | Selected-Bible Scripture loads progressively for topic cards through installed resources or Query, with per-verse outcomes, bounded caching and cancellation. Saved quotations remain separate. Follow/Hide and explicit private Copy retain their independent ownership. |
| Source annotations and references | Implemented core; target verification required | Below-verse/paragraph source notes, unlocated lexical metadata and citation controls; red Jesus quotations. Source text and private offsets remain unchanged; large-text/native selection acceptance remains required. |
| Personal study/sermon notebooks | Implemented core | Ordered private blocks and references, durable draft journals, revision conflicts, lifecycle flush and schema 3 migrations. The complete private backup includes notebooks, journals and references; Markdown has Save/Copy and supported sharing. |
| Private-data portability | Implemented core; target verification required | Explicit file import preview/confirmation, legacy v1/v2 import and v2 export, plus a distinct complete private format for notebooks, journals, settings and copy provenance. Atomic merging preserves conflicting work; public corpora are excluded. |
| Complete offline resources | Implemented core; target verification required | Explicit installs, staged generation activation, integrity/revision checks, restart recovery, cancel/retry/remove, installed Bible/reference/search and dictionary/commentary/topic indexes. Private data is independent of public resource removal. |
| Markdown generation | Implemented core; device verification required | Scripture and notebook Markdown preview, Save file/Download and Copy; supported mobile/browser share sheets with retained fallback actions. |
| Complete website localization | Implemented candidate; linguistic verification required | Current 282-message reference contract and 69 bundled packs, native extension catalogue, UI-wide lookup and independent RTL direction. Build-time generated translations require human language review; documented upstream historical-language fallbacks are retained. Tests compare pinned upstream keys, placeholders and native call sites, not only pack lengths. |
| getBible identity and approved artwork | Implemented candidate; package verification required | Exact display name, lowercase technical names, centralized public destinations and book artwork/native wordmark. CI checks asset hashes and naming. The alpha correction requires clean installation and adds no legacy-name migration. |
| Accessibility | Pending target verification | Safe areas, explicit Scripture semantics, keyboard/focus restoration, 200% text/RTL layouts, high contrast and reduced-motion handling have automated regressions. Actual VoiceOver/TalkBack, native selection handles and full device focus acceptance remain required. |
| CI and versioned packages | Implemented candidate; exact-run evidence required | Versioned DEB, EXE, DMG, APK, simulator APP and Web packages; automatic promotion of successful main artifacts to GitHub Releases. Native desktop/mobile simulator and three browser-engine acceptance jobs complement package builds. Passing one target is not validation of another. |
| Signed store distribution | External | Requires Apple/Google credentials and store review |

“Ready for distribution” requires every applicable Partial/Missing row to be resolved, automated checks and supported-host builds to pass, versioned packages to be verified, and the target manual QA matrix to be signed off. Mobile, desktop and browser are separate validation targets.

## Search v3 increment

Online Search now uses service-native paginated requests and preserves ranked original-text results. Filters, reference responses, revision consistency, cancellation, rate limits and native narrow RTL/200% layouts have 29 focused automated checks. See [Search v3](search-v3.md). Whole-translation search remains an explicit offline service, rather than the online reader path. Composed reader and platform evidence is recorded with the completed Study increment.

## On-demand dictionary increment

Typed dictionary lookup now discovers catalogues, metadata, published indexes and exact entries on demand. Native lookup preserves original words and lexical metadata, duplicate definitions, source attribution and bounded history. Eighteen focused tests and nineteen live-schema-validated fixtures cover this resource boundary; the adaptive reader entry points are composed in the Study increment. See [Dictionaries](dictionaries.md).

## Commentary resource increment

Native commentary reading requests only discovered coverage and the chosen chapter. It distinguishes introductions from Scripture, includes earlier-anchored ranges and multiple source entries, and preserves source OSIS, attribution and v2 citation provenance. Fourteen focused checks cover sparse availability, request ownership, dismissal, preferences and RTL/200% native layouts; six resource fixtures match the current live contract. See [Commentaries](commentaries.md).

## Local notebook storage increment

Independent titled study/sermon notebooks complement canonical inline verse notes. Ordered blocks, captured quotations, serialized autosave, durable editor journals and explicit conflict recovery preserve private content. Twenty-eight notebook, native-input and migration checks cover schema 1/2 upgrades, actual SQLite restart, simultaneous local editors and 200% RTL editing. Website-compatible backups deliberately omit notebooks; the separate complete private format preserves notebooks and draft journals, and the UI explains the distinction. See [Notebooks](notebooks.md).

## Public topic increment

Read-only public topic discovery, sparse reverse associations and locale fallback remain separate from private starter marking groups. Follow/Hide save scoped local choices; only explicit previewed Copy creates an independent private UUID group and additive canonical markings. Fifteen focused tests cover published identities, missing selected-Bible coordinates, collisions, repeat copies, source revisions, private-data preservation and native 200% layouts. Seven resource fixtures match the live Bookmarks contract. See [Public topics](public-topics.md).

## Integrated candidate and deliberate differences

Steps 16–17 implement the remaining reader, Study, bookmark and localization
boundaries against the current reference, together with runtime acceptance and
downloadable installers. Their automated results, external target limitations
and release candidate identity are recorded in [Testing](TESTING.md).

Flutter preserves two independent private groups when matching is ambiguous;
it does not guess that identical labels imply identical ownership. Published
topic metadata is loaded on first use of bookmark management/assignment rather
than adding startup network work. Dictionary discovery initially uses installed
modules where available, with an explicit online expansion. Separate private
notebooks, complete private backups and installed full-text search remain native
extensions. These choices are visible and preserve existing private data.

Source comparison, deterministic integration, actual installer execution,
physical-device accessibility and store review are separate evidence. Generated
locale coverage establishes available messages, not human linguistic approval.

Compact reference and Study sheets preserve positive keyboard clearance while
bounding transient negative native insets at zero. The iPad acceptance failure
exposed this layout boundary; focused keyboard-metrics regressions accompany
the production correction. Native input, draft retention and exact clipboard
assertions remain part of the composed target journeys.
