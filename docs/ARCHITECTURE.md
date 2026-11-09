# Architecture overview

This document describes the current app boundaries for contributors. Keep the user-driven cleanup flow and its safety checks intact when changing implementation details.

## Main pieces

- `Sources/CleanUpForMacOSApp.swift` contains the SwiftUI app, navigation, cleanup/configuration/history views, and simulator-management views.
- `Sources/CleanupStore.swift` contains cleanup models and stores, configuration import/export, path validation, scanning, simulator inventory/deletion, local history, and disk history.
- `Sources/HomebrewManagerStore.swift` owns the Homebrew formula inventory and fixed Homebrew operations. The CLI manager only searches and manages formulae; it does not execute shell commands or read commands from cleanup profiles.
- `Sources/OperationSupport.swift` provides cooperative cancellation, bounded command output with deadlines, and in-memory metadata fingerprints for stale-target rejection.
- `Config/cleanup-rules.json` is the bundled single-role programmer profile. Imported profiles are stored under the user's Application Support directory and are not written back to this file.
- `Config/PrivacyInfo.xcprivacy` declares the app's privacy manifest.

## Cleanup flow

1. The user selects a profile rule and starts a scan.
2. `CleanupRule.resolvedPath` accepts only the supported literal `$HOME/` path syntax, an approved runtime root, and a canonical target inside the current user's home directory.
3. The scanner reports estimated sizes and visible child directories. Read failures invalidate that rule rather than returning zero; cancellation prevents unfinished results from being used. It does not display a file inventory or infer file contents. Metadata fingerprints include hidden entries for change detection, but hidden files remain excluded from the ordinary cache size estimate.
4. The user selects a rule or displayed child directory and reviews a scrollable confirmation with each target, estimated size, operation, and impact. Parent/child selections are mutually exclusive.
5. Before moving a directory to macOS Trash, compare its metadata fingerprint with the completed scan and repeat path/symlink checks. Changed or unreadable targets are skipped and must be scanned and confirmed again. The local JSONL history records the result and resolved local path. This is not an atomic filesystem transaction: changes after the final check remain possible.

Fingerprints hash entry names and filesystem metadata, not file contents, and stay in memory. Scanning compares the root fingerprint before and after its size walk to reject changing trees. Temporary-build cleanup also compares a scan fingerprint and verifies ownership, symlinks, and compiler-artifact criteria, including hidden descendants.

Imported configuration is data, never executable behavior. It cannot add approved roots or commands. Do not weaken the root allowlist, symlink checks, explicit confirmation, or Trash-based cleanup to make a rule easier to contribute.

## Simulator boundary

The simulator manager obtains device and runtime inventory through fixed `xcrun simctl` commands. It can delete a user-confirmed simulator device after refreshing and validating its state. Device deletion is permanent. Runtime removal uses a freshly validated fixed `simctl runtime delete` call after confirming that no devices reference it. Installation belongs to Xcode Components; the app must not manipulate runtime bundles directly.

## Homebrew CLI manager

The manager detects the standard Apple Silicon and Intel executable locations (`/opt/homebrew/bin/brew` and `/usr/local/bin/brew`). It invokes Homebrew directly with fixed subcommands and validated formula identifiers; never route arguments through a shell or profile configuration. Inventory and search are user initiated. Every install, upgrade, pin/unpin, and uninstall requires an in-app confirmation. Uninstall uses Homebrew's default dependency behavior. Version control is limited to Homebrew's installed version and pinning support; arbitrary historical-version rollback is not promised.

## Local data

Profiles, disk history, and cleanup history remain in local Application Support storage. Cleanup history contains resolved absolute paths. Never commit it, include it in a screenshot, or paste it into a public issue without redaction.

## Contributor checks

The macOS CI job validates the bundled profile's static structure and builds the app. The validator cannot prove a directory is safe and intentionally cannot approve runtime roots; those require evidence and maintainer review. `swift test` runs the `CleanupCoreTests` Swift Package target against production store/helper sources without starting the UI. CI runs these tests before building the app. Fixtures are isolated disposable directories; tests never clean configured user directories or delete simulators. See [safety validation](SAFETY_VALIDATION.md).

## Long-running work

Only scans and read-only Homebrew queries expose cancellation. Cooperative tokens are checked during directory traversal and between commands; a cancelled full scan does not start later categories. The UI polls a bounded, home-redacted output tail and elapsed time. Homebrew modifications deliberately have no cancel button.

The shared process runner drains stdout/stderr independently without blocking, limits captured output, and enforces deadlines (120 seconds per inventory/simulator command; 900 seconds per Homebrew modification). On timeout/cancellation it requests termination and escalates after two seconds. It signals a child process group only if that group is owned by the launched process; detached descendants are not guaranteed to stop. A stopped modifying command may already have changed state. Homebrew refreshes inventory after failure; users must inspect state before retrying. No operation is described as rolled back.
