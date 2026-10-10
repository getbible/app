# Architecture

## Decision record ADR-001

The app uses a layered, local-first architecture. Flutter widgets depend on application state, application state depends on repository contracts, and data adapters implement those contracts. This makes the persistence and future synchronization boundaries explicit without claiming a synchronization backend exists.

Provider/`ChangeNotifier` supplies reader state and bounded feature controllers.
Search, dictionary, commentary, topics and notebooks own separate lifecycles;
they do not add service parsing or persistence policy to `AppState` or reader
widgets. GoRouter is pinned for the planned canonical deep-link graph. A future
state-system change should be one deliberate ADR rather than mixing systems
feature by feature.

SQLite is the system of record. Drift supplies cross-platform executors and background native database creation. Models perform strict, versioned serialization rather than accepting loose maps throughout the application.

## Runtime flow

1. `main.dart` initializes Flutter and opens the database.
2. `runApp` displays the native shell; `AppState` then loads preferences and last reading position without waiting for network access before the first frame.
3. `CachedBibleRepository` gets translation/book/chapter data.
4. The repository checks cached records, expiry, and API hashes.
5. `ReaderScreen` renders typed chapter data and reports cache freshness.
6. Annotation/settings repositories persist user actions immediately.
7. `StudyServices` composes feature repositories/controllers with the existing
   shared public transport and private database. Search has an independently
   owned `OnlineSearchController`.
8. `StudyWorkspace` renders the chosen typed panel. Closing cancels public
   resource interactions and requests a notebook flush; application shutdown
   awaits notebook persistence before closing SQLite.

## Extension points

- Add use-case classes when `AppState` would otherwise accumulate business rules.
- Implement new repository adapters for optional future synchronization; retain SQLite as offline source of truth.
- Keep platform share/file-picker integration behind services.
- Add deep-link routes without exposing API numeric details to widgets.

## Security and privacy boundaries

No secrets are required. Imported JSON is hostile input and must be size-bounded, decoded, fully validated, merged in memory, then committed transactionally. URLs are constructed from validated translation identifiers and positive numeric passage fields.

## Public service boundaries

`ApiTransport` is the shared HTTP boundary for the Bible, Query, Search,
Dictionary, Commentary and public Bookmark services. `ApiConfiguration` injects
independent versioned roots; adapters retain each service's native envelope.
`ServiceEnvelopeAdapters` validates discovery/study/search documents into typed
contracts, without adding HTTP or JSON parsing to widgets.

Transport validates status before decoding, bounds streamed response bytes and
request duration, and retries only transient failures within a finite budget.
Typed failures retain HTTP status and Retry-After. Cache policy accounts for
Cache-Control, validators, Date/Age and Expires; no-store bodies are not retained,
no-cache responses are revalidated, and 304 requires an eligible saved body.
Missing browser-exposed headers imply conservative freshness. This bounded
HTTP cache is separate from SQLite's saved Scripture and future explicit
installations. Cancellation is request-scoped: dismissing one surface never
closes another service's shared client.

## Rich Scripture and private ranges

`ScriptureTextMap` maps source word ranges onto the unchanged verse string.
Published word ranges are 1-based inclusive; token-array ranges are 0-based
inclusive. Neither is a character offset. Multiword tokens, punctuation,
whitespace, combining characters and supplementary Unicode characters retain
their original positions. Unlocated or incompatible source ranges are preserved
in the model without being guessed into display coordinates.

`ScriptureTextComposer` combines source emphasis, private marking colors and
temporary emphasis as separate layers. Supported source emphasis includes
italic/bold, divine-name styling and quotations explicitly attributed to Jesus;
unknown source attributes remain preserved. The persisted `showSourceStyles`
reader preference disables only the source visual layer. Native selectable text
and copied verse content remain unchanged.

Private selected-text records keep their translation, canonical verse identity,
UTF-16 code-unit offsets with an exclusive end, and saved quote. A range is
rendered only when its bounds and exact quote match the current verse. Source
revision mismatch leaves the record stored, rather than shifting its offsets or
coloring another phrase. Whole-verse annotations remain translation-neutral,
and ranged removal leaves whole-verse, other-translation, other-verse and
non-overlapping records intact.

