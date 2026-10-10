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

## Acceptance evidence

Implementation is in progress. Record exact test/build evidence here before
marking the pull request ready. Required coverage includes naming in packaged
metadata and documentation; every Scripture sharing path; inline verification;
licensing attribution; dictionary selection and related entries; direct verse
bookmark access; additive memberships; topic verse content; return navigation;
compact and wide layouts; large text/RTL; offline and failed requests.
