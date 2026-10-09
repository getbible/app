# Public topics and private copies

The Study Topics workspace reads the public [GetBible Bookmarks v1 API](https://getbible.net/api/bookmarks/v1/). It discovers the current index, summary catalogue and available name languages, then requests one selected topic or the current chapter's reverse associations. Ordinary browsing never downloads `all.json` or `catalog.json`, installs a corpus, or writes to the public service.

`PublicTopicsRepository` is the domain boundary. `ApiPublicTopicsRepository` owns transport and the strict static-document adapters; `TopicsController` owns cancellation, local choices and independent resource errors; `TopicsPanel` renders native controls and delegates Scripture to the shared Query preview. Closing or selecting another topic invalidates late reads. The shared transport belongs to the application, so dismissal does not close another panel's HTTP client.

Topic summaries have an integer `verses` count. Individual topic files have sorted, unique coordinate triples and translated names. IDs come from the published catalogue, never from English names, aliases or translated labels. Partial locale documents fall back to canonical English names. The index's checksum describes the complete public catalogue and is retained as its revision identity. After a changed revision, resources are revalidated, including a previously cached topic that has since been deleted. HTTP 404 remains an unavailable resource; a successful empty reverse map means there are no associations.

The public coordinates cover books 1–66. That dataset limit does not change Bible v3 discovery, navigation or extended-book reading. Unsupported contextual chapters show the limit while the full topic browser remains usable. Selecting a chapter association requests a structured reference in the user's selected Bible. Query resolves discovered book names, bounds batches and reports unavailable verses without substituting a different translation or successful partial Scripture.

Follow and Hide are local settings keyed by the service root and stable public topic ID. They never create private markings, notes or groups. Public refresh does not enter the annotation repository. Preference restoration disables those actions until their saved state is known, and failures remain independent of readable public data.

Copy to my markings first presents the target name and new/already-present association counts. Confirmation creates an independent private group with a freshly allocated `private-topic-` identity, then canonical whole-verse markings. Private starter/custom IDs and names are never reused to identify that destination. The local SQL adapter records scoped provenance and commits group, markings and provenance in one collision-checked transaction. A failed transaction rolls back every insertion. Imports through the adapter are serialized; the database rechecks identities and provenance against independent writers.

Copying the same topic again adds only missing canonical identities. Existing private names, colors, quote text, creation dates and inline notes remain unchanged. Later public removal does not delete the copy; an explicit later copy can add new coordinates while retaining earlier private associations. If the user deletes their entire copy group, an explicit copy can create a fresh independent group. No automatic synchronization is implied.

Complete private backups include scoped copy provenance and Follow/Hide choices alongside copied groups and markings. Website-compatible v2 exports retain reader data and supported source fields, but omit these additional private settings. Importing an older website backup therefore does not restore those choices or copy-destination preferences. Public cache or installed-resource removal never deletes private copied annotations.

`test/public_topics_test.dart` covers the published and constructed positive documents, shape/identity failures, partial names, empty reverse maps, exact lazy GET routes, invalid-response cache recovery, catalogue revision/deletion, local-only choices, extended Bible IDs, late request ownership, collision rollback, preservation of existing groups/notes, duplicate-safe/additive copies and deletion/recreation. Native widget tests exercise selected-Bible previews, explicit confirmation and a narrow 200% text surface with scrollable content. Positive fixtures are independently validated against the current live OpenAPI JSON Schema. Physical-device selection, clipboard, accessibility and store review remain platform release gates.

## Complete offline public topics

**Set up offline use** explicitly downloads `all.json` with `index.json` and
`checksums.json`. The index's checksum must equal the exact full-body SHA-256;
both requested paths must retain the same manifest hashes through final
verification. Workers validate the complete dataset and derive topic summaries,
individual topics, localized name maps and chapter reverse associations before
atomic activation. A bulk topic is not parsed as an individual topic: its
`names` are assembled from the bulk locale documents, preserving partial locale
coverage and English fallback. Unknown locale/topic IDs remain unavailable.

`InstalledPublicTopicsRepository` reads this complete snapshot without HTTP after
restart and uses the same public-topic source scope as the online repository.
Missing reverse indexes represent no associations only for valid canonical
chapters within the still-active complete generation. A replaced generation
cannot be mistaken for an empty chapter. The panel identifies the installed
source and offers **Set up offline use**. Topic coordinates still require the
chosen Bible to be available for Scripture preview; public-topic installation
contains no Scripture text and never silently downloads a Bible.

Uninstalling the public dataset removes only its owned public generation.
Independent **Copy to my markings** groups, copied markings, local choices,
copy provenance and private verse notes remain intact. The complete-module
suite exercises a private copy before removal and a duplicate-safe repeat copy
after removal, in addition to locale and reverse-index equivalence.

On 9 October 2026 the processor validated the generated source repository's
complete `all.json` (218,400 UTF-8 bytes) against the exact SHA-256 published in
its `index.json`. Its 61 topics and 54 locales produced 653 local documents.
This verifies real bulk locale composition and reverse associations independently
of the constructed fixtures. Source:
[`getbible/bookmarks`](https://github.com/getbible/bookmarks/tree/main/v1).