`ScriptureChapterLayout` follows emitted verse IDs for paragraph ranges and
ordered headings before their anchor. Native paragraph selection maps each
selected section back to its original verse string; generated verse-number
markers and document separators are excluded from saved verse ranges. Copy
omits generated verse markers and joins the selected original verse slices.
Translation/book introductions and source titles render separately from verse
coordinates, including introduction-only content with no invented Scripture
verse.

## Reference previews

Reference lookup follows the same boundaries as reading:

- `ReferenceRequest`, `ReferenceSelection`, `ReferenceChapter` and
  `ReferenceResult` describe selected-translation citations in `domain/`.
  `QueryRepository` is the adapter boundary for online lookup and a future
  installed-Bible resolver.
- `QueryApiClient` uses the shared transport and a dedicated compact Query v3
  parser. Optional chapter metadata can be absent; verse identities and all
  supplied lexical/source fields and contributing `ref` arrays survive parsing.
  A schema-invalid response discards only its own HTTP cache snapshot, allowing
  a corrected response to be fetched on retry.
- `GroupedReferenceLookup` resolves structured coordinates using book names
  discovered in the selected Bible. It retains the source-language citation
  label rather than sending that label as an invented translated book name.
  It returns one complete aggregate only after every batch succeeds and every
  requested coordinate is present. A missing book, unavailable verse or failed
  batch produces an error without exposing successful partial Scripture.
- `ReferencePreviewController` owns request cancellation and at most eight
  previous citations. Switching, closing or disposing invalidates late results.
  It owns no reader position or annotation writes.
- `ReferencePreview` renders native selectable rich text, the reference and
  translation, loading/errors, Copy and Open actions. It respects the reader's
  source-style preference and uses selected-translation direction when compact
  metadata omits direction. `showAdaptiveReferencePreview` presents a compact
  sheet below 900 logical pixels and a right-aligned panel dialog on wider
  windows. Dictionary, commentary, public-topic and notebook panels invoke this
  same preview through typed callbacks.

Query references are percent-encoded as one path segment, without query
parameters. Structured requests are split within all current public bounds:
512 Unicode characters, eight references and 200 verses per HTTP request.
The reader limits an aggregate interactive preview to 2,000 verses. Free-form
text exceeding the character/reference bounds gets an actionable error;
arbitrary source-language citation text is not split or reinterpreted locally.

Opening or closing a preview leaves the reading position unchanged. Only an
explicit Open action loads a static chapter and selects the returned verse ID.
Reader navigation checks preview ownership before committing late data. The
presented preview dismisses only its own still-current route after successful
navigation; a delayed operation cannot pop another route or a newer citation.
Chapter-turn gestures are suppressed while the surface is open, and closing
restores the underlying focus and scroll.

Unknown translations and invalid/missing references preserve the service's
error and never substitute a default passage. An installed Bible resolves supported references through its published discovery
and chapter indexes. The online adapter remains the fallback for an uninstalled
Bible; neither path starts a bulk download during an ordinary lookup. Dictionary, commentary, topic and notebook callers reuse these typed
requests and the same preview component.

## Study workflow boundaries

`StudyContext` is an immutable snapshot of the opening Scripture, selected
translation, source verse, language/direction, discovered books and original
UTF-16 selection. Generated verse numbers and paragraph separators never become
lookup or marking text. Resource switching follows this snapshot rather than
silently following later reader navigation.

`NativeScriptureText` uses Flutter's native selectable document without a
competing word-tap gesture recognizer. A delayed single-word action leaves
double-click, long-press selection and scrolling in control. Context menus keep
Copy, marking/remove and inline Note actions and add selected-phrase Search.
`StudyWorkspace` uses a beside-reader panel on wide windows and a keyboard-aware
modal sheet on compact screens, with safe areas, focus traversal and Escape/
back handling. The reader suppresses chapter-turn gestures while a Study/modal
interaction owns focus. Closing leaves its passage/scroll unchanged; explicit
passage opening respects active inline-note drafts.

