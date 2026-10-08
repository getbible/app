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
