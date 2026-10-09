# Privacy policy draft

getBible.live is a local-first Bible reader implemented with Flutter. Canonical
verse notes, study/sermon notebooks, draft journals, markings, preferences,
reading position and cached Scripture are stored on the user's device. The
application does not require an account and does not include advertising,
analytics, behavioral tracking or cross-device synchronization.

The application connects to GetBible services to retrieve translation metadata and Scripture. The network provider may process ordinary connection information such as IP address and request time as necessary to serve requests and protect the service. User notes and markings are not sent with Scripture requests.

Reference previews connect to the public Query v3 service only for an explicitly
requested Scripture lookup. The request contains the selected Bible translation
and the user-entered reference, or selected verse coordinates expressed using
that translation's discovered book names. A source-language citation label is
kept for display when structured coordinates are used. The app does not send
private note text, marking text, marking groups, backups or reading history to
Query. Opening a preview creates no account, tracking record or cloud copy of
private reader data in the application.

Online Search connects to the public Search v3 service. It sends the entered
query, or the exact Scripture word/phrase the user explicitly chooses to search,
the selected Bible and chosen filters. It retrieves requested result pages
without uploading a local Bible installation, personal notes or marking data.
Search text is a public network request, so text deliberately entered into the
search field is sent to that service.

Dictionary and commentary browsing retrieves public catalogues, resource
metadata, a selected dictionary index/entry or commentary coverage/chapter.
Surface-word and alias filtering occurs against the chosen dictionary's index
on the device; there is no server definition-text search. Topic browsing
retrieves public topic summaries, selected topic associations, locale names
and the contextual book/chapter reverse index. These public reads do not send
private group names, note/notebook contents, selected-text markings or drafts.

Dictionary/commentary preferences and topic Follow/Hide choices remain local.
Copying a public topic requires an explicit preview and confirmation, then
creates an independent private marking group on the device. The application
does not write to the public topic service or synchronize that private copy.

Notebook references and quotations are saved locally with their Scripture
attribution. Previewing or opening a notebook citation sends only its explicitly
selected Scripture reference/coordinates through the shared reader services,
never the surrounding notebook block or complete private document. Editing,
autosave, draft recovery and conflict resolution require no network request.

Users can export a complete private backup to a chosen file and explicitly
merge a validated backup. This includes verse notes, markings, notebooks,
draft journals, reading position, preferences and private topic-copy provenance.
A separately labelled website-compatible export contains only the website's
supported reader data. Backups are plain JSON; they are not encrypted by the
application, and possession of a backup permits reading its private contents.
The app does not upload these files. Saving and sharing occur only on the user's
action, using a chosen local destination or operating-system share target.
Those destinations may have their own storage/synchronization and privacy terms.

Notebook deletion remains a separate explicitly confirmed action in Study.
Public resource/cache removal does not delete private reader data, notebooks or
draft journals. Import is additive and never resets unrelated private data.

Translation text and metadata may be governed by their respective copyright and license terms. This draft must be reviewed against the final binaries, hosting logs, store disclosures, jurisdictional requirements, and published contact details before release.