| Feature | Typed boundary and behavior |
|---|---|
| Search | `SearchRepository` and `OnlineSearchController` request online Search v3 pages, preserve API match order and source verses, deduplicate identities, and reject source/engine revision changes. Reference-kind results are complete selections without pagination. |
| Dictionary | `DictionaryRepository` and `DictionaryController` discover resources, resolve exact index IDs/aliases and repeated definitions, and fetch selected entries. Large native indexes build typed normalized keys in compute; interactive filtering yields cooperatively. Entry/link history is bounded and cycle-safe. |
| Commentary | `CommentaryRepository` and `CommentaryController` read published book/chapter coverage before the selected chapter. Verse matching includes entries anchored earlier whose published ranges contain the selected verse. Introductions are source commentary, not invented Scripture verses. |
| Public topics | `PublicTopicsRepository` and `TopicsController` browse published IDs, reverse chapter associations and partial locale name maps. Follow/Hide is local; only explicit preview/confirmed copying calls `PublicTopicCopyRepository`. |
| Notebooks | `NotebookRepository` and `NotebookController` own private document summaries, selected ordered blocks, autosave, durable draft journals, optimistic revisions and conflict recovery. Canonical verse notes remain in the existing annotation repository. |

Each public feature has its own request ownership and failure state. Replacing
input, changing modules or dismissing a panel invalidates late results without
closing the shared HTTP client. Widgets receive typed values and callbacks;
they issue no HTTP/SQL and decode no service JSON. Public-cache refreshes never
write personal annotations. Private topic copies use distinct IDs, atomic
transactions and service-scoped provenance so repeated copying is idempotent
and public update/removal cannot delete the private group or notes.

`StudyCitation` preserves published reference text, OSIS, covered coordinates
and the resource's original reference provenance. Positive common-canon verse
selections use discovered book names in the selected Bible. Whole chapters and
v2 extended-book IDs use the original source citation rather than assuming v3
book-ID equivalence; Query may report unavailable coverage. Chapter/verse-zero
introductory citations remain explicitly unavailable. No adapter claims automatic
versification conversion.

Schema 3 adds notebook, ordered block and draft-journal tables through a forward
transactional migration from schemas 1/2. Existing verse-note IDs, timestamps,
markings, groups, settings and Scripture stay intact. Autosave writes the draft
journal before document activation; failure retains an editable draft and Retry.
Independent editor identities and base revisions prevent one local editor from
overwriting another editor's document or deleting its newer journal. A conflict
can be saved explicitly as a new notebook. A pending debounce/write is not a
keystroke-level crash-durability guarantee.

Application shutdown is idempotent: overlapping callers await the same private
flush before SQLite closes. If the latest edit cannot reach its journal,
shutdown fails with a storage error and leaves controllers/database usable for
Retry. Already durable activation conflicts remain recoverable after reopening;
they do not force a successful document overwrite.

Website-compatible backups retain their established reader-data contract. The
separate complete private format includes notebooks, journals and typed Study
settings/copy provenance. The portability controller drains pending private
writes, validates the whole import before mutation and refreshes the open
reader only after a successful transaction. Imported journals remain recoverable
without silently activating them. Cache deletion preserves private tables.

Shared controllers, typed repositories and platform database/file adapters keep
the six target platforms on one architecture. Optional signing and automated
GitHub publication are separate from store submission. Bundled localization,
native runtime acceptance and worker measurements are implemented; human
linguistic review, physical-device accessibility/suspension and store approval
remain separate evidence. Feature tests and composed journeys do not substitute
for those gates.

## Decision record ADR-002: portability and installed-resource ownership

The next implementation extends the existing repository boundaries with two
separate responsibilities. A complete, versioned private backup preserves
notebooks, recoverable drafts, annotations and user settings. The existing
website-compatible v1/v2 import and v2 export contract remains available;
legacy readers must not be presented with notebook data they cannot interpret.
Imports must validate the complete bounded document before a transactional
merge and preserve distinct conflicting work and its references.

Explicit offline installations own public resource generations and their
derived indexes. Downloading, validation and indexing happen in a staged
generation; only a fully validated generation may replace the active one.
Cancellation, process interruption, storage failure and resource removal must
never remove private records or invalidate the last usable installation.
Transient cache eviction and installation removal are separate operations.

