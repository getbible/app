# Web-to-Flutter parity contract

## Authority and goal

The current default branch of `getbible/app.getbible.life`, its README/tests and
live application define product behavior. Flutter implements the behavior with
native widgets and local platform services. Platform-appropriate presentation is
acceptable; changed data ownership or a missing workflow must be recorded.

The [October 2026 audit](PARITY_AUDIT_2026-10.md) compares the reference commit
`22172efd7ed46722c8f0da42b58222c8f1bc2360` with the Flutter implementation.
Both applications now use the v3 Bible, Query and Search services. The
[July audit](PARITY_AUDIT_2026-07.md) is historical and predates the reference's
unified bookmarks and v3 Study workflows. Neither audit replaces the requirement
to recheck the reference when its behavior changes.

## Shared concepts and ownership

Paths in the reference column refer to `getbible/app.getbible.life`.

| Product contract | Reference authority | Flutter boundary / current gate |
|---|---|---|
| Bible v3 and hashes | `lib/getbible.ts`, `lib/cache.ts` | `lib/data/api/`, `CachedBibleRepository`, lossless source models and complete installed Bible indexes. |
| Query v3 previews | `lib/scripture-api.ts`, `app/components/ReferenceModal.tsx` | `QueryRepository`, `GroupedReferenceLookup`, `ReferencePreviewController`, `ReferencePreview`. |
| Search v3 | `lib/scripture-api.ts`, `app/page.tsx` | `OnlineSearchController`, `ApiSearchRepository`, `SearchPanel`; input debounce differs. |
| Dictionary/context lookup | `lib/study-api.ts`, `lib/dictionary-lookup.ts`, `StudyPanel.tsx` | Typed repository/controller and native panel; cross-resource confirmed-definition choices remain missing. |
| Commentary | `lib/study-api.ts`, `StudyPanel.tsx` | Typed sparse-coverage/range/citation workflow with explicit complete offline module installation. |
| Topic identity and migration | `lib/shared-bookmarks.ts`, `lib/bookmark-storage.ts` | Public topic/copy repositories plus private annotations; unified list and automatic reconciliation remain missing. |
| Memberships and provenance | `lib/markings.ts`, `BookmarkMenu.tsx` | `annotations.dart`, `AppState`, annotation repository; preservation and full contextual menu are distinct acceptance gates. |
| Canonical notes | `lib/notes.ts`, `app/page.tsx` | `VerseNote`, annotation repository, inline reader editor. |
| Rich source annotations | `lib/annotations.ts`, `ScriptureText.tsx` | `ScriptureTextMap`/composer and native text; full source-note/reference surface remains missing. |
| Reader restoration and URLs | `lib/reader-state.ts`, `app/page.tsx` | `AppState`, settings and passage parser; router/platform integration incomplete. |
| Markdown and backups | `lib/markdown.ts`, `lib/markings.ts`, `app/page.tsx` | Native Save/Copy/share and previewed file import; separate complete private format includes notebooks and retained drafts while website v2 remains compatible. |
| Daily Scripture | `lib/daily.ts` | Typed resolver and versioned daily cache; alias/range/ownership fixes have regressions awaiting current validation evidence. |
| Appearance/localization | `lib/appearance.ts`, `lib/i18n.ts`, `public/locales/` | `ReaderPreferences`, `UiStrings`, `assets/locales/`; complete current-message adoption remains incomplete. |

## Bookmark preservation rules

The reference's public and private topics share a list while each membership
retains its independent origin. Public topic identity belongs to validated
source metadata, not a translated label or color. Whole-verse membership stays
canonical across translations; selected ranges stay translation-specific with
original UTF-16 offsets and quotes. Adding one topic must not erase another.
Removing one personal membership must not remove its global counterpart.

Automatic reconciliation in the reference preserves custom names/colors and
surviving local IDs, resolves only unambiguous name/alias/locale matches, and
retains every personal record. Global duplicates can collapse only within the
same source/topic/coordinate identity. Flutter must implement these rules in a
single SQLite transaction before it claims unified-bookmark parity.

The existing **Copy to my markings** creates an independent private copy. That
operation is different from the reference's **Download global bookmarks**, whose
records retain removable global provenance. Follow/Hide are also separate local
preferences. Documentation and UI must not treat these operations as synonyms.

Web backup version 2 now includes additive `source` fields on groups and
markings. Accepting the version number alone does not establish compatibility.
Regression fixtures must cover mixed origins, migrated local group IDs,
collisions, repeated imports and round-trip provenance. Private notebooks and
durable editor journals use the separate complete private backup format; website v2 export makes no claim to include them.

## Scripture and preview rules

Scripture text remains unchanged through source styling, native selection,
Copy, Search emphasis and markings. Source word/token positions are distinct
from persisted character offsets. Quote mismatch preserves the stored private
record without coloring unrelated replacement text.

Previewing a citation does not install a translation or change the persisted
reading position. Explicit Open uses exact returned coordinates; unavailable
coverage must remain an error. Shared Query previews retain source attribution,
bounded history and cancellation on replacement/dismissal. Native notes and
notebooks remain private when their Scripture references are queried.

## Synchronization workflow

For each product change:

1. Record the inspected reference commit and source/test paths.
2. Compare visible workflow and persistence contracts, not only feature names.
3. Add shared JSON fixtures for API/backup changes and native regression cases
   for state transitions, ownership and failures.
4. Implement through domain/repository/application boundaries; widgets do not
   issue raw HTTP, SQL or migration operations.
5. Refresh locale packs and adopt changed messages without translating Scripture,
   source metadata or personal labels.
6. Update this contract and [Feature parity](FEATURE_PARITY.md), distinguishing
   implemented code from runtime/device evidence and remaining differences.
7. Compare both apps at phone/desktop widths, light/dark, RTL, large text and
   offline states before release acceptance.

Synchronize compact locale files from a sibling reference checkout with:

```bash
dart run tool/sync_web_locales.dart ../app.getbible.life
flutter test test/localization_contract_test.dart
```

The existing locale test checks internal pack consistency. Until a pinned
reference fixture/message contract is added, it cannot detect new upstream
messages or prove all native controls use translations. The October audit found
199 Flutter messages versus 218 reference messages across the same 69 locales.

## Release gate

No release may be described as feature-equivalent while applicable rows in
`FEATURE_PARITY.md` remain Partial or Missing. Supported-host CI builds,
versioned artifacts, native/browser runtime journeys and side-by-side QA are
separate requirements. External signing/store access does not waive application
parity or justify describing unsigned validation artifacts as store-ready.
