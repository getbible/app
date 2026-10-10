# Online Search v3

The reader requests pages from `https://search.getbible.net/v3/{translation}?q=...`.
Opening Search or searching a selected phrase does not install, download or scan
a whole translation. Online is the default. The explicit **Installed Bible
(offline)** choice searches only a deliberately installed and verified Bible;
it never downloads a Bible or falls back to HTTP.

## Ownership

`OnlineSearchCriteria` and `OnlineSearchRequest` capture immutable, bounded
inputs. `SearchRepository` is the domain boundary. `ApiSearchRepository` maps
those inputs to the shared `ApiTransport`, validates the native envelope and
associates each ordered match with its actual verse ID. Widgets never issue
HTTP requests, parse JSON or scan a corpus. `OnlineSearchController` owns request
cancellation, pagination, deduplication and retry state independently from the
reader's passage and annotations. `SearchPanel` is reusable native content for
a compact full-screen route or an adaptive Study pane.

The familiar Exact word mode maps to `whole_word`; Partial word maps to
`substring`. All/Any/Phrase, case sensitivity, Bible/testament/deuterocanon
scope, repeated discovered book IDs, Fold/Exact diacritics, exclusions,
All-words proximity and canonical/relevance order are typed criteria. Locale
is deliberately absent from online requests: the API owns Unicode, script and
diacritic matching. A selected phrase reaches `q` unchanged, including original
whitespace and Unicode characters.

## Consistent pages and references

The first page requests 25 verses. A next page is requested when the user
approaches the end or presses Load more. Its offset is the previous API offset
plus the **actual returned count**, rather than the requested limit or the
number left after client deduplication. Result order comes exclusively from
`matches`; grouped chapter or verse-array order never determines ranking.
Duplicate verse identities are skipped while the original order is retained.

The first page's translation-source SHA, engine version, result kind and total
must agree with later pages. A change preserves the loaded page and offers
Restart search; it never appends a second revision. No request can exceed offset
10000. If more matches remain, the panel states the bound and asks the user to
narrow the criteria. The summary distinguishes loaded matches from the API's
total, including pages whose duplicate identities reduced the displayed count.

`query.kind == reference` is a complete resolved passage. The supplied full-text
filters and page limit are not applied locally; all returned verses are shown
and no next-page control is offered. An empty full-text response is a valid
zero-result state. Invalid pagination or an incomplete reference is rejected
before it becomes visible. Schema-invalid HTTP cache bodies are discarded so
a corrected retry can reach the service.

Input and filter changes now start a search after 250 ms of inactivity, matching
reference commit `098eeaa`'s `app/page.tsx`. Enter and the Search action submit
immediately and cancel the pending timer so the request is sent once. Blank
input clears results without requesting an empty search. Each input change,
repeated submission, translation change or close invalidates the prior request
token and pending timer. A late request cannot replace or append to current
results. A late result-opening failure also cannot overwrite a newer search's
state. Disposal and context replacement cancel pending startup/debounce callbacks
without notifying a locked widget tree. Closing never closes the shared transport.
Rate-limit/temporary-error Retry-After intervals disable the Retry action until the requested pause has
elapsed, in addition to the transport's bounded retry budget.
The service pause survives clearing/closing Search and resubmitting another
query or translation, so the Search action cannot bypass the server's pause.
Reopening a paused search restores its Retry timer. Widget initialization,
context replacement and disposal invalidate requests without notifying locked
ancestor widgets; explicit user actions continue to notify normally.

## Original Scripture and accessibility

Hits retain the full rich `Verse`, lexical/source fields, returned terms and
Scripture direction. `SearchPanel` renders them with native selectable rich
text. Opening a hit identifies its exact verse rather than its index in an
assembled chapter. Temporary emphasis maps only safely locatable returned
terms into original UTF-16 ranges with an exact quote. It does not transform
Scripture or reconstruct the server's search algorithm; an unlocatable folded
term remains plain. Combining sequences and supplementary characters are
preserved. Exact alphabetic terms avoid underlining adjoining words, and case
sensitivity applies to emphasis.

