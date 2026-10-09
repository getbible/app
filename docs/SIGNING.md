# Distribution signing

Unsigned validation builds and signed distribution builds are separate outputs.
Every configured target can run independently. Missing credentials skip that
target's signed job, with the missing configuration names reported; they do not
prevent other platforms from building. A configured job with an invalid,
expired or mismatched certificate/profile must fail instead of silently falling
back to an unsigned package labelled as signed.

Store account creation, listing metadata and submission are separate from
building a signed package. These scripts do not upload an IPA to App Store
Connect or publish a Mac App Store listing. macOS Developer ID notarization
submits the signed software to Apple's notary service as part of creating a
usable direct-download package.

See [Android and Windows signing](SIGNING_ANDROID_WINDOWS.md) for those target
credentials and scripts, and [Deployment](DEPLOYMENT.md) for the package matrix.

## GitHub configuration

Set secrets and variables under **Settings → Secrets and variables → Actions**
in `getbible/app`, or in the release environment used by the workflow. Secrets
hold private material/passwords; variables hold public account identifiers and
certificate names. Do not commit a certificate, private key, provisioning profile,
password or generated signing configuration. Apple and Android/Windows credentials
have separate prefixes and cannot accidentally enable another target.

An exported `.p12` must contain its certificate **and private key**, and must be
password protected. Encode the complete file as base64; the scripts accept wrapped
or unwrapped base64. The temporary keychain password is generated per invocation;
no reusable keychain password secret is needed.

### macOS direct distribution

| Setting | Kind | Required value |
|---|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Secret | Base64 of a Developer ID Application certificate/private-key `.p12`. |
| `MACOS_CERTIFICATE_PASSWORD` | Secret | Password protecting that `.p12`. |
| `MACOS_SIGNING_IDENTITY` | Variable | Exact certificate identity from `security find-identity -v -p codesigning`, starting with `Developer ID Application:` and ending with the team ID in parentheses. |
| `MACOS_TEAM_ID` | Variable | The Apple Developer team owning the certificate. |
| `MACOS_NOTARY_KEY_P8_BASE64` | Secret | Base64 of a team App Store Connect API private key (`.p8`) authorized for notarization. |
| `MACOS_NOTARY_KEY_ID` | Variable | Identifier of that API key. |
| `MACOS_NOTARY_ISSUER_ID` | Variable | Issuer ID associated with the team API key. |

Use a **Developer ID Application** identity for direct downloads. An Apple
Distribution/Mac App Distribution certificate serves a different distribution
channel. The configured identity must appear exactly once among the valid
identities in the imported temporary keychain and belong to `MACOS_TEAM_ID`.

Build the release app with the shared version/build metadata, then run:

```bash
bash scripts/release/sign_macos.sh app \
  build/macos/Build/Products/Release/getBible.live.app

python3 scripts/release/package.py package --target macos \
  --metadata build/release-metadata.json --output dist \
  --signing-mode distribution \
  --sign-hook scripts/release/sign_macos_artifact.sh
```

The first stage signs nested Mach-O files and frameworks from the inside out,
then signs the application with the committed release entitlements, secure
timestamps and hardened runtime. It verifies the bundle ID, signature and team,
submits a ZIP with `notarytool`, requires an Accepted response, and staples and
validates the application's ticket. It preserves the release sandbox and public
network-client entitlements. A new nested helper app is rejected until its own
entitlement policy is explicitly added.

The packaging hook signs, notarizes, staples and verifies the final DMG. Package
checksums are computed **after** this hook; the ZIP contains the already-stapled
application. Both stages use Gatekeeper assessment. A failed or timed-out Apple
submission stops the signed package job. The diagnostic includes the submission
ID when Apple returns a completed rejection, so it can be investigated in the
Apple account.

Each stage creates a temporary keychain, restores the user's prior keychain
search list, deletes the temporary imported identities and removes its decoded
certificate/API-key files on exit. The scripts also unwind on workflow SIGTERM
and normal keyboard interruption. As with any process cleanup, forced host loss
or SIGKILL cannot execute cleanup handlers; GitHub-hosted ephemeral runners
remove the entire machine after the job.

