# Web-to-Flutter parity audit (9 October 2026)

## Sources and scope

The product authority is [`getbible/app.getbible.life` at
`22172efd7ed46722c8f0da42b58222c8f1bc2360`](https://github.com/getbible/app.getbible.life/tree/22172efd7ed46722c8f0da42b58222c8f1bc2360),
including its README, implementation and tests. The Flutter baseline inspected
is `2320832170bec9762960dd29de9ae5b7af2c7f17`. The July audit records an older
product and must not be used as the current bookmark or Search specification.

This is a source comparison with focused executable reference tests. It is not
side-by-side browser/device acceptance or a claim that the website's deployment
matches this exact commit. The current remediation's build and runtime evidence
belongs in [Testing](TESTING.md) and [Deployment](DEPLOYMENT.md).

Both implementations now use Bible v3, Query v3, Search v3 and the Dictionary,
Commentary and Bookmark v1 services. The earlier description of v3 as a
Flutter-only extension is obsolete. Online API coverage is substantially
aligned, but complete product parity has not been achieved.

## Bookmark contract changed materially

The reference commits `df9db18` and `22172ef` replaced the older separate-topic
import flow. The current implementation is in `lib/markings.ts`,
`lib/shared-bookmarks.ts`, `lib/bookmark-storage.ts`,
`app/components/BookmarkMenu.tsx` and `app/page.tsx`.

| Current reference behavior | Flutter baseline | Required alignment |
|---|---|---|
| Public and personal topics share one editable list. Fresh readers receive API topic metadata without automatically importing verse memberships. | Sixty bundled starter groups and a separate public Topics panel; explicit Copy creates a separate private group. | A unified native topic list, while retaining private copying only as an explicitly distinct operation if retained. |
| Automatic, idempotent reconciliation matches existing groups by source identity, ID, canonical/localized name or unambiguous alias. Custom IDs, names, colors and personal records survive; ambiguous names remain private. | No equivalent reconciliation; copied topics receive a collision-safe `private-topic-` identity. | Transactional forward migration with captured active/selected group remapping; unknown or ambiguous identities must not be guessed. |
| A verse or exact selected range can belong to several personal topics; personal and global origins can coexist in the same topic. | Adding a whole-verse marking removes every previous whole-verse marking at that verse. | Add/remove a specific membership without erasing another topic or origin. Preserve translation-neutral whole verses and translation-specific UTF-16 selections. |
| Each group/mark can retain `source: {type: "shared-bookmark", topicId}`. Personal highlighting takes precedence regardless of download time. | Source provenance is ignored by the baseline annotation parser; whole-verse merge identity has no origin component. | Preserve, validate, store and export source metadata, and include origin in whole-verse deduplication. See the data-integrity finding below. |
| A contextual bookmark menu lists assignments, exact saved selections, separate personal/global removal actions, recent topics, and a return-to-verse path from Study. | Active-color/selection menus and separate saved-marking cards. | A native assignment menu with equivalent ownership, focus restoration, keyboard and large-text behavior. |
| Download one/all public topics into their existing groups; remove global memberships without deleting personal marks or group metadata. G badges identify downloaded origin; rows combine equivalent displayed verses without merging stored origins. | Lazy public browsing, Follow/Hide and independent private copies. No complete catalog installation or origin-aware download removal UI. | Unify the online workflow; complete resource installation/integrity remains the offline-resource increment. |
| Topics, memberships and setup state are persisted together in one atomic browser snapshot. | SQLite provides transactions for existing writes and public copies, but there is no unified migration/setup snapshot. | Use a SQLite transaction for the complete migration and its completion marker; do not reproduce the browser storage implementation literally. |

### Data-integrity finding at the baseline

A current web backup may contain two whole-verse records with the same group
and coordinates: one personal and one global. The website's
`markingIdentity` distinguishes these origins. In the inspected Flutter
baseline, `MarkingGroup.fromJson` and `Marking.fromJson` ignore `source`, and
`Marking.identity` maps both records to the same value. A merge can therefore
discard one membership; re-export also loses provenance. Matching a group by
name and color alone can incorrectly join unrelated source identities.

The baseline `AppState.markWholeVerse` and `removeWholeVerseMarking` also remove
all whole-verse records at a verse. This can erase other topic memberships,
including earlier explicit private topic copies. These are preservation defects
to fix independently of the larger UI redesign. Passing a legacy v1/v2 fixture
without source metadata does not establish current-web compatibility.

The regression contract must include mixed personal/global origins in one
renamed local group, repeated cross-translation import, colliding IDs, same-name
groups from different source topics, legacy deterministic source IDs, deletion
of one membership, and SQLite reopen. Existing notes, quotes, ranges and
creation timestamps must remain unchanged.

## Targeted corrections in this change

The preservation remediation adds typed group/mark source metadata, origin-aware
whole-verse identity and merges, narrow recognition of legacy deterministic
imports, schema-4 forward migration and source fields in web backup round trips.
Whole-verse assignment becomes additive/idempotent per topic; scoped personal
removal retains other topics and downloaded origins, with personal highlight
priority. The full unified list, automatic group reconciliation, recent-topic
assignment surface and global download management remain unfinished. Ranged
selection removal still follows its existing overlap behavior; this change does
not claim the reference's complete per-topic range menu.

The daily remediation adds version-2 public cache selections, typed Query alias
resolution, all-verse validation before chapter activation, complete selection
emphasis, cancellation ownership and retry of the failed daily request. It
removes unrelated default-passage/stale-daily substitution. Old first-verse
caches remain readable and are refreshed before daily use. No private annotation
or SQLite schema change is needed for that public cache field.

The new regressions pass within the 298-test Flutter suite, including source
round trips, forward migration, concurrent membership writes and stale-menu
ownership. Validation evidence and its platform limits are maintained in
[Testing](TESTING.md). The source-baseline findings below remain useful history
of the differences that triggered these targeted fixes.

## Other verified differences

| Area | Current reference source and behavior | Flutter baseline and consequence | Priority / roadmap |
|---|---|---|---|
| Daily Scripture | `lib/daily.ts`, `tests/daily.test.ts`: Query resolves source book aliases; all selected verses are retained; unresolved or incomplete lookup does not open another passage. | `AppState.openDailyScripture`, `daily_scripture_service.dart`: local name match only, first verse only, fallback to KJV Ephesians 5 when the name is unavailable. A real alias can open unrelated Scripture. | Correctness fix before parity acceptance. |
| Dictionary discovery | `lib/dictionary-lookup.ts`, `StudyPanel.tsx`: reusable cross-resource indexes and confirmed nonempty definitions determine contextual choices; suggestions and partial-resource failures remain explicit. | `DictionaryController` selects one compatible/remembered module, filters that module's published index, and exposes the catalog as choices. A word may have a definition elsewhere even when the initial resource has none. | Workflow alignment; keep bounded concurrency and cancellation. |
| Source annotations | `lib/annotations.ts`, `app/components/ScriptureText.tsx`: source notes, unlocated lexical metadata and reference buttons render below Scripture; Jesus quotations render red without redundant speaker notes. | Rich metadata survives parsing, and source emphasis renders, but these annotation/reference controls are absent. `scriptureVerseSpan` uses weight rather than red for Jesus quotations. | Visible reading/Study parity. Preserve original Scripture and private offsets. |
| Search interaction | `app/page.tsx`, `lib/scripture-api.ts`: edits trigger a debounced, cancellable server search. | `SearchPanel._inputChanged` cancels and clears; a Search/submit action starts the replacement. API filters, authoritative order, 25-result pagination and cancellation are present. | UX difference; document or align with a bounded debounce. |
| Deep links and history | `lib/reader-state.ts`, `app/page.tsx`: friendly passage URLs, direct reload and back/forward ownership. | `parsePassageLink` exists, but `main.dart` mounts a fixed `MaterialApp.home`; no router consumes URL changes or integrates platform links. | Existing unfinished navigation/parity work. |
| Localized interface | `lib/i18n.ts`, `public/locales/`: 69 packs with 218 source-message positions at the reference commit. | `assets/locales/` has 69 packs with 199 positions; `UiStrings` wires only a subset of labels. Existing locale tests compare Flutter files with each other, not the current reference. | Step 16. Sync the positional contract and adopt messages across native widgets. |
| Markdown and backups | Web download/file-import actions are wired into `app/page.tsx`; backups now preserve public provenance. | Markdown preview and clipboard work. Native save/share and complete backup picker/import/export flows remain incomplete; notebooks/journals/preferences are not fully portable. | Step 12 for private portability; complete native file actions before release. |
| Complete offline resources | `lib/cache.ts`, `lib/study-api.ts`, `lib/offline-ready.ts`, `public/sw.js`: explicit complete Bible/study downloads and offline startup from installed data; the web shell is cached. | Verified opened-chapter fallback and typed on-demand Study work. Deliberate full-Bible download is not an installation manager serving all reader/query paths; complete Study installation is absent. | Steps 13–15. The native app needs equivalent installed-resource behavior, not a service worker. |
| Reader credits and placement | Latest web source places study controls below Scripture, links the Verified explanation to API documentation, and adds official GetBible credit/slogan in translation details. | Native translation metadata and verification explanations exist, but this placement and complete credit/link presentation differ. | Step 16 alongside phone/desktop visual review. |

The website itself still describes live Search as requiring a connection.
Complete installed-Bible search in Flutter is a planned capability, not an
existing reference-app parity requirement. Do not report the website as offering
full offline Search merely because it installs Bible resources.

## Capabilities that already align

- Dynamically discovered Bible v3 identities, preserved original verse text,
  canonical whole-verse annotations and translation-scoped selected text.
- Query v3 previews and explicit reader navigation without requiring a full
  Bible download.
- Advanced online Search v3, source-ranked pagination and exact-verse opening.
- On-demand dictionary entry identities/aliases and sparse chapter/verse
  commentary with source attribution.
- Canonical inline verse notes and local-first storage without uploading private
  note text or adding accounts or tracking.

These are implemented feature boundaries, not proof of every platform's visual,
accessibility or runtime equivalence. Flutter's separate study/sermon notebooks
are additional functionality; no equivalent notebook model was found in the
inspected web source. Keep them separate from canonical notes and include them
in the later complete-private-backup contract.

## Executed evidence

On Node 24.19.0, the reference's existing tests were run without changing its
source:

```bash
node --experimental-strip-types --test \
  tests/bookmark-migration.test.ts \
  tests/bookmark-memberships.test.ts \
  tests/bookmark-storage.test.ts \
  tests/shared-bookmarks.test.ts
```

Result: **33 passed, 0 failed**. These exercise the reference behavior above;
they do not test the Flutter implementation. A file comparison also verified 69
locale packs in each repository and the 199/218 message-count difference. Only
the locale index was byte-identical among the 70 common JSON files.

## Delivery order and acceptance

1. Fix runtime/build blockers and current backup/membership preservation; add
   regression tests for the exact failing paths, not only compilation.
2. Implement the unified native bookmark list, migration and assignment menu
   against the reference's source contract and shared backup fixtures.
3. Align daily alias/range behavior, contextual dictionaries and source
   annotations. Verify these through composed reader journeys.
4. Continue steps 12–15 for complete private portability and installed resources;
   keep their larger scope separate from the immediate error fixes.
5. Complete step 16 localization, links, native file actions and visual/accessibility
   review, then step 17 supported-host builds and actual device install/upgrade.

A successful build answers whether a target compiles. A deterministic integration
journey answers only the exercised runtime behavior. Neither establishes current
web parity, installer correctness on every host, or store acceptance by itself.