Native filter, result-summary and action messages use the UI locale; Scripture,
Bible names and returned references keep their source values. Filters and results
share one scrollable surface, allowing safe use below a
keyboard and at large text sizes. Dropdowns have bounded widths, full semantic
labels and native keyboard behavior. Result errors stay visible beside already
loaded Scripture and provide explicit retry or restart actions.

## Verification and sources

Run:

```bash
flutter test test/online_search_test.dart test/search_panel_test.dart
flutter test test/app_state_online_search_test.dart
flutter test test/search_reader_navigation_test.dart
```

The suites cover all request filters and encoding, explicit false/zero values,
rich lexical fields, relevance ordering, compact direction fallback, a
120-verse reference despite `limit=1` and restrictive filters, actual-return
pagination/deduplication, source/engine rotation, cancellation, repeated input,
rate-limit retry, zero results, the offset ceiling, malformed-cache recovery,
original Unicode emphasis, and a 320-pixel RTL panel at 200% text scaling.
The application-composition suite proves that Search reuses the injected reader
transport, requests no Bible/corpus resource, and preserves private annotations
and the persisted reader position. Failed result opening retains the search
surface and presents its error.
Composed reader regressions exercise successful Open, reopening/closing,
dismissal during a pending search, and query replacement during delayed Open,
including actual AppState/Provider/widget lifecycle ownership.
Reader/platform integration and physical-device QA remain additional release
gates; these focused tests do not establish store readiness.

The implementation follows the official [Search v3 guide](https://getbible.net/api/search/v3/)
and [live OpenAPI contract](https://search.getbible.net/v3/openapi.json), inspected
on 8 October 2026. The contract SHA-256 is
`6f657fb26f16046bc307da855b6c4ba593ea5fba5ad0dee2bdee2157d15b7f9c`.
`test/fixtures/search_v3_rich.json` records the positive rich envelope used by
the repository regression suite.


## Installed Bible search

The source selector makes the choice explicit. `InstalledSearchRepository` reads
immutable installed-generation records through the same typed search boundary.
SQLite narrows literal candidates in its database worker; the adapter processes
100 rows at a time, yields between batches and retains only the requested page.
It does not load or scan every installed translation in memory. Search receives
original rich verses, including lexical information and source direction.
A removal or revision change during a search requires restarting that search.
The server's Retry-After pause remains attached to Online search and does not
prevent an independent local operation.

Offline capabilities are deliberately visible:

| Criterion | Installed behavior |
|---|---|
| All / Any / Phrase | Supported, using Unicode letters/numbers/marks as words. |
| Exact / Partial word | Supported; partial phrase matches the unchanged substring. |
| Case sensitive | Supported; insensitive matching uses Unicode lowercase. |
| Bible / Old / New / selected books | Supported; Old uses established IDs 1–39 and New 40–66. Whole Bible and individual selection include all installed extended IDs. |
| Exclusions | Supported, one word per comma-separated exclusion, matching the selected word mode. |
| Diacritics | Exact only; spelling and combining sequences are not normalized. |
| Result order | Canonical book/chapter/verse order only. |
| Proximity / relevance / diacritic folding / Deuterocanon scope | Explicit validation error; choose Online to use these features. |

Selecting Installed sets the visible diacritics/order fields to their supported
values and clears proximity. Unsupported criteria submitted programmatically are
also rejected. Extended source IDs are not guessed to belong to a testament;
choose their individual books instead of Deuterocanon scope. A missing installation displays an installation instruction; it
is never represented as a successful zero-match corpus. For continuous scripts
without spaces, Partial word can find a substring within the source word group. The query is bounded to
50 words, 500 characters and the shared 100-result/10,000-offset pagination limit.

References resolve against the installed Bible's published names and actual
verse identities: `John3:16`, `John 3:16,18-21`, whole chapters and up to eight
semicolon-separated selections. Unknown aliases, missing verses inside a range,
introduction-only chapters and selections exceeding 200 verses are errors.
Full-text filters do not alter a successfully resolved reference. The complete
selected reference is shown regardless of the page size.

The native worker, actual SQLite restart, rich-text preservation, interrupted
revision/update, request isolation, reference bounds and offline search are
exercised in `test/installed_bible_test.dart`. Browser execution of the same
compiled resource worker is a separate smoke-test gate.
