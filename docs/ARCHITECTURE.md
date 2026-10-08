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