Bible, dictionary, commentary and topic adapters supply source-specific
discovery and indexing behind a shared installation contract. Reader, Query,
Search and Study consume typed installed adapters through their existing
repositories. Normal online use starts no bulk download. Offline Search must
identify its supported filters and source explicitly. Large parsing/indexing
requires native workers and a browser-worker or bounded cooperative strategy;
Flutter Web compute alone does not provide background execution.

This decision establishes implementation boundaries, not a completion claim.
Current implementation and verification evidence belongs in the existing
backup, API/cache, feature-parity and testing documents.

## Portability and offline composition

`AppState` owns the portability and offline controllers alongside Study. Native
file access is behind `TextFileService`; the platform adapter bounds input before
decoding and reports cancellation independently of failure. Widgets only present
typed import previews, progress and export actions. The complete backup contract
is versioned independently of website v2 so an older importer cannot mistake a
partial restore for full notebook support.

`OfflineResourceStore` owns schema-5 installation generations, documents, search
rows and interruption leases. Source-specific installers fetch published bulk
files, validate exact bytes and publication consistency, and stream bounded
index batches from a native isolate or the bundled browser worker. Only the
activation transaction changes the visible generation. Installed adapters pin a
generation and reject changed snapshots; they do not splice different revisions.

Closing the app drains private portability and offline work before closing
SQLite. Failure to journal a private edit leaves the database and controllers
available for Retry. Closing an offline panel alone does not cancel a requested
installation. Ordinary startup reads installed metadata locally and makes no
catalogue or bulk-download request.

## Decision record ADR-003: integrated reader and artifact promotion

The final integration keeps topic reconciliation, contextual resource discovery
and route ownership behind application and repository boundaries. Public topic
memberships retain their source identity independently of personal memberships;
reconciliation is transactional and must preserve private records. External
links and browser history use the same guarded passage-opening operation as
reader navigation, so an incoming route cannot silently discard an active draft.
Interface translations apply only to application messages, never Scripture,
resource text or private names.

GitHub Releases distribute the immutable installers already produced by a
successful supported-host CI run. Promotion validates the source revision,
shared version metadata and every package checksum before publishing. It does
not rebuild binaries, change their version or replace an existing published
version. Alpha, beta and release-candidate channels remain prereleases.
Optional signing remains independently configured per platform; absent keys
leave development packages available without implying store approval.

Automated host, simulator and browser evidence is recorded separately from
physical-device, assistive-technology and store acceptance. Downloadable test
installers must state their architecture, signing state and installation limits.

## Startup and shutdown ownership

`AppBootstrap` displays loading and a non-destructive Retry surface while local
storage opens. Its factory owns cleanup of partial initialization; the bootstrap
closes a completed resource if its surface was removed before handoff. Once
handed to the production reader, the reader session owns shutdown. Injected test
or host states retain their caller's lifetime. `LocalDatabase.fromExecutor`
releases a failed open/migration executor before Retry and preserves the original
failure even if cleanup also fails. It never resets an existing database.

Web startup rejects Drift's purely in-memory fallback for production private
storage, because appearing to save data that disappears at the next launch is
unsafe. Explicit in-memory test databases remain available. The recovery surface
explains storage permissions/capacity and does not recommend clearing site data.
Desktop cancellable exit awaits durable writes; notebook lifecycle flush errors
retain their drafts and expose recovery. Forced process termination can still
interrupt an uncommitted edit.

## Integrated reader boundaries

`ReaderRouter` owns address-bar/native-link transitions; `AppState` owns passage
request cancellation, validation and persistence. A single persistent page keeps
inline drafts and focus through URL changes. Previewing Scripture stays separate
from explicitly opening it. `SourceAnnotations` presents typed source metadata
and shared citation actions outside original selectable Scripture text.

`UnifiedBookmarksController` discovers public metadata and coordinates explicit
membership operations through a repository. `SqlUnifiedBookmarksRepository`
commits reconciliation, origin-preserving memberships and active/recent group
remaps transactionally. The database owns identities; a translated display label
alone never establishes ownership when multiple private matches exist.

`DictionaryDiscovery` owns bounded concurrent index/definition discovery and
confirmed choices. Installed and online repositories share the actual background
index parser. A native/Web worker keeps large parsing away from the UI event
loop; the controller owns cancellation, scope, partial failures and history.
Widgets render these states without issuing raw HTTP or SQL.
