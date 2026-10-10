# Release checklist

Use this checklist against one candidate version and commit. Published alpha,
beta and release-candidate packages may retain clearly recorded external gates;
do not describe them as stable or store-approved while those gates remain open.

- [ ] Feature-parity ledger has no unexplained Partial mobile requirements.
- [ ] Formatting, analysis, unit, widget, migration, and integration tests pass.
- [ ] Dependency/license review is current; no secrets or signing files are tracked.
- [ ] API failure, malformed response, offline cache, and changed-hash behavior verified.
- [ ] Backup fixtures import and round-trip without duplicates/data loss.
- [ ] Android release APK/AAB build and install on phone/tablet.
- [ ] Unsigned iOS device build and iPhone/iPad simulator APP execute through the appropriate target; unsigned device bundles are never described as directly installable.
- [ ] Package IDs, display name, icons, splash, permissions, and deep links verified.
- [ ] RTL, screen reader, keyboard, reduced motion, contrast, and large text checked.
- [ ] Small/large screens, rotation, suspension, and process restoration checked.
- [ ] New Study/Search labels localized and keyboard/screen-reader journeys checked on actual target platforms.
- [ ] Complete private backup and retained-draft restore verified through the actual file picker on each target; website v2 export is clearly distinguished.
- [ ] Complete Bible/Study installation, interruption/retry, atomic update/removal and offline restart verified on target devices without changing private work.
- [ ] Windows, macOS and iOS builds verified on their supported host toolchains; macOS sandbox HTTPS exercised with the network-client entitlement.
- [ ] Privacy, store listing, screenshots, content rating, and translation attribution approved.
- [ ] Version/build numbers and release notes updated; tag points to green CI.
- [ ] GitHub Release assets are promoted from that successful main run without rebuilding; every installer matches its package manifest/checksum and immutable version.
- [ ] Actual DEB, Windows setup EXE and macOS DMG install/launch on their supported hosts; custom `getbible:` links reach the intended passage.
- [ ] Browser release starts from a fresh page with all networking disabled after shell installation; private data survives app/cache lifecycle tests.
- [ ] Android phone/tablet, iPhone/iPad and native desktop runtime reports are retained for the exact candidate.
- [ ] Prior-version package upgrade preserves private IDs, origins, quotes/ranges, notebook journals and settings; restore a retained backup as a separate check.
- [ ] Machine-generated locale coverage is distinguished from human language review, including documented upstream English fallbacks.

## Store publication checklist

- [ ] Play Data Safety and App Store privacy answers match local-first behavior.
- [ ] Support URL, privacy URL, category, age rating, descriptions, and screenshots supplied.
- [ ] Internal/TestFlight feedback resolved.
- [ ] Apple provisioning/notarization and platform signing identities are configured and signed packages independently verified; verified HTTPS app associations match domain/team ownership.
- [ ] Staged rollout and rollback owner identified.
