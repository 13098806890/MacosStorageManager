# Safety validation

Run `swift test` on macOS 14 or later with Xcode command-line tools selected, then build the app:

```sh
swift test
python3 scripts/validate_cleanup_rules.py Config/cleanup-rules.json
xcodebuild -project CleanUpForMacOS.xcodeproj -scheme CleanUpForMacOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

The Swift Package test target compiles the production stores and helpers, excluding the app entry point. Tests cover path grammar/approved roots, parent-child selection conflicts, failed and cancelled scans, metadata change detection (including hidden entries), symlink rejection, independent subtree fingerprints, stale-target rejection without removal, stdout/stderr pressure, command exit codes, cancellation, deadlines, termination escalation, and bounded/redacted progress.

All filesystem tests use disposable fixtures created by the tests. Permission tests skip when run as root. Command tests use fixed local Python snippets; they do not invoke Homebrew, delete simulators, or clean real directories. These snippets are test code, never cleanup configuration or application commands.

Before distribution, manually validate the following with disposable fixtures or a clean test account:

- Cancel a full scan in each category; later categories must not start and the UI must become usable again.
- Confirm that empty, missing, permission-denied, and changing directories have distinct outcomes. Failed scans must have no usable cleanup selection.
- Review a large selection in the scrollable confirmation sheet, including long paths and impact text. Cancel with Escape and confirm keyboard/focus behavior.
- Change a selected target after scanning; cleanup must skip it and request a new scan. Exercise multiple sibling selections and partial refresh failures.
- Exercise Trash failures, successful Trash moves, and local history-write failures separately. A successful move followed by a refresh/log failure must not be reported as an unsuccessful move.
- Check external-tool failures and timeouts in an isolated environment. Do not assume timeout means rollback; check the actual tool state before retrying.

A successful build or test run does not validate every vendor's cache contents or eliminate the race between the final metadata check and the filesystem move. Quit related apps and stop builds before cleanup. No real user cleanup should be performed merely to validate a rule or this test suite.
