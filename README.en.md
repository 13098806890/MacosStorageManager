# CleanUpForMacOS

[简体中文](README.md) | **English**

A macOS storage cleanup tool for developers. You start each scan, review descriptions and estimated sizes, choose the targets, and confirm. Ordinary cleanup moves items to Trash; nothing is silently or periodically deleted.

[Download CleanUpForMacOS 0.1.0 DMG](https://github.com/13098806890/MacosStorageManager/releases/download/v0.1.0/CleanUpForMacOS-0.1.0.dmg) · [Browse all releases](https://github.com/13098806890/MacosStorageManager/releases)

> **Current release:** `0.1.0`, signed with Developer ID and notarized by Apple. The installer supports macOS 14 or later and is not compatible with the Mac App Store.

> **Security:** App Sandbox is disabled so the app can access approved cache directories in the current user's home folder. Import profiles only from sources you trust, and review each target and its impact before cleanup. Ordinary cache cleanup uses macOS Trash; simulator device deletion is permanent.

## Features

- **Profile-based cache scans:** Scans are user-initiated. Import profiles and enable rules individually. Each profile file supports one role.
- **Review before cleanup:** See each configured description, estimated impact, and size. Expand child folders sorted by size. Each level initially shows 10 items; use **Load more** or **Load all** to reveal additional folders. After you select a target and confirm, ordinary cache directories are moved to Trash.
- **Disk space history:** View capacity for the volume containing your home folder and track available space after manual scans. History stays on this Mac and retains up to 365 points.
- **Simulator management:** Review Xcode Simulator device states and data sizes. After confirmation, a running device is shut down before the device and its data are permanently deleted. Xcode manages simulator runtimes; this app does not remove runtime files.
- **Command-line tools:** Use Homebrew to view installed formulae and versions, search, check upgrades, install, upgrade, pin/unpin the current version, or uninstall. Each package change requires confirmation. Pinning can delay security updates; arbitrary historical-version rollback is not provided.
- **Local records:** Cleanup logs, imported profiles, and disk history are stored locally and are not uploaded to a project service.

## How to use

Download the DMG from [GitHub Releases](https://github.com/13098806890/MacosStorageManager/releases), open it, and drag the app to **Applications**. You can also build from source using the steps below.

After launching the app:

1. Open **配置管理** (Configuration Management) in the sidebar. Enable the rules you want, or import a compatible JSON profile. Imported rules are disabled by default.
2. Return to **全部** (All) and click **扫描全部缓存** (Scan All Caches). Category selection filters the displayed results; the scan covers all enabled rules whose paths exist on this Mac.
3. Review descriptions, sizes, and estimated impact. Expand child folders to inspect them; each level is sorted largest first and initially shows 10 items.
4. Select a rule directory or a displayed child directory, review the confirmation dialog, and choose **移到废纸篓** (Move to Trash).
5. Open **模拟器管理** (Simulator Management) to review Xcode devices. Device deletion cannot be undone. Manage runtimes in Xcode **Settings > Components**.
6. Open **命令行工具** (Command-line Tools) to review Homebrew formulae. Search to install; installed formulae can be upgraded, pinned/unpinned, or uninstalled. These actions call the local Homebrew installation and show a confirmation first.

Scan sizes are estimates, not file inventories. The scanner does not inspect filenames and skips hidden files, so displayed sizes may be lower than actual usage.

## Screenshots

App screenshots are pending. Once captured, they will be added under [`docs/screenshots/`](docs/screenshots/) and shown here. Please do not submit screenshots containing real usernames, cleanup logs, personal filenames, or other machine-specific information.

## Build

Requirements: macOS 14 or later, Xcode 15 or later, and the Xcode Command Line Tools selected in Xcode **Settings > Locations**.

```sh
git clone https://github.com/13098806890/MacosStorageManager.git
cd MacosStorageManager
xcodebuild \
  -project CleanUpForMacOS.xcodeproj \
  -scheme CleanUpForMacOS \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Alternatively, open `CleanUpForMacOS.xcodeproj` in Xcode, select the `CleanUpForMacOS` scheme, then build or run. This project is configured for direct distribution and is not suitable for the Mac App Store.

## Configuration and safety boundaries

The bundled profile is [`Config/cleanup-rules.json`](Config/cleanup-rules.json). A rule is a deletion proposal, not trusted code, and community proposals are not automatically approved. Each JSON file uses the same schema; users can import multiple profiles and enable rules themselves.

Rule paths accept only `$HOME/` followed by static path components. At runtime, the app also checks approved cache roots, the current user's home boundary, and symlinks. Importing a profile cannot expand the allowlist. Enabled rules cannot have duplicate or ancestor/descendant paths. Ordinary cleanup moves data to Trash, but users must still decide whether the target contents are safe to remove. Simulator device deletion is permanent.

Scans show configured descriptions, aggregate sizes, and visible child folders. They do not inspect or display a file inventory. Deeper child folders use a generic description; `subfolderDescriptions` applies only to immediate child folders.

Before adding or changing cleanup rules, read [`AGENTS.md`](AGENTS.md) and [`docs/AI_RULE_AUTHORING.md`](docs/AI_RULE_AUTHORING.md). Every proposed path needs evidence from its owner, a clear account of its contents and regeneration behavior, offline impact, and the smallest appropriate directory boundary. A name containing `cache`, `tmp`, or `build` is not evidence that a path is safe to remove.

## Local data and privacy

Profiles, disk-space history, and cleanup records are stored under `CleanUpForMacOS` in the current user's Application Support directory. Cleanup logs contain resolved local absolute paths; do not commit or publicly share an unredacted log. Capacity data is only used for local display. See [`Config/PrivacyInfo.xcprivacy`](Config/PrivacyInfo.xcprivacy).

## Contributing

Contributions to code, documentation, accessibility, localization, and evidence-backed cleanup rules are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Report security issues as described in [`SECURITY.md`](SECURITY.md).

**License not yet selected:** There is currently no `LICENSE` file, so redistribution and reuse terms have not been established. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Maintainer documentation

- [Versioning and release process](docs/RELEASING.md): version numbers, build numbers, release checks, and distribution signing requirements.
- [AI contributor guide](docs/AI_CONTRIBUTING.md): project boundaries, workflow, and verification requirements for AI-assisted changes.
- [Cleanup rule authoring guide](docs/AI_RULE_AUTHORING.md): required safety evidence before adding or changing cleanup paths.
