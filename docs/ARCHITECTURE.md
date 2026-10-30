# Architecture overview

This document describes the current app boundaries for contributors. Keep the user-driven cleanup flow and its safety checks intact when changing implementation details.

## Main pieces

- `Sources/CleanUpForMacOSApp.swift` contains the SwiftUI app, navigation, cleanup/configuration/history views, and simulator-management views.
- `Sources/CleanupStore.swift` contains cleanup models and stores, configuration import/export, path validation, scanning, simulator inventory/deletion, local history, and disk history.
- `Config/cleanup-rules.json` is the bundled single-role programmer profile. Imported profiles are stored under the user's Application Support directory and are not written back to this file.
- `Config/PrivacyInfo.xcprivacy` declares the app's privacy manifest.

## Cleanup flow

1. The user selects a profile rule and starts a scan.
2. `CleanupRule.resolvedPath` accepts only the supported literal `$HOME/` path syntax, an approved runtime root, and a canonical target inside the current user's home directory.
3. The scanner reports aggregate sizes and visible child directories. It does not inspect filenames or infer the meaning of files.
4. The user selects a rule or displayed child directory and confirms the action.
5. The selected directory is moved to macOS Trash. The local JSONL history records the result and the resolved local path.

Imported configuration is data, never executable behavior. It cannot add approved roots or commands. Do not weaken the root allowlist, symlink checks, explicit confirmation, or Trash-based cleanup to make a rule easier to contribute.

## Simulator boundary

The simulator manager obtains device and runtime inventory through fixed `xcrun simctl` commands. It can delete a user-confirmed simulator device after refreshing and validating its state. Device deletion is permanent. Shared Simulator Runtime installation and removal belongs to Xcode Components; the app must not manipulate runtime bundles directly.

## Local data

Profiles, disk history, and cleanup history remain in local Application Support storage. Cleanup history contains resolved absolute paths. Never commit it, include it in a screenshot, or paste it into a public issue without redaction.

## Contributor checks

The macOS CI job validates the bundled profile's static structure and builds the app. The validator cannot prove a directory is safe and intentionally cannot approve runtime roots; those require evidence and maintainer review. The project currently has no automated test target.
