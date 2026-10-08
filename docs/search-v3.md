# Online Search v3

The reader requests pages from `https://search.getbible.net/v3/{translation}?q=...`.
Opening Search or searching a selected phrase does not install, download or scan
a whole translation. The existing local search service is reserved for the
explicit installed-Bible capability in the later offline-resource increment.

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

Each input change, repeated submission, translation change or close invalidates
the prior request token. A late request cannot replace or append to current
results. Closing never closes the shared transport. Rate-limit/temporary-error
Retry-After intervals disable the Retry action until the requested pause has
elapsed, in addition to the transport's bounded retry budget.

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

Filters and results share one scrollable surface, allowing safe use below a
keyboard and at large text sizes. Dropdowns have bounded widths, full semantic
labels and native keyboard behavior. Result errors stay visible beside already
loaded Scripture and provide explicit retry or restart actions.

## Verification and sources

Run:

```bash
flutter test test/online_search_test.dart test/search_panel_test.dart
```

The suites cover all request filters and encoding, explicit false/zero values,
rich lexical fields, relevance ordering, compact direction fallback, a
120-verse reference despite `limit=1` and restrictive filters, actual-return
pagination/deduplication, source/engine rotation, cancellation, repeated input,
rate-limit retry, zero results, the offset ceiling, malformed-cache recovery,
original Unicode emphasis, and a 320-pixel RTL panel at 200% text scaling.
Reader/platform integration and physical-device QA remain additional release
gates; these focused tests do not establish store readiness.

The implementation follows the official [Search v3 guide](https://getbible.net/api/search/v3/)
and [live OpenAPI contract](https://search.getbible.net/v3/openapi.json), inspected
on 8 October 2026. The contract SHA-256 is
`6f657fb26f16046bc307da855b6c4ba593ea5fba5ad0dee2bdee2157d15b7f9c`.
`test/fixtures/search_v3_rich.json` records the positive rich envelope used by
the repository regression suite.
