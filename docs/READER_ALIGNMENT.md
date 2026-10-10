# getBible identity and reader alignment

This change follows the agreed product review of 10 October 2026. The product
name is exactly **getBible**. The screenshots supplied by the maintainers and
the reference reader define the intended interaction, spacing and hierarchy;
colors and typography follow the reader preferences.

## Alpha identity reset

This application has not launched. Maintainers explicitly require a clean
identity correction, with **no migration or upgrade compatibility layer** for
previous alpha installations. Developers uninstall the old alpha before
installing the corrected build. Existing development data is not automatically
moved to renamed application directories or databases.

Use `getBible` for display names and `getbible` for package identifiers where
lowercase syntax is required. Remove product-name domain suffixes from source,
platform metadata, installers, build artifacts, artwork and documentation.

## Canonical destinations

- Reader website and generated Scripture links: `https://app.getbible.life`.
- General documentation and licensing attribution: `https://getbible.net`.
- Verification explanation API link: `https://getbible.net/api/bible/`.

Documentation links do not replace the Bible, Query, Search or study service
endpoints. Product-owned links must share one explicit configuration contract.

## Required reader behavior

- Translation licensing ends with the book artwork, "The Word for the world!"
  and "Powered by getBible APIs.", linking to the general documentation.
- The verification control toggles a compact dismissible explanation beneath
  the chapter header and distinguishes verified and saved/offline content.
- Contextual Study uses a spacious centered dialog on wide windows and an
  accessible compact presentation. Passage context, selected text, Search
  selection, Dictionaries and Commentaries are immediately understandable.
- Dictionary choices contain confirmed definitions for the current selection;
  related-entry navigation must retain this contract. Lexical identifiers are
  actionable, multiple definitions remain readable and failures are truthful.
- Each verse has a direct bookmark action. Its menu shows existing clickable
  topic memberships and expands Add another topic into a searchable scrollable
  list. Adding one topic never removes another.
- Topic detail shows reference, translation, provenance and actual Scripture,
  resolved through the existing Query repository with bounded lazy loading.
  Personal saved quotations remain independent of fetched display text.
- All topics and Back to verse preserve the originating passage and position.
- Layout, text scaling, keyboard focus, RTL and themes remain native Flutter.

## Automatic offline defaults

The selected Bible is prepared in the background; other translations are not
downloaded automatically. All catalogue-discovered dictionaries/commentaries
are acquired by default through one queue. **Downloads & storage → Keep
offline** persists a per-module choice; disabling it removes the local copy and
keeps automatic acquisition off. Public topic choices come from Bookmarks v1
metadata or its saved copy, never hardcoded topic lists. The complete bookmarks
dataset is manual opt-in and stays removed until explicitly requested again.

Startup, resume and resource use check persisted successful source checks after
30 days. Unchanged hashes avoid bulk redownload; changed content activates only
after complete validation, with the last good generation retained on failure.
**Check for updates** bypasses the interval. **Clear downloads** retains private
data and exclusions, while default resources can return on the next startup/use.
These operations run while the app is active and do not imply closed-app OS jobs.

## Acceptance evidence

Implemented in [pull request #7](https://github.com/getbible/app/pull/7) for
`1.0.0-alpha.5+6`, against reference source
`098eeaa06c75efde4a3c75a9984d66ac987add30`. The alpha identity correction has no
upgrade/migration layer. Existing database-schema and backup-validation tests
remain relevant to ordinary data integrity; they do not migrate old app names.

The composed reader tests exercise direct verse bookmarks, additive membership,
Query-loaded topic Scripture, exact return navigation, canonical outbound links,
inline verification and the licensing footer. Wide/light and compact/dark/RTL
layouts are covered, including 200% text, a 320px viewport and a visible keyboard.
Dictionary tests cover confirmed choices, all definitions, in-flight Back and
nested lookup cancellation. Actual native Copy semantics, keyboard and toolbar
paths preserve original Scripture without presentation markers.

Actual Flutter widget captures were inspected with loaded fonts: wide Study,
compact memberships and the compact keyboard layout. That review found and
corrected a clipped dictionary selector and excess popup height. Geometry and
content-height regressions now protect both corrections; very short enlarged
menus scroll their entire contents to keep all actions reachable.

Local analyzer, formatting, product-identity, locale/inventory and developer/
release-tool checks pass. Linux and web release compilation succeeded during
this increment. Full-suite evidence and hosted platform gates are recorded in
[Testing](TESTING.md#identity-and-reader-alignment-alpha5). Only the checks on the
final PR head establish native package/runtime acceptance. Signing and store
submission remain separately configured; physical-device and human translation
review are not implied by automated results.
