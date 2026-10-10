# Web-to-Flutter parity contract

## Authority and goal

The current default branch of `getbible/app.getbible.life`, its README/tests and
live application define product behavior. Flutter implements the behavior with
native widgets and local platform services. Platform-appropriate presentation is
acceptable; changed data ownership or a missing workflow must be recorded.

The integrated candidate is aligned to reference commit
`098eeaa06c75efde4a3c75a9984d66ac987add30`. The
[October 2026 audit](PARITY_AUDIT_2026-10.md) records the earlier comparison at
`22172efd7ed46722c8f0da42b58222c8f1bc2360` and the gaps it identified.
Both applications now use the v3 Bible, Query and Search services. The
[July audit](PARITY_AUDIT_2026-07.md) is historical and predates the reference's
unified bookmarks and v3 Study workflows. Neither audit replaces the requirement
to recheck the reference when its behavior changes.

The maintainers' [reader alignment contract](READER_ALIGNMENT.md) additionally
fixes the native product name as `getBible` and specifies the screenshots'
interaction hierarchy. `ProductIdentity` owns the reader/share URL
`https://app.getbible.life`, general documentation `https://getbible.net`, and
verification link `https://getbible.net/api/bible/`. Lowercase technical names
use `getbible`; the alpha identity reset requires clean installation and no
legacy-name migration. Existing schema and bookmark reconciliation remain
separate responsibilities.

## Shared concepts and ownership

Paths in the reference column refer to `getbible/app.getbible.life`.

| Product contract | Reference authority | Flutter boundary / current gate |
|---|---|---|
| Bible v3 and hashes | `lib/getbible.ts`, `lib/cache.ts` | `lib/data/api/`, `CachedBibleRepository`, lossless source models and complete installed Bible indexes. |
| Query v3 previews | `lib/scripture-api.ts`, `app/components/ReferenceModal.tsx` | `QueryRepository`, `GroupedReferenceLookup`, `ReferencePreviewController`, `ReferencePreview`. |
| Search v3 and installed source | `lib/scripture-api.ts`, `app/page.tsx`; native offline policy | `OnlineSearchController`, repositories and `SearchPanel`; verified installed selected Bible preferred on opening, explicit source choices retained, no unsupported-filter silent online fallback. Online debounce and immediate submit remain. |
| Contextual Study layout | `StudyPanel.tsx`, maintainer screenshots | Centered wide dialog or compact sheet with captured passage/selection, Search selection and Dictionaries/Commentaries tabs. Personal tools use a separate management selector. Responsive/native accessibility acceptance remains required. |
| Dictionary/context lookup | `lib/study-api.ts`, `lib/dictionary-lookup.ts`, `StudyPanel.tsx` | Confirmed-definition choices, repeated definitions and actionable lexical IDs; related entries perform another contextual lookup rather than opening the full catalogue. Bounded discovery separates suggestions/failures; large indexes use workers. Installed-first scope has explicit online expansion. |
| Commentary | `lib/study-api.ts`, `StudyPanel.tsx` | Typed sparse-coverage/range/citation workflow; catalogue-driven automatic whole-module acquisition with persistent exclusions. |
| Automatic offline content | Maintainer-approved offline defaults, `Downloads & storage` | Selected Bible plus all non-excluded dictionaries/commentaries enter one queue. Persisted successful checks expire after 30 days; changed data activates atomically, failures keep the last good generation. Complete bookmarks remain manual opt-in. |
| Topic identity and reconciliation | `lib/shared-bookmarks.ts`, `lib/bookmark-storage.ts` | Public choices use Bookmarks v1 metadata or its saved copy, never hardcoded topic lists. Repository transactions reconcile source identity or unambiguous names/aliases/locales; ambiguous independent private groups remain private. |
| Memberships and provenance | `lib/markings.ts`, `BookmarkMenu.tsx` | Direct verse action, clickable memberships and searchable scrollable Add another topic picker; additive assignment and scoped personal/global removal. All topics and Back to verse retain the originating reader position. |
| Topic Scripture | `lib/scripture-api.ts`, topic views and maintainer screenshots | `TopicVerseLoader` and `TopicVerseList` resolve coordinates through shared installed/Query lookup, with bounded pages/concurrency/cache, independent errors and cancellation. Display text never replaces saved quotations. |
| Verification and licensing | Reader verification and licensing views, maintainer screenshots | Inline dismissible verification explanation below the chapter header; licensing footer uses approved book artwork, slogan and documentation attribution. Destinations come from `ProductIdentity`. |
| Canonical notes | `lib/notes.ts`, `app/page.tsx` | `VerseNote`, annotation repository, inline reader editor. |
| Rich source annotations | `lib/annotations.ts`, `ScriptureText.tsx` | `ScriptureTextMap`/composer, `SourceAnnotations` and native selectable Scripture; source notes/citations below verses/paragraphs, unlocated lexical metadata and red Jesus quotations. |
| Reader restoration and URLs | `lib/reader-state.ts`, `app/page.tsx` | `ReaderRouter`, `NativeReaderLinks`, `AppState` and persistent reader page; exact visible-verse restoration, friendly URLs/history, custom-scheme platform activation and draft-aware navigation. Verified HTTPS associations require external domain/team setup. |
| Markdown and backups | `lib/markdown.ts`, `lib/markings.ts`, `app/page.tsx` | Native Save/Copy/share and previewed file import; separate complete private format includes notebooks and retained drafts while website v2 remains compatible. |
| Daily Scripture | `lib/daily.ts` | Typed resolver and versioned daily cache; alias/range/ownership fixes have regressions awaiting current validation evidence. |
| Appearance/localization | `lib/appearance.ts`, `lib/i18n.ts`, `public/locales/` | `ReaderPreferences`, scoped `UiStrings`, pinned 282-message upstream catalogue, 69 packs and native extension messages. UI direction is independent of Scripture. High contrast/reduced motion respect preferences; generated language packs still require linguistic review. |

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
single SQLite transaction. The implemented store also remaps active/recent group
choices while retaining private notebook data. Catalogue refresh is idempotent
and uses the membership structure introduced in schema 5. Schema 6 separately
adds public-download scheduling and exclusions.

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

