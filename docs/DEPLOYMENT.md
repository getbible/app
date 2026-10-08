# Deployment and distribution

## Android

Install Flutter stable, Android Studio, required SDK/platform tools, and accept licenses. Verify `life.getbible.mobile`, display name, manifest network permission, deep-link intent filters, icons, and launch theme.

Create a private upload keystore outside the repository. Configure signing through local `key.properties` or CI secrets; never commit either. Build:

```bash
flutter clean
flutter pub get
flutter build apk --release
flutter build appbundle --release
```

Upload the AAB to an internal Play Console track, complete Data Safety/content rating/store listing, test install/upgrade/deep links, then promote deliberately.

## iOS/iPadOS

Use macOS/Xcode, set the team and provisioning for `life.getbible.mobile`, enable associated domains if universal links are shipped, and confirm privacy manifests/usage strings. Build an unsigned validation artifact with:

```bash
flutter build ios --release --no-codesign
```

For distribution, archive in Xcode, sign with an Apple Distribution identity, upload to App Store Connect, test through TestFlight, and submit after metadata/privacy review.

## Desktop and web targets

Validate Windows on Windows and macOS on macOS; a Linux or web build does not
validate those runners. The macOS debug/profile and release sandbox entitlements
include `com.apple.security.network.client` for public HTTPS Scripture, Search
and Study requests. Exercise actual HTTPS in the sandbox before distributing a
signed archive. Windows packaging/signing, macOS notarization and store-specific
entitlements remain release work on the relevant host.

Linux release validation uses `flutter build linux --release`. Web validation
uses `flutter build web --release --base-href /flutter/` for the retained path;
verify deployed URLs, browser CORS and storage behavior separately. A server's
successful CORS preflight is supporting evidence, not a browser-runtime test.

Native Study uses no embedded browser, additional account service or telemetry.
Complete notebook portability, installed offline resources, full localization,
device accessibility and store metadata remain roadmap steps 12–17. Development
builds and unsigned Android release outputs are validation artifacts; they are
not a signed store submission.

## GitHub release

Tag only a green, reviewed commit. A release workflow should produce checksums and unsigned/test artifacts; store-signed artifacts should come from protected CI environments or store pipelines. Release notes must enumerate user-visible changes, migrations, known limitations, and backup compatibility.

## External access required

- Google Play Console application ownership and upload signing configuration
- Apple Developer team, certificates/profiles, and App Store Connect role
- Domain hosting access for Android Digital Asset Links and Apple association files
- Final legal approval of translation attribution and privacy/store text
