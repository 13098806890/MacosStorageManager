# CleanUpForMacOS

[简体中文](README.md) | **English**

A macOS storage cleanup tool for developers. You start each scan, review descriptions and estimated sizes, choose the targets, and confirm. Ordinary cleanup moves items to Trash; nothing is silently or periodically deleted.

[Download CleanUpForMacOS 0.1.0 DMG](https://github.com/13098806890/MacosStorageManager/releases/download/v0.1.0/CleanUpForMacOS-0.1.0.dmg) · [Browse all releases](https://github.com/13098806890/MacosStorageManager/releases)

> **Current release:** `0.1.0`, signed with Developer ID and notarized by Apple. The installer supports macOS 14 or later and is not compatible with the Mac App Store.

## Features

- **Storage overview:** See available disk space and how it changes after each scan.
- **Cache cleanup:** Browse storage usage by Xcode, package managers, developer tools, and browsers, then choose what to clean.
- **Simulator management:** Review and remove Xcode simulators and runtimes you no longer use.
- **Temporary build cleanup:** Find leftover temporary build files and reclaim space.
- **Command-line tools:** View Homebrew tool sizes, search, install, upgrade, pin versions, or uninstall tools.
- **Profiles and records:** Choose what to scan, import profiles, and review cleanup records stored on your Mac.

## Screenshot

![CleanUpForMacOS storage overview](docs/screenshots/storage-overview.png)

## How to use

Download the DMG from [GitHub Releases](https://github.com/13098806890/MacosStorageManager/releases), open it, and drag the app to **Applications**.

1. Enable the items you want to scan in **配置管理** (Configuration Management).
2. Click **扫描全部** (Scan All) to review storage usage by category.
3. Read the descriptions and cleanup impact, expand child folders as needed, and select your targets.
4. Review the targets and impact in the confirmation sheet before cleanup. Caches and temporary builds move to Trash. Use the dedicated management pages for simulators, runtimes, and command-line tools.

> **Before cleanup:** Caches may need to be downloaded or generated again; quit the related apps first. Simulator device deletion is permanent, so save any data you need beforehand. Scan sizes are estimates and may omit hidden files. Scans can be cancelled; failed scans and changed targets require a fresh scan before cleanup.

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

## Privacy and safety

You start each scan and confirm before cleanup. Profiles, disk history, and cleanup records stay on your Mac and are not uploaded to a project service. Remove personal paths before sharing cleanup records.

The app accesses cache directories with App Sandbox disabled and is distributed directly. Import profiles only from sources you trust, and review each target and its impact before cleanup. See the [privacy manifest](Config/PrivacyInfo.xcprivacy).

## Contributing

Contributions to code, documentation, accessibility, localization, and evidence-backed cleanup rules are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Report security issues as described in [`SECURITY.md`](SECURITY.md).

**License not yet selected:** There is currently no `LICENSE` file, so redistribution and reuse terms have not been established. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Maintainer documentation

- [Versioning and release process](docs/RELEASING.md): version numbers, build numbers, release checks, and distribution signing requirements.
- [AI contributor guide](docs/AI_CONTRIBUTING.md): project boundaries, workflow, and verification requirements for AI-assisted changes.
- [Cleanup rule authoring guide](docs/AI_RULE_AUTHORING.md): required safety evidence before adding or changing cleanup paths.
