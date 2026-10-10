# Native UI localization

The selected Bible's language chooses the reader's UI pack. Scripture, resource
names, module definitions, source attribution, user topic names, notes and
notebooks retain their original content. Localization never sends those values
to a translation service. Interpolation inserts those values only on the device.

## Reference contract

`lib/core/web_ui_catalog.dart` and `assets/locales/` are synchronized together
from the reference application's `lib/i18n.ts` and `public/locales/`. The keyed
English catalog provides the fallback for the positional translations. The
pinned source revision and key order are recorded in
`test/fixtures/ui_locale_contract.json`.

The current reference bundles 69 locale codes and 282 messages. Of those packs,
52 contain translations. English is defined by the keyed catalog; 16 other
language codes currently use the reference's explicit English fallback:
`br`, `ch`, `chr`, `enm`, `eo`, `eu`, `gd`, `gv`, `la`, `mn`, `nd`, `pon`,
`pot`, `sn`, `tlh`, and `tpi`. These are bundled language choices, not a claim
that 69 distinct languages have been translated or reviewed. Historical-language
aliases follow the reference generator, including Hebrew for `hbo`, Greek for
`grc`, Russian for `cu`, Arabic for `cop`/`syr`, and German for `got`.

`UiStringsScope` wraps the navigator so dialogs and pushed routes use the same
pack and update with it. Flutter's Material, Cupertino and native selection
controls use the corresponding framework localization where supported, with an
explicit English fallback otherwise. UI direction follows the effective UI
language. Scripture and source content keep their independently supplied
direction. Large-text, RTL and placeholder contracts have automated coverage;
human linguistic and physical screen-reader review remain release acceptance.

## Native extensions

Backup/restore, notebooks, offline installations and other native-only controls
use explicit literal templates through `UiStrings.of(context).text(...)`.
Existing reference phrases reuse their reference translations. Remaining
phrases have stable named keys in `lib/core/native_ui_catalog.dart` and committed
JSON packs in `assets/native_locales/`. Do not pass Scripture or arbitrary user
content into this API. Variable values belong in a separate named map:

```dart
UiStrings.of(context).text(
  'Downloading {name}',
  {'name': resource.title},
)
```

The inventory command scans only explicit UI calls. A small reviewed list in
`tool/native_ui_defaults.json` registers UI-owned labels returned by framework-
independent file/status services. Those services stay independent of Flutter.
A malformed/missing pack or translated placeholder falls back per message;
private content is never transformed to fill a translation gap. Substitution is
one pass, so braces inside a source name cannot become another placeholder.

Native extensions are machine translated using the reference project's public
UI translation policy. `assets/native_locales/provenance.json` records original
English templates, effective locale targets and review status. It explicitly
marks human review as pending. Historical aliases and intentionally empty
reference packs retain the same fallback policy; failed new translations are
reported as failures, not silently declared translated.

## Updating packs

From the repository root, with the pinned Dart/Flutter SDK and a current checkout
of the reference application:

```bash
dart tool/sync_web_locales.dart ../app.getbible.life
python3 tool/ui_locale_inventory.py
dart format lib/core
python3 tool/translate_native_locales.py --write
flutter test test/ui_strings_test.dart test/localization_contract_test.dart test/source_annotation_localization_test.dart
```

The translation step is an explicit maintainer action requiring internet access.
It submits only the public English UI catalog. It uses no application accounts,
API keys, backups or user data. It preserves existing translations whose original
English template is unchanged, validates message boundaries and placeholder
identities, and stores complete language packs atomically. Partial progress is
recoverable; errors return a nonzero status. For a single language, add
`--locales af`; normal generation uses two concurrent sessions and can explicitly
use up to four with `--workers 4`.

Commit the reviewed resulting JSON and generated catalog. CI and application
runtime never invoke the translation endpoint. Builds remain deterministic and
can use the committed packs offline. Run `python3 tool/ui_locale_inventory.py
--check` to detect new unregistered native templates and
`dart tool/sync_web_locales.dart ../app.getbible.life --check` to compare a checked
out reference revision. Locale tests verify exact key coverage, valid placeholders,
source preservation, region aliases, RTL, route inheritance and safe fallback.
