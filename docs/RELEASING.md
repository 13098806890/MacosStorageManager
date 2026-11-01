# Versioning and release process

This document defines how maintainers version, build, and publish CleanUpForMacOS.

## Version plan

The project is pre-1.0. Use semantic version components in `MARKETING_VERSION` and Git tags:

- **First public release: `0.1.0`** (`CURRENT_PROJECT_VERSION = 1`). It establishes the first public feature baseline.
- For `0.y.z`, increment **patch** (`0.1.1`) for fixes and documentation-only corrections that do not add a user-facing capability or change configuration compatibility.
- Increment **minor** (`0.2.0`) for user-visible features, material behavior changes, or backward-compatible additions to profile support.
- Increment **major** to `1.0.0` when the maintainer considers the app's core cleanup behavior and configuration format stable enough for general use. After `1.0.0`, follow normal SemVer: major for incompatible changes, minor for compatible features, patch for compatible fixes.
- Set the Git tag to `v<MARKETING_VERSION>` (for example, `v0.1.0`). The Git tag, release title, changelog heading, and Xcode `MARKETING_VERSION` must match.
- Increment `CURRENT_PROJECT_VERSION` as a monotonically increasing integer for every distributed build, including rebuilds of the same marketing version. Never reset it when the marketing version changes.

Do not create a tag for unreviewed or uncommitted changes. Before a release, move the completed notes from `未发布` / `Unreleased` into a dated version section in `CHANGELOG.md`, and prepare the matching GitHub release description under `docs/releases/`.

## Distribution status and signing

The app disables App Sandbox to access the approved home-relative cache paths without directory selection. It is intended for direct distribution, not the Mac App Store.

The `v0.1.0` release is signed with **Developer ID Application**, uses Hardened Runtime and a secure timestamp, and has an accepted Apple notarization ticket. Future installers must meet the same requirements. An Apple Development certificate is not a substitute. See Apple's [notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [Developer ID overview](https://developer.apple.com/developer-id/).

Before publishing a downloadable DMG:

1. Obtain a valid Developer ID Application certificate and configure the Xcode target for direct distribution with the required Hardened Runtime settings.
2. Build the Release configuration and verify the app bundle is signed with the intended Developer ID identity.
3. Submit the app or disk image with `notarytool`, wait for an accepted result, staple the ticket, and validate it with `stapler` and Gatekeeper assessment.
4. Create and inspect the DMG on a clean macOS account; verify drag-to-Applications installation and first launch.
5. Record the exact app version, build number, source commit, architecture, and SHA-256 checksum in the release notes. Do not include local logs, expanded home paths, or signing credentials.

If signing/notarization is not available, keep the release as a draft or publish source code only with the limitation stated clearly. Do not attach a development-signed or unsigned installer as if it were notarized.

## Release checklist

- [ ] Review the working tree and ensure only intended source and documentation changes are included.
- [ ] Review user-visible changes and safety behavior; do not claim tests that were not run.
- [ ] Validate cleanup configuration with `python3 scripts/validate_cleanup_rules.py Config/cleanup-rules.json` when configuration changes.
- [ ] Build the Release configuration on the minimum supported macOS/Xcode environment.
- [ ] Update `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `CHANGELOG.md`, and `docs/releases/vX.Y.Z.md` consistently.
- [ ] Confirm README installation and signing statements match the available artifact.
- [ ] Verify no local absolute paths, cleanup logs, user data, simulator identifiers, or credentials are included.
- [ ] Confirm licensing is resolved before describing the project as open source or inviting reuse. The repository currently has no `LICENSE` file.
- [ ] Create a GitHub release from the reviewed tag. Attach only the verified artifact, include its checksum, and do not mark a pre-release as latest.

## Current release plan

The initial tag is `v0.1.0`, matching the Xcode marketing version. The signed and notarized DMG and release details are recorded in [`releases/v0.1.0.md`](releases/v0.1.0.md). The project license remains undecided; do not describe the repository as open source until a license is added.
