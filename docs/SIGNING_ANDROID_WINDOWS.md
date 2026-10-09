# Android and Windows distribution signing

The build matrix can compile and package without distribution credentials.
Signed jobs require each target's complete configuration and must run only for
trusted code after merge to `main`. Pull-request jobs do not receive signing
material. The scripts also reject `pull_request` and `pull_request_target` events.
A missing credential skips the optional signed job; a failed signature or
verification after that job starts fails the job. Never label an unsigned
artifact as signed or use the Android debug key for a release artifact.

`python3 scripts/release/signing_configuration.py` reports configuration
availability using names and booleans, without printing values. Use
`--require android` or `--require windows` for an explicit signing gate, and
`--github-output` to write the per-target `*_signing` booleans to `GITHUB_OUTPUT`.
The Apple names are included for the corresponding [Apple signing](SIGNING.md)
jobs. Checking availability does not validate passwords, certificate trust or
store enrollment; the target signing and verification commands do that work.

For an administrative check that cannot read secrets, `--metadata-file` accepts
GitHub's JSON secret-name metadata (`secrets`) plus optional variable-name
metadata (`variables`), or a JSON array of names. No secret values are needed.
Include all relevant repository/organization/environment names visible to the
intended job; a repository-only metadata list cannot establish environment-secret
availability. Runtime job gates check the values actually delivered to the job.

## Android

Configure these GitHub Actions secrets for the authorized release environment:

| Secret | Content |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | Base64 of the existing upload/distribution keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Alias of its private signing key |
| `ANDROID_KEY_PASSWORD` | That key's password |

Use the existing application signing identity for updates. Do not generate a
different key on every build. Play App Signing enrollment and upload-key ownership
are configured in the Play Console, independently from compilation.

The job runs the ordinary release build through the temporary-key wrapper:

```bash
python3 scripts/release/signing_configuration.py --require android
python3 scripts/release/sign_android.py -- flutter build apk --release
python3 scripts/release/sign_android.py -- flutter build appbundle --release
```

Each command decodes the key into a private temporary directory, passes its
path through `ANDROID_KEYSTORE_PATH`, and removes the directory on completion,
build failure or normal cancellation. Passwords stay in environment variables,
not Gradle command arguments. The base64 key is removed from the child process
environment. CI must use disposable runners; a forced OS kill cannot execute
application cleanup handlers.

`android/app/build.gradle.kts` uses the complete environment configuration for
release signing. For local signing, an ignored `android/key.properties` file
may instead contain `storeFile`, `storePassword`, `keyAlias` and `keyPassword`.
`storeFile` is absolute or relative to the `android` directory. The two sources
are never mixed; incomplete configuration fails with field names only. With
neither source configured, release validation output is unsigned.

The signed APK must pass Android SDK `apksigner verify`; the signed AAB must
pass JAR-signature verification before packaging. Final manifests/checksums
describe the already signed bytes. Test installation and upgrade on an Android
device separately from cryptographic verification. A signed AAB is an upload
artifact for Google Play, not a directly installable app.

## Windows

Configure these GitHub Actions secrets:

| Secret | Content |
|---|---|
| `WINDOWS_SIGNING_CERTIFICATE_BASE64` | Base64 PFX containing the publisher's code-signing certificate and private key |
| `WINDOWS_SIGNING_CERTIFICATE_PASSWORD` | PFX password |

The optional Actions variable `WINDOWS_TIMESTAMP_URL` selects an RFC3161 service.
Its default is DigiCert's documented `http://timestamp.digicert.com` endpoint.
The timestamp itself is cryptographically verified; timestamps are mandatory
for this distribution path. A provider requiring a hardware token, HSM or cloud
signing service needs that provider's runner integration instead of PFX export.
Never weaken a key provider's export restrictions to use this path.

On a Windows runner with PowerShell 7 and the Windows SDK:

```powershell
python scripts/release/signing_configuration.py --require windows
pwsh -NoProfile -File scripts/release/sign_windows.ps1 -Paths build/windows/x64/runner/Release
```

`-Paths` accepts one or more files/directories. Directories select executable
and DLL files recursively. The hook preserves valid vendor signatures. It
imports the private certificate into the current user's certificate store for
the operation, signs using SHA-256 and RFC3161/SHA-256 timestamps, and requires
both successful SignTool verification and valid timestamped Authenticode.
It removes its imported certificate/private key and temporary PFX in `finally`;
an existing developer certificate is preserved. The PFX directory has a private
user ACL, and the password is never passed on SignTool's command line.

Packaging signs the staged application bundle first, then creates its ZIP and
installer, then signs/verifies the installer, and only then generates checksums.
Changing an executable or installer after signing invalidates the signature.
SmartScreen reputation and Microsoft Store submission are separate from a
valid Authenticode signature.

## Validation

```bash
python3 -m unittest discover -s scripts/release/tests -p 'test_signing_configuration.py'
```

These regressions cover partial configuration, metadata-only checks, secret-value
redaction, PR rejection, invalid base64 and keystore cleanup after failed builds.
Actual signature trust, timestamping, certificate cleanup and package installation
must run on their target hosts with real authorized credentials. Local unit tests
do not certify a signing identity or a signed release.

Official references:

- [Flutter Android release signing](https://docs.flutter.dev/deployment/android)
- [Microsoft SignTool options and verification](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool)
- [Microsoft Authenticode timestamps](https://learn.microsoft.com/en-us/windows/win32/seccrypto/time-stamping-authenticode-signatures)
- [DigiCert RFC3161 endpoint](https://knowledge.digicert.com/solution/troubleshooting-timestamping-problems)
