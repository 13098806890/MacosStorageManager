# Architecture overview

This document maps the app's current feature layout and the boundaries each feature must preserve. The project is a native SwiftUI macOS app with no external package dependencies.

## Source layout

```text
Sources/
├── App/
│   └── CleanUpForMacOSApp.swift
├── OperationSupport.swift
└── Features/
    ├── Cleanup/
    │   ├── CleanupStore.swift
    │   └── CleanupViews.swift
    ├── Homebrew/
    │   ├── HomebrewManagerStore.swift
    │   └── HomebrewManagerView.swift
    ├── Simulator/
    │   ├── SimulatorManagerStore.swift
    │   └── SimulatorManagerViews.swift
    └── TemporaryBuilds/
        └── TemporaryBuildManagerStore.swift
```

- `App/CleanUpForMacOSApp.swift` creates the window and coordinates navigation and feature stores.
- `Features/Cleanup/` owns cleanup configuration and scan models, profile import/export, approved-path parsing, cache scanning, Trash operations, cleanup history, disk history, and related views.
- `Features/Homebrew/` owns the Homebrew inventory, fixed actions, and management UI. Formula names are validated; profile data cannot supply commands.
- `Features/Simulator/` owns Simulator inventory, device/runtime actions, and their UI.
- `Features/TemporaryBuilds/` owns `/private/tmp` inventory and cleanup for eligible temporary build directories. It excludes the running app's bundle from inventory and checks again before moving a target to Trash.
- `OperationSupport.swift` provides cooperative cancellation, bounded process output with deadlines, and in-memory metadata fingerprints used to detect changed targets.
- `Config/cleanup-rules.json` is the bundled single-role profile. Imported profiles are kept in the user's Application Support directory and are not written back to this file.
- `Config/PrivacyInfo.xcprivacy` declares the app's privacy manifest.

The Xcode project uses explicit file references so it remains compatible with the documented Xcode 15 build baseline. Add each Swift source file both to its feature group and to the target's Sources build phase in `CleanUpForMacOS.xcodeproj/project.pbxproj`. `Package.swift` compiles production stores and support code for safety regression tests while excluding the app entry point and UI files.

## Cleanup flow and safety boundary

1. The user enables profile rules and starts a scan.
2. `CleanupRule.resolvedPath` accepts only literal `$HOME/` syntax with static components, an approved runtime root, and a canonical target inside the current user's home directory.
3. The scanner reports estimated sizes and visible child directories. Read failures invalidate that rule; cancellation prevents unfinished results from being used. It does not display a file inventory or infer file contents. Metadata fingerprints include hidden entries for change detection, while hidden files remain excluded from the ordinary cache size estimate.
4. The user chooses a rule or displayed child directory and reviews a confirmation sheet listing the targets, estimated sizes, actions, and impacts. Parent and child selections are mutually exclusive.
5. Before moving a directory to macOS Trash, the app compares its metadata fingerprint with the completed scan and repeats path and symlink checks. Changed or unreadable targets are skipped and need a fresh scan and confirmation. Local JSONL history records the result and resolved path. This is not an atomic filesystem transaction; changes after the final check remain possible.

Fingerprints hash entry names and filesystem metadata, not file contents, and stay in memory. Scanning compares the root fingerprint before and after its size walk to reject changing trees. Temporary-build cleanup also compares a scan fingerprint and verifies ownership, symlinks, compiler-artifact criteria, and hidden descendants.

Imported configuration is data, never executable behavior. It cannot add approved roots or commands. Preserve the root allowlist, home-boundary and symlink checks, explicit confirmation, and Trash-based cleanup. Do not add automatic or scheduled cleanup. See [`AGENTS.md`](../AGENTS.md), [`AI_RULE_AUTHORING.md`](AI_RULE_AUTHORING.md), and [`SAFETY_VALIDATION.md`](SAFETY_VALIDATION.md) before changing cleanup paths or safety behavior.

## Simulator management

The simulator manager obtains inventory using fixed `xcrun simctl` commands. A user-confirmed device deletion refreshes and validates device state before permanently deleting the device. Runtime removal uses a freshly validated fixed `simctl runtime delete` call after confirming no devices still reference it. Xcode Components manages runtime installation; the app does not manipulate runtime bundles directly.

## Homebrew manager

The manager detects the standard Apple Silicon and Intel executable locations (`/opt/homebrew/bin/brew` and `/usr/local/bin/brew`). It invokes Homebrew directly with fixed subcommands and validated formula identifiers; it never routes arguments through a shell or cleanup profile. Inventory and search are user initiated. Every install, upgrade, pin/unpin, and uninstall requires an in-app confirmation. Uninstall uses Homebrew's default dependency behavior. The app does not provide arbitrary historical-version rollback.

## Local data and privacy

Profiles, disk history, and cleanup history remain in local Application Support storage. Cleanup history contains resolved absolute paths. Never commit it, include it in screenshots, or paste it into a public issue without redaction.

## Contributor checks

CI validates the bundled profile, runs `swift test` against production store/support code, and builds the macOS app. The validator cannot prove a directory is safe and does not replace evidence or maintainer review. Regression tests use isolated disposable fixtures and do not clean configured user directories or delete simulators.

## Long-running work

Scans and read-only Homebrew queries expose cancellation. Cooperative tokens are checked during directory traversal and between commands; cancelling a full scan prevents later categories from starting. The UI polls a bounded, home-redacted output tail and elapsed time. Homebrew modifications deliberately have no cancel button.

The shared process runner drains stdout and stderr independently without blocking, limits captured output, and enforces deadlines (120 seconds per inventory/Simulator command; 900 seconds per Homebrew modification). On timeout or cancellation it requests termination and escalates after two seconds. It signals a child process group only if that group is owned by the launched process; detached descendants are not guaranteed to stop. A stopped modifying command may already have changed state. Homebrew refreshes inventory after failure; users must inspect state before retrying. No operation is described as rolled back.
