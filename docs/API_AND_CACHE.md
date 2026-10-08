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
| Full translation | `/{translation}.json` | Deliberate existing offline/search download; verify its own `.sha` and exact bytes. |

Bible routes have no query parameters. Book IDs are positive source identifiers, including large deterministic IDs; there is no fixed 66-book limit. Verse text remains exactly as received, including whitespace, line endings and UTF-16 code-unit positions. Models retain optional lexical tokens, spans, source attributes, editorial entries, titles, introductions and unknown additive fields. Static and nested chapters share the same verse/enrichment adapters. Known malformed enrichment is rejected during parsing before activation.

Persistent keys include service, API version and serialization version; configured alternate origins receive an additional source scope. For example, the default source uses `bible:v3:s2:chapter:kjv:1:1`. Schema-one cache rows migrate to `bible:v2:s1:*`; they remain readable only as explicitly legacy, unverified fallback. They are never checked against or relabeled with v3 hashes. The on-device database name and all private annotation/settings identities remain unchanged.

Freshness states are `fresh`, `cachedVerified`, and `cachedUnverified`; repository results also identify legacy provenance. Index reuse respects the received `Cache-Control`, `Age`, date/expiry and no-cache policy, with seven days as an additional maximum. Missing freshness headers are conservative: saved indexes require another online request. No-store bodies are returned to the caller without replacing persisted Scripture. Saved content remains readable, with an unverified indicator, when the network cannot verify it.

Activation reads the SHA-1, downloads and fully parses the JSON, hashes its **original bytes**, and reads SHA-1 again. Both source hashes and the byte digest must agree. Source rotation or a mismatched body retries once. Only a validated snapshot reaches the single-row SQLite upsert; earlier failure leaves the last-known-good row intact. Cached chapter/book/full bodies retain the original JSON text, allowing their exact digest to be checked again before a network-verified result. Storage bookkeeping failures cannot hide successfully validated network Scripture.

Catalogue hash changes invalidate only the exact resource or its delimiter-separated descendants. SQL uses literal `substr` matching instead of wildcard `LIKE`, so book/chapter 1 cannot invalidate 10, and `%`/`_` never become wildcards. Changed Scripture verification is expired while its readable bytes remain saved; subordinate discovery indexes are removed. Clearing Scripture caches preserves private notes, marking groups, settings and caches owned by other services.

Introduction-only nested records have no standalone chapter file. Chapter discovery merges their published nested chapter IDs with the normal index. Book-level titles/introductions appear as an internal introduction navigation node with chapter 0 and no verse. This is a reader sentinel, never a published Bible chapter or an invented Scripture coordinate: the repository reads and verifies the book representation and does not request `/0.json` or `/0.sha`. An ordinary chapter index remains usable when optional book metadata is unavailable.

Native book/corpus decoding, source-model construction and SHA-1 calculation run through a bounded Flutter compute worker. The worker also returns the original JSON text, avoiding another large re-encoding during activation. Flutter Web compute runs on its existing event loop; cooperative/worker corpus processing and installation are explicitly part of the later complete offline-resource workflow.

Whole-translation installation/indexing and using an installed corpus for every reader/query/search operation are separate later work. The current deliberate corpus download preserves and verifies enriched source data without claiming that complete installed-resource workflow.
