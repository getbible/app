# Architecture

## Decision record ADR-001

The app uses a layered, local-first architecture. Flutter widgets depend on application state, application state depends on repository contracts, and data adapters implement those contracts. This makes the persistence and future synchronization boundaries explicit without claiming a synchronization backend exists.

Provider/`ChangeNotifier` currently supplies the small application state surface. GoRouter is pinned for the planned canonical deep-link graph. If state complexity grows, migration to Riverpod should be one deliberate ADR rather than mixing state systems feature by feature.

SQLite is the system of record. Drift supplies cross-platform executors and background native database creation. Models perform strict, versioned serialization rather than accepting loose maps throughout the application.

## Runtime flow

1. `main.dart` initializes Flutter and opens the database.
2. `AppState` loads preferences and last reading position.
3. `CachedBibleRepository` gets translation/book/chapter data.
4. The repository checks cached records, expiry, and API hashes.
5. `ReaderScreen` renders typed chapter data and reports cache freshness.
6. Annotation/settings repositories persist user actions immediately.

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