The selected Bible is prepared independently by the automatic offline queue;
the preview itself does not wait for a complete download. Dictionary/commentary
catalogue acquisition is automatic unless its per-module control is disabled.
Clearing public downloads retains these exclusions and all private data;
defaults can be acquired on the next startup/use, while removed full bookmark
datasets remain absent until another manual request. Refresh checks run while
the app is active, with no closed-app scheduler implied.

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

The pinned fixture `test/fixtures/ui_locale_contract.json` records the inspected
reference commit and catalogue. Contract tests compare upstream keys and message
positions, native call-site coverage and placeholders. The current reference has
282 source messages and 69 locale packs; empty upstream packs intentionally use
English. The importer adapts the literal app name in `clearAllConfirm` while
retaining the upstream key and position. Native extension packs are committed
and loaded locally; provider-generated translations and local AI-assisted
additions have explicit provenance. Runtime and CI do not contact a translation
service. Mechanical coverage is not human language approval; see
[localization](LOCALIZATION.md).

The earlier audit's 199/218 message counts describe its historical commits, not
this candidate. Re-synchronization must update the pinned fixture as well as the
packs so a new upstream key cannot pass by comparing only local pack lengths.

## Release gate

No release may be described as feature-equivalent while applicable rows in
`FEATURE_PARITY.md` remain Partial or Missing. Supported-host CI builds,
versioned artifacts, native/browser runtime journeys and side-by-side QA are
separate requirements. External signing/store access does not waive application
parity or justify describing unsigned validation artifacts as store-ready.

Native keyboard geometry has an additional platform contract: compact reference
and Study sheets must accept keyboard appearance, dismissal and transient
negative insets without invalid padding or loss of an active private draft.
Positive insets retain their full spacing; only negative layout clearance is
bounded at zero. This native protection does not change website workflows,
Scripture or stored private data.
