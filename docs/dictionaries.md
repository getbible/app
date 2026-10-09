# On-demand Dictionary Study

Word lookup is a native Study panel. Its immutable `StudyContext` retains the
original selected word and UTF-16 range. `DictionaryLookupBuilder` maps that
range to the source tokens' whitespace-word coordinates; token array positions
are never interpreted as character offsets. It preserves all Strong's IDs,
lemmas, morphology and transliterations. Plain translations use a surface-word
candidate with surrounding punctuation removed, without changing Scripture.

`DictionaryController` owns discovery, resource selection, requests and bounded
entry history. `DictionaryRepository` separates it from HTTP and JSON.
`ApiDictionaryRepository` uses the shared Dictionaries v1 transport to read
`dictionaries.json`, the chosen module's `metadata.json` and `index.json`, then
only an explicitly selected indexed entry. No server definition-text search or
whole-module download is performed. Large native indexes are decoded and
validated in a compute worker; index keys are folded once, and interactive
filtering yields in bounded slices for web responsiveness and cancellation.

The published index decides entry identities. Greek `G3056` and Hebrew `H0430`
are retained exactly; no ID is synthesized from padding, a display word or a
catalogue Strong's prefix. Every repeated definition remains an individual
index result. Accent folding applies to index keys and aliases, never verse
text. Definitions keep plain text, literal markup characters and paragraph
breaks. Structured references, links and backlinks remain separate typed data.

Automatic defaults require compatible language and lexical family. A missing
language has an explicit resource-choice state. A deliberate resource choice
is stored per language/family, and its actual source language is always shown,
including remembered foreign-language choices. Storage failure does not hide
successfully loaded definitions. Module/context changes and dismissal invalidate
late results. Link history is bounded and revisiting a loaded ancestor removes
the cycle without recursively fetching resources.

Dictionary and commentary citations share `StudyCitation` and its strict
adapter. Source labels and OSIS are retained. Positive verse coordinates use
the selected Bible's shared Query preview. Whole chapters and v2 extended-book
IDs use the original citation spelling; unresolved or unavailable selected-Bible
coverage is an explicit preview error. Chapter/verse-zero introduction citations
are unavailable, never manufactured Scripture. Resource attribution retains
license, source, copyright, distribution notes and original v2 reference
provenance; the app makes no automatic versification-conversion claim.

Run:

```bash
flutter test test/dictionary_lookup_test.dart test/dictionary_repository_test.dart test/dictionary_controller_test.dart test/dictionary_panel_test.dart
```

Positive catalogue, metadata, index and entry
fixtures under `test/fixtures/dictionaries_v1/` are checked against the published
Dictionaries v1 OpenAPI schemas. Focused tests cover Greek/Hebrew IDs, aliases,
accent folding, plain/rich source words, repeated definitions, missing entries,
an advertised Strong's prefix without matching token IDs, stale module results,
cycle-safe links, native citations, persistence failure, RTL and 200% text.

The implementation was rechecked against the [official Dictionary v1
guide](https://getbible.net/api/dictionaries/v1/) and its [live
OpenAPI](https://dictionaries.getbible.net/v1/openapi.json). An available-platform
benchmark parsed the current Webster1913 index (6,917,748 bytes; 114,712 entries)
and verified identical synchronous/cooperative matches, event-loop yielding and
cancellation. Native compute avoids putting that large parse on the UI isolate.
Flutter Web still performs JSON parsing on its event loop; physical-phone and
browser performance profiling remains a later integrated UX release gate.

## Complete offline dictionaries

**Set up offline use** lists the dynamically discovered dictionaries, source
language, license and advertised whole-module size. An explicit installation
fetches the current SHA-256 manifest, catalogue, module metadata, index and
`{dictionary}.json`. It hashes the exact downloaded bytes, validates identities,
counts and every nested entry against the published index, and checks the same
manifest paths again before activation. Repeated display keys remain separate
exact IDs; aliases, lexical IDs, links, citations and attribution survive.

The complete module is decoded, verified and indexed in a native isolate or the
bundled browser worker, with bounded, acknowledged batches into staging. Saved
large indexes also rebuild their normalized lookup keys in that worker. No
per-entry HTTP crawl or main-isolate whole-module JSON parsing is used. Failed,
cancelled, malformed or source-rotated installations leave the prior installation
readable. Installation/removal never writes private annotations.

`InstalledDictionaryRepository` supplies the same typed controller boundary.
Installed metadata, index and entries are read locally after restart, with an
**Installed on this device** status. Saved discovery retains online-only choices
without delaying installed lookup for an HTTP timeout; **Set up offline use →
Browse catalogue / Check for updates** obtains new discovery. Online-only choices retain
an explicit status and use the existing API. An entry missing from an installed
snapshot is a repairable storage error, never a fetch from another revision.
Source roots are isolated and a module reading session pins its generation.

`test/installed_study_test.dart` adds complete-module fixtures, real SQLite
restart, installed/online source equivalence, exact-byte corruption, manifest
rotation and atomic failed-update coverage.

The complete-module processor was additionally checked on 9 October 2026
against the generated source repository's current `saoa.json`, metadata and
index: 107,863 published bytes produced 35 validated local documents. This
exercises a real complete dictionary independently of the small regression
fixtures. Source: [`getbible/dictionaries`](https://github.com/getbible/dictionaries/tree/main/v1).
