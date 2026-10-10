# On-demand Dictionary Study

Word lookup is a native Study panel. Its immutable `StudyContext` retains the
original selected word and UTF-16 range. `DictionaryLookupBuilder` maps that
range to the source tokens' whitespace-word coordinates; token array positions
are never interpreted as character offsets. It preserves all Strong's IDs,
lemmas, morphology and transliterations. Plain translations use a surface-word
candidate with surrounding punctuation removed, without changing Scripture.

`DictionaryController` owns discovery, resource selection, requests and bounded
entry history. `DictionaryDiscovery` searches across resources and exposes only
confirmed nonempty definitions in the lookup chooser. Contextual Study presents
the selected word, actionable lexical identifiers and every confirmed definition
for the chosen resource. The full catalogue is available separately through the
unbound dictionary browser, never as an escape from a selected-word lookup.
`DictionaryRepository`
separates it from HTTP and JSON.
`ApiDictionaryRepository` uses the shared Dictionaries v1 transport to read
`dictionaries.json`, the chosen module's `metadata.json` and `index.json`, then
exact indexed entries to confirm a selected word's definitions. No server
definition-text search or whole-module download is performed. Indexes larger
than 256 KiB are decoded, validated and normalized in a native isolate or the
bundled browser worker. The online and installed adapters share this parser;
128-entry acknowledged batches return to the UI. Interactive exact/prefix
matching yields after each 1,024 records and checks cancellation.

The published index decides entry identities. Greek `G3056` and Hebrew `H0430`
are retained exactly; no ID is synthesized from padding, a display word or a
catalogue Strong's prefix. Every repeated definition remains an individual
index result. Accent folding applies to index keys and aliases, never verse
text. Definitions keep plain text, literal markup characters and paragraph
breaks. Structured references, links and backlinks remain separate typed data.

The lookup default follows the current reference application: an explicit
choice is retained, followed by lexical compatibility, Bible language, English,
and published resource name. Only confirmed choices participate. A foreign
fallback is visibly attributed in its actual source language. A deliberate
resource choice is stored per language/family; Scripture and the captured
selection are never translated or replaced by that choice. Storage failure does
not hide successfully loaded definitions. Module/context changes and dismissal invalidate
late results. Entry history in the unbound browser is bounded; revisiting a
loaded ancestor removes the cycle without recursively fetching resources.
Related entries and prefix
suggestions start a new contextual lookup with the published entry ID and key;
the dictionary chooser is filtered again, and Back restores the prior lookup.
Clearing the contextual search restores the original selection rather than
switching into catalogue browsing.

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
cancellation. The native worker keeps large parsing off the UI isolate.
The Step 16 parser now sends large online indexes through the same actual
browser worker as installed indexes. The bounded worker regression uses 5,001
entries, including a repeated definition and folded alias. Runtime and target
verification is recorded separately in [Testing](TESTING.md).

## Cross-resource lookup and offline scope

The implementation is aligned with reference commit `098eeaa`'s
`lib/dictionary-lookup.ts` and `app/components/StudyPanel.tsx`. Opening a selected
word discovers resources with exact published index keys, aliases and retained
lexical candidates, then checks each matching entry body. Empty definitions and
HTTP 404 entries are excluded. Other resource failures are reported separately
without hiding confirmed definitions. Results appear progressively, and a choice
made while other resources are loading remains selected. **Check dictionaries
again** retries discovery while retaining the deliberate resource preference.

Four workers share index and definition requests. A lookup admits at most
400,000 index records, 256 definition requests and 2,000,000 retained definition
characters. A reached limit is visible and suggests a more specific lookup word.
Normalized indexes are reused only for the same catalogue publication, expire
after 15 minutes, and are invalidated when managed installations change. Entry
navigation rechecks the selected repository snapshot; confirmed lookup bodies
cannot cross an installed-generation boundary. Dismissal or a newer word cancels
queued work and discards late responses.

When any dictionaries are installed, initial discovery checks those installed
resources only. **Searching installed dictionaries** states that scope, and
**Include online dictionaries** explicitly expands it to the published catalogue.
Thus a local match does not wait for unrelated HTTP timeouts. A no-match result
in this mode describes only installed resources, not every published dictionary.
Opening the dictionary browser without a selected word also prefers an
installed resource before applying language/default ranking.
A remembered online choice cannot cause an automatic request in that case.
The browser still lists the full catalogue for a deliberate online selection.
Choosing an online resource there is an explicit online action. A submitted
replacement word no longer carries the
original selection's Strong's candidates.

When no exact definition is confirmed, at most 20 separately labelled prefix
suggestions can open their exact published entry IDs. Suggestions never become
confirmed-resource choices merely because their index keys matched a prefix.
Native controls are localized, definitions retain their source direction and
selectability, and Scripture citations retain the selected Bible and captured
source context. Additional regressions are in `dictionary_discovery_test.dart`,
`dictionary_index_worker_test.dart`, the controller tests and native panel tests.

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
