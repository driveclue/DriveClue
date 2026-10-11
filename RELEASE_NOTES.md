# Releasing DriveClue

**No release is authorized by this guide.** Preparation is local-only. Tag creation, draft upload, feed push, and draft publication each require explicit user authorization at the time of action. Do not run either publish command, commit, push, or tag as part of release preparation.

Sparkle reads `appcast.xml` from `main` and verifies the EdDSA signature of the downloaded archive; macOS independently checks the Developer ID signature and notarization ticket. The appcast must never advertise an absent, unverified, or unsigned asset.

## Prerequisites

- macOS 14+ with Xcode, XcodeGen, SwiftLint, Python 3, `gh` authenticated for `driveclue/DriveClue`, Apple Developer Program Developer ID Application certificate for team `R3YX83R9RQ`.
- Pinned Sparkle 2.10.0 CLI tools in `build/sparkle-tools/bin` (`sign_update`, `generate_keys`). Install from the official Sparkle 2.10.0 release; verify the download before use. The login-keychain private key must match `SUPublicEDKey` in `project.yml` (`mwTWSAi4FYAOlIGHncqA8MniPfH5V9Kra9bDqfoGeZI=`). Back up the private key securely outside the repository.
- A `notarytool` credential profile, for example `xcrun notarytool store-credentials driveclue-notary --apple-id you@example.com --team-id R3YX83R9RQ`. `notarytool` must return Accepted; the final app must be stapled and pass Gatekeeper.
- `origin` must be `https://github.com/driveclue/DriveClue.git`; `main` and `origin/main` must match with a completely clean tree, including untracked files. The desired `MARKETING_VERSION` and monotonically increasing `CURRENT_PROJECT_VERSION` must already be committed and pushed. No existing remote `vVERSION` tag/release. Never move a published tag.
- Review/update release notes as short HTML (or plain text) outside the source tree or include in the source commit. Check GPLv3 corresponding source availability at the tag.

## 1. Local preflight and preparation (no publication)

```bash
scripts/release.sh preflight 1.0.1
scripts/release.sh prepare 1.0.1 --notarize driveclue-notary --notes /path/to/notes.html
```

`preflight` validates clean source, exact remote commit, version/build monotonicity, and absence of a conflicting tag/release. `prepare` repeats checks, archives that exact committed tree into `build/release/1.0.1/source/`, runs `swift test --package-path DriveClueCore`, strict SwiftLint, an **unsigned** Release build, then a separate **universal** (`arm64` + `x86_64`) Developer ID–signed Release build; every binary in the bundle must contain both architectures. It submits to Apple, requires Accepted, staples and verifies the app, re-zips, extracts and checks the actual final archive, signs it with Sparkle, and produces `appcast.xml`, notes, and `manifest.json` alongside the ZIP under `build/release/1.0.1/`.

From the same stapled app it also builds `driveclue_1.0.1_build_<build>_universal.dmg` (app + `Applications` shortcut), signs it with Developer ID, notarizes and staples it, then mounts it read-only and re-runs the app checks plus Gatekeeper. A copy is placed in the gitignored `releases/` folder for convenience; the copy under `build/release/1.0.1/` is the one that gets uploaded. The DMG is for first-time downloads only — Sparkle updates always use the ZIP. The manifest pins source commit, build, archive length/hash, signature, DMG name/hash, notes and feed hash. The shared Xcode project and repository feed are not changed by preparation. If a step fails, inspect artifacts before removing the release directory and retrying; do not upload partial output.

Smoke gates before authorizing any remote action:

- Review the archived source commit, version/build, produced manifest/feed URL/signature/length, final ZIP SHA-256, and release notes. Inspect that `project.yml` still embeds the expected feed and public key. Do not modify prepared artifacts.
- On clean macOS 14+ test machines (Apple Silicon and Intel if available), extract/download the ZIP and launch the stapled app without Gatekeeper warnings. Check launch, drive reading, indicators, local history, menu bar, report export, storage scanning and disk benchmark (only on a safe test volume), and update UI. Check privacy and no unintended network requests.
- Confirm tests, lint, unsigned build and signed notarized build passed; CI checks are green for the exact source commit. Check `xcrun stapler validate`, `spctl --assess --type execute`, bundle ID/version/build, and Developer ID team. Confirm Sparkle key ownership before signing. Never publish a dev/unsigned/unstapled build.

## 2. Draft release (requires separate explicit authorization)

```bash
scripts/release.sh publish-draft 1.0.1 --confirm v1.0.1
```

This rechecks the pristine `main`/`origin/main`, prepared hashes, and exact source commit, creates remote `v1.0.1` pointing **exactly** at that source, uploads the ZIP and DMG to a **draft pre-release**, downloads both assets and compares bytes. It does not modify or push the feed and cannot make the draft public. Inspect the draft notes and asset again. If interrupted, investigate remote tag/release state manually; never retag or silently rerun against an existing release.

## 3. Public pre-release and feed (each requires separate authorization)

After verifying the draft asset and authorizing a public pre-release, run:

```bash
scripts/release.sh publish 1.0.1 --confirm v1.0.1
```

`publish` checks that `main` still equals the prepared source commit, the exact source tag is remote, and the draft ZIP and DMG can be downloaded byte-for-byte; after publishing it re-downloads both public assets and compares them again. It then makes the draft a public **pre-release** and checks that it is no longer a draft. It performs no commit or push. If a gate fails, inspect `gh release view v1.0.1 --repo driveclue/DriveClue` before retrying; do not create a second tag. Verify that the public archive is downloadable at the prepared enclosure URL and that its SHA-256 matches the manifest before proceeding.

Only after the asset is publicly downloadable, review `build/release/1.0.1/appcast.xml` and **separately authorize** committing that prepared feed to `main` and pushing it. Do not regenerate the item or change its signature. Verify `https://raw.githubusercontent.com/driveclue/DriveClue/main/appcast.xml` serves the same item (the raw cache may lag). Feed publication is the final step that exposes this pre-release to Sparkle users; no feed entry may reference an unavailable draft asset. If feed publication fails, the public pre-release is still available for manual download, but older installations do not see the update until the feed is repaired.

## Post-publication verification

- Download the public asset from its appcast enclosure URL; compare SHA-256 against `manifest.json`, extract and verify codesign, notarization, Gatekeeper and metadata again.
- Fetch the public feed and compare the new item to the prepared feed, including `sparkle:version`, URL, length, EdDSA signature, and release notes. Check the tag resolves to the manifest's `source_commit`.
- On an **older installed version** of DriveClue, invoke **Check for Updates…**, verify the expected notes, install, relaunch and inspect the version and drive dashboard. Test both architectures when available. If the update does not appear, compare the running app's build to the feed's strictly higher `sparkle:version` and ensure it was not skipped. Do not use a fabricated unsigned feed as a substitute for a full install test.

`MARKETING_VERSION` is the user-facing semver; `CURRENT_PROJECT_VERSION` is Sparkle's strictly increasing numeric comparison. Keep historical feed entries and protect the private EdDSA key. If notarization is rejected, use `xcrun notarytool log <submission-id> --keychain-profile driveclue-notary` and resolve it before proceeding. Never instruct users to bypass Gatekeeper for a release.
