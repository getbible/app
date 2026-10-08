# GetBible API and cache workflow

The Bible root is `https://api.getbible.net/v3`. `ApiConfiguration` permits independent service roots, and `ApiTransport` supplies bounded responses, HTTP cache policy, conditional requests, typed failures and cancellation. The Bible client uses the same transport boundary for the separately hosted daily Scripture resource.

| Resource | Endpoint | Cache behavior |
|---|---|---|
| Translations | `/translations.json` | Discover identities and translation source hashes. |
| Books | `/{translation}/books.json` | Discover source book IDs, names, URLs and hashes. |
| Chapters | `/{translation}/{book}/chapters.json` | Discover emitted standalone chapter files. |
| Book content | `/{translation}/{book}.json` | Preserve book titles/introduction and nested intro-only records. |
| Chapter | `/{translation}/{book}/{chapter}.json` | Save original UTF-8 JSON after byte verification. |
| Source SHA-1 | Corresponding `.sha` sibling | Check before download and again before activation. |
| Full translation | `/{translation}.json` | Deliberate corpus download; verify its own `.sha` and exact bytes. Online Search does not request this resource. |

Bible routes have no query parameters. Book IDs are positive source identifiers, including large deterministic IDs; there is no fixed 66-book limit. Verse text remains exactly as received, including whitespace, line endings and UTF-16 code-unit positions. Models retain optional lexical tokens, spans, source attributes, editorial entries, titles, introductions and unknown additive fields. Static and nested chapters share the same verse/enrichment adapters. Known malformed enrichment is rejected during parsing before activation.

Persistent keys include service, API version and serialization version; configured alternate origins receive an additional source scope. For example, the default source uses `bible:v3:s2:chapter:kjv:1:1`. Schema-one cache rows migrate to `bible:v2:s1:*`; they remain readable only as explicitly legacy, unverified fallback. They are never checked against or relabeled with v3 hashes. The on-device database name and all private annotation/settings identities remain unchanged.

Freshness states are `fresh`, `cachedVerified`, and `cachedUnverified`; repository results also identify legacy provenance. Index reuse respects the received `Cache-Control`, `Age`, date/expiry and no-cache policy, with seven days as an additional maximum. Missing freshness headers are conservative: saved indexes require another online request. No-store bodies are returned to the caller without replacing persisted Scripture. Saved content remains readable, with an unverified indicator, when the network cannot verify it.

Activation reads the SHA-1, downloads and fully parses the JSON, hashes its **original bytes**, and reads SHA-1 again. Both source hashes and the byte digest must agree. Source rotation or a mismatched body retries once. Only a validated snapshot reaches the single-row SQLite upsert; earlier failure leaves the last-known-good row intact. Cached chapter/book/full bodies retain the original JSON text, allowing their exact digest to be checked again before a network-verified result. Storage bookkeeping failures cannot hide successfully validated network Scripture.

Catalogue hash changes invalidate only the exact resource or its delimiter-separated descendants. SQL uses literal `substr` matching instead of wildcard `LIKE`, so book/chapter 1 cannot invalidate 10, and `%`/`_` never become wildcards. Changed Scripture verification is expired while its readable bytes remain saved; subordinate discovery indexes are removed. Clearing Scripture caches preserves private notes, marking groups, settings and caches owned by other services.

Introduction-only nested records have no standalone chapter file. Chapter discovery merges their published nested chapter IDs with the normal index. Book-level titles/introductions appear as an internal introduction navigation node with chapter 0 and no verse. This is a reader sentinel, never a published Bible chapter or an invented Scripture coordinate: the repository reads and verifies the book representation and does not request `/0.json` or `/0.sha`. An ordinary chapter index remains usable when optional book metadata is unavailable.

Native book/corpus decoding, source-model construction and SHA-1 calculation run through a bounded Flutter compute worker. The worker also returns the original JSON text, avoiding another large re-encoding during activation. Flutter Web compute runs on its existing event loop; cooperative/worker corpus processing and installation are explicitly part of the later complete offline-resource workflow.

Whole-translation installation/indexing and using an installed corpus for every reader/query/search operation are separate later work. The current deliberate corpus download preserves and verifies enriched source data without claiming that complete installed-resource workflow.

