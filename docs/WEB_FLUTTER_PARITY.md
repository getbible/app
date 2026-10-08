# Web-to-Flutter parity contract

## Authority and goal

The current default branch of `getbible/app.getbible.life`, its README/tests, and `https://app.getbible.life/` define product behavior. Flutter implements that behavior with native Flutter widgets and local platform services. Slight platform-appropriate differences are acceptable; missing workflows, altered persistence semantics, or generic branding are not.

## Shared concepts and ownership

| Product contract | Web authority | Flutter authority |
|---|---|---|
| GetBible API parsing | `lib/getbible.ts` | `lib/data/api/`, `lib/domain/models/bible.dart` |
| Scripture reference preview | Existing web reference/navigation behavior; Flutter v3 extension | `QueryRepository`, `GroupedReferenceLookup`, `ReferencePreviewController`, `ReferencePreview` |
| Hash/cache invalidation | `lib/cache.ts` | `CachedBibleRepository`, `LocalDatabase` |
| Reader restoration | `lib/reader-state.ts` | settings repository and `AppState` |
| Marking overlap/identity | `lib/markings.ts` | annotation models/repository |
| Canonical notes | `lib/notes.ts` | `VerseNote`, annotation repository |
| Search modes | `lib/search.ts` | search models/service |
| Markdown contract | `lib/markdown.ts` | `markdown_service.dart` |
| Daily Scripture | `lib/daily.ts` | API/cache models and application use case |
| Appearance | `lib/appearance.ts` | `ReaderPreferences` and presentation theme |
| UI localization | `lib/i18n.ts`, `public/locales/` | `assets/locales/` and Flutter localization service |
| Reader defaults/groups | `config/reader.ts` | `starter_marking_groups.dart` |

## Synchronization workflow

For every product change:

1. Identify the behavioral contract and persistence impact in both repositories.
2. Add or update shared JSON fixtures before implementation when serialization/API behavior changes.
3. Implement web and Flutter behavior without changing canonical note, marking, or backup rules.
4. Add equivalent unit tests plus platform-appropriate UI/integration tests.
5. Refresh locale packs when UI messages change; never translate Scripture or user labels.
6. Update this document and `FEATURE_PARITY.md` in the Flutter repository.
7. Compare the applications side by side on phone and desktop widths, light/dark, RTL, offline, and large text.

Synchronize the compact locale files from a sibling web checkout with:

```bash
dart run tool/sync_web_locales.dart ../app.getbible.life
flutter test test/localization_contract_test.dart
```

## Intentional v3 extensions

Rich Bible v3 source styling is also an intentional presentation extension.
Native line/paragraph text keeps the web-compatible UTF-16 end-exclusive private
range and exact-quote contract. Source word/token indexes are mapped separately;
turning source styles off does not edit verse text or private annotations.
Changed source quotes stay stored without highlighting unrelated replacement
text. Full localization, platform selection and screen-reader parity remain
release gates rather than claims derived from rich-text widget tests.

Flutter's shared reference preview uses the public Query v3 REST service while
preserving the web baseline's annotation, selected-text coordinate and reading
position rules. The separate React application retains its existing API
implementation; this extension does not claim that repository was upgraded.

Previewing a citation requires no translation installation and does not change
the persisted reader position. Structured references use book names discovered
in the selected Bible and retain the original source label. Missing translation,
book or verse coverage is shown without substituting Scripture. Rich verse
metadata and contributing references remain intact, while full-chapter layout
is loaded only for explicit reader navigation.

The preview provides native Copy, exact-verse Open, bounded back history,
cancellation on replacement/dismissal, and adaptive compact/wide presentation.
The dedicated Query unit/widget suites verify this behavior, including Unicode,
RTL, large text, all-or-error batching and late Open route ownership. New labels
are injectable; complete locale adoption remains step 16. Dictionaries,
commentaries, public topics and personal notebook citations now reuse this
shared preview. Browser/device runtime and side-by-side QA are still release gates.

## Release gate

No Flutter release may be described as feature-equivalent while applicable rows in `FEATURE_PARITY.md` remain Partial. CI, build artifacts, and manual side-by-side QA are all required. External signing/store access is tracked separately and is not a reason to waive application parity.

## Search v3 increment

Online Search now uses service-native paginated requests and preserves ranked original-text results. Filters, reference responses, revision consistency, cancellation, rate limits and native narrow RTL/200% layouts have 29 focused automated checks. See [Search v3](search-v3.md). Whole-translation search remains an explicit offline service, rather than the online reader path. Composed reader and platform evidence is recorded with the completed Study increment.

## Native dictionary resources

The native resource panel adds on-demand dictionaries and lexical lookup through typed service/controller boundaries. Original Scripture stays selectable; entry IDs and aliases come from published indexes, and large native indexes parse off the UI isolate. Eighteen focused checks cover cancellation, repeated definitions, source language, history and narrow RTL/200% layouts. See [Dictionaries](dictionaries.md).

## Commentary resource increment

Native commentary reading requests only discovered coverage and the chosen chapter. It distinguishes introductions from Scripture, includes earlier-anchored ranges and multiple source entries, and preserves source OSIS, attribution and v2 citation provenance. Fourteen focused checks cover sparse availability, request ownership, dismissal, preferences and RTL/200% native layouts; six resource fixtures match the current live contract. See [Commentaries](commentaries.md).

## Local notebook storage increment

Independent titled study/sermon notebooks complement canonical inline verse notes. Ordered blocks, captured quotations, serialized autosave, durable editor journals and explicit conflict recovery preserve private content. Twenty-eight notebook, native-input and migration checks cover schema 1/2 upgrades, actual SQLite restart, simultaneous local editors and 200% RTL editing. Website-compatible backups continue to omit notebooks until step 12; the UI states this boundary. See [Notebooks](notebooks.md).

## Public topic increment

Read-only public topic discovery, sparse reverse associations and locale fallback remain separate from private starter marking groups. Follow/Hide save scoped local choices; only explicit previewed Copy creates an independent private UUID group and additive canonical markings. Fifteen focused tests cover published identities, missing selected-Bible coordinates, collisions, repeat copies, source revisions, private-data preservation and native 200% layouts. Seven resource fixtures match the live Bookmarks contract. See [Public topics](public-topics.md).
