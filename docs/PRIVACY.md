# Privacy policy draft

getBible.live is a local-first Bible reader implemented with Flutter. Notes, markings, preferences, reading position, and cached Scripture are stored on the user’s device. The application does not require an account and does not include advertising, analytics, behavioral tracking, or cross-device synchronization.

The application connects to GetBible services to retrieve translation metadata and Scripture. The network provider may process ordinary connection information such as IP address and request time as necessary to serve requests and protect the service. User notes and markings are not sent with Scripture requests.

Reference previews connect to the public Query v3 service only for an explicitly
requested Scripture lookup. The request contains the selected Bible translation
and the user-entered reference, or selected verse coordinates expressed using
that translation's discovered book names. A source-language citation label is
kept for display when structured coordinates are used. The app does not send
private note text, marking text, marking groups, backups or reading history to
Query. Opening a preview creates no account, tracking record or cloud copy of
private reader data in the application.

Users can export reader data to a file, import a compatible backup, or delete local reader data. Files shared through the operating system are handled by the destination selected by the user and are subject to that destination’s privacy terms.

Translation text and metadata may be governed by their respective copyright and license terms. This draft must be reviewed against the final binaries, hosting logs, store disclosures, jurisdictional requirements, and published contact details before release.