## Online Search and public Study resources

Each service retains its own configured root and native response envelope.
Public Study resources use the shared bounded HTTP cache and request lifetime;
they are not stored as a complete offline installation. Invalid typed documents
discard their own transport-cache representation so Retry can obtain corrected
content. HTTP 404, rate limits, unavailable coverage and offline failures remain
truthful outcomes rather than empty definitions or substituted Scripture.

| Service | On-demand resources | Ownership |
|---|---|---|
| Query v3 | `/{translation}/{encoded-reference}` | Reused reference-preview boundary; never changes reader position until explicit Open. |
| Search v3 | `/{translation}?q=...` with typed filters, `limit` and `offset` | Requested result pages only; no full-Bible download or implicit local corpus search. |
| Dictionaries v1 | `dictionaries.json`, `{module}/metadata.json`, `{module}/index.json`, `{module}/{exact-entry-id}.json` | Catalogue capability plus actual index IDs/aliases determine lookup; no definition-text server search or whole-module read. |
| Commentaries v1 | `commentaries.json`, `{module}/metadata.json`, `{module}/books.json`, `{module}/{book}/{chapter}.json` | Published sparse coverage determines chapter requests; there is no verse endpoint. |
| Bookmarks v1 | `index.json`, `topics.json`, `locales.json`, `locales/{locale}.json`, `topics/{id}.json`, `verses/{book}/{chapter}.json` | Public summaries and individual association/locale files; no online `all.json` or `catalog.json` download. |

Dictionary/commentary OpenAPI paths include `/v1`; the configured endpoint
removes a repeated version segment instead of producing `/v1/v1`. Bookmark
paths are relative to its v1 root. Source identities are percent-encoded as
individual path segments, not derived from translated labels.

Search preserves the service's ranked `matches` order and joins coordinates to
their returned source verses. Match records are not character offsets. Native
emphasis uses safe matches in the original unchanged verse while preserving
lexical/source styling and direction. Search text is bounded to 1–500 Unicode
characters; pages are 1–100 results and offsets 0–10,000. Next offset uses the
actual returned count. Duplicate verse identities do not reorder results.
Changed Bible SHA, engine version or pagination totals require a first-page
restart, avoiding mixed snapshots. The service's reference-kind response is
shown completely, without full-text filtering or pagination. Retry-After pauses
the service interaction even if the user changes filters or resubmits.

Dictionary metadata retains licensing and original reference provenance.
Filtering searches published index keys, aliases and exact IDs; repeated keys
remain separate definitions. A Strong's prefix is a capability hint, never
permission to manufacture a `G`/`H` entry URL. Metadata/index and entry reads
are bounded; indexes above 256 KiB are parsed in native compute and interactive
filtering yields in bounded slices. Flutter Web still decodes JSON on its event
loop; broader browser/device performance profiling is a later gate.

Commentary verse selection includes all entries whose `verses` coverage contains
the selected verse, falling back to the anchor only when range coverage is absent.
Published chapter/verse-zero introductions are displayed as commentary context.
Plain text paragraphs, source order, OSIS, ranges and attribution survive parsing;
there is no HTML renderer or automatic reference-versification conversion.

Bookmark `index.checksum` describes the aggregate `all.json`; it is used as a
dataset revision, not as proof of an individual topic file's checksum. Revision
changes invalidate affected public representations and revalidate selected
resources. The public dataset's 66-book coverage does not restrict Bible v3
reading. Partial topic-name locales fall back to the published English name.
Follow/Hide choices stay local. An explicit topic copy writes private whole-verse
markings in an atomic transaction with collision-safe group IDs and provenance;
online discovery or public deletion cannot modify that private copy.

Dictionary/commentary SHA-256 manifests and bookmark `checksums.json` are
installation integrity contracts for later offline-resource work. This online
Study flow validates typed documents and HTTP policy without claiming complete
manifest-verified installation. Schema-3 notebooks and their journals are private
SQLite documents, independent from every public resource cache. Clearing
Scripture/download caches and legacy reader-data replacement preserve them.