This channel produces notarized direct-download macOS packages. Mac App Store
submission requires its own distribution certificate/profile and store archive
workflow; a Developer ID DMG is not a Mac App Store package.

### iOS and iPadOS

| Setting | Kind | Required value |
|---|---|---|
| `IOS_CERTIFICATE_P12_BASE64` | Secret | Base64 of an Apple Distribution certificate/private-key `.p12`. |
| `IOS_CERTIFICATE_PASSWORD` | Secret | Password protecting that `.p12`. |
| `IOS_SIGNING_IDENTITY` | Variable | Exact `Apple Distribution:` identity, including the team ID in parentheses. |
| `IOS_TEAM_ID` | Variable | The Apple Developer team owning the app and profile. |
| `IOS_PROVISIONING_PROFILE_BASE64` | Secret | Base64 of a current App Store distribution `.mobileprovision` for `life.getbible.mobile`, matching the certificate and requested entitlements. |

The App ID/profile must enable Associated Domains for the existing
`applinks:app.getbible.life` and `applinks:getbible.life` entries. The script
validates those entitlements and does not remove them to make signing pass.
App Store distribution profiles must have `get-task-allow` false and no
ad-hoc device list or enterprise `ProvisionsAllDevices` flag. Renew profiles and
certificates before expiration, then replace their corresponding secrets.

`pubspec.yaml` is the version source of truth. It accepts
`MAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]+BUILD`. Release filenames/metadata retain
the optional channel, while Apple `CFBundleShortVersionString` uses the numeric
three-part version and `CFBundleVersion` uses the explicit build number. Increase
the build number for another App Store Connect upload; CI does not invent a
version from its run number. The workflow supplies those numeric `VERSION_NAME`
and `BUILD_NUMBER` values from `build/release-metadata.json`. After Flutter dependencies are available, run:

```bash
bash scripts/release/sign_ios.sh
```

The script imports the distribution identity, installs the profile in both the
current and legacy Xcode profile locations, and temporarily configures only the
Runner target for manual signing. Framework/test targets do not receive the
app's provisioning profile. `flutter build ipa --release` receives explicit
build-name/build-number and a generated App Store Connect export options plist.
The export keeps that version instead of asking Xcode to renumber it.

The resulting `build/ios/ipa/*.ipa` is passed to the signed-iOS packager for
version, signature, profile and checksum validation. Stale IPA files are removed
before building, so an earlier IPA cannot be uploaded after an export failure.
The original Xcode project bytes, earlier local provisioning profiles and
keychain search list are restored on successful or failed completion. Temporary
private keys, profile copies and export options are removed.

The same app targets both iPhone and iPad. The App Store IPA is suitable for a
separate authorized App Store Connect/TestFlight upload; it is not a general
sideload package and is not a simulator binary. Simulator and unsigned device
outputs remain separately named validation artifacts.

## Validation boundary

Portable tests exercise profile/team/bundle/expiry/entitlement validation,
Runner-only configuration, repeated patching, invalid secrets and restoration
when signing preparation fails:

```bash
python3 -m unittest discover -s scripts/release/tests -p test_apple_signing.py -v
```

They do not replace actual Apple tool execution. Actual signing/notarization and
IPA export require a macOS runner, Xcode and the corresponding complete secret
set. Skipped jobs are reported as skipped, and must not be counted as signed
release evidence. Installed-device testing and store acceptance remain separate
release gates even after a signed package builds successfully.

## Primary references

- [Apple: notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple TN2311: managing multiple App ID prefixes](https://developer.apple.com/library/archive/technotes/tn2311/_index.html)
- [Apple TN3147: migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [Flutter: build and release an iOS app](https://docs.flutter.dev/deployment/ios)
- [Flutter: build and release a macOS app](https://docs.flutter.dev/deployment/macos)
