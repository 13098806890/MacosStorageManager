# Contributing

Thanks for helping improve CleanUpForMacOS. Contributions are welcome in the app, documentation, accessibility, localization, and cleanup-rule review.

AI coding agents should first read [`AGENTS.md`](AGENTS.md) and [`docs/AI_CONTRIBUTING.md`](docs/AI_CONTRIBUTING.md). For version changes and releases, follow [`docs/RELEASING.md`](docs/RELEASING.md).

**License status:** the repository does not yet have a `LICENSE` file. Until the maintainer chooses one, please use issues and discussions to propose work; maintainers may defer merging code contributions because reuse and contribution terms have not been established.

## Before you start

- For a small fix, open a pull request with a clear description.
- For a new feature or a change to cleanup behavior, open an issue first so the scope and safety impact can be reviewed before you invest time.
- For cleanup-rule proposals, use the **Cleanup rule proposal** issue form and read [`docs/AI_RULE_AUTHORING.md`](docs/AI_RULE_AUTHORING.md). A rule is a deletion proposal; a pull request does not itself authorize a new path or expand the app's approved-root allowlist.
- Do not include cleanup logs, real home-directory paths, simulator identifiers, screenshots with personal data, or other machine-specific information in issues or pull requests.

## Build locally

Requirements: macOS 14 or later, Xcode 15 or later, and the Xcode Command Line Tools selected in Xcode Settings > Locations.

```sh
xcodebuild \
  -project CleanUpForMacOS.xcodeproj \
  -scheme CleanUpForMacOS \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

There is currently no test target. Do not describe a change as tested unless you performed the relevant verification. Cleanup behavior must not be validated against real cache directories; use isolated temporary fixtures if you add tests in a future test target.

For cleanup configuration edits, validate JSON and review path grammar, role, required fields, duplicate paths, and parent/child overlap:

```sh
python3 scripts/validate_cleanup_rules.py Config/cleanup-rules.json
git diff --check
```

The validator does not prove a path is safe and does not check the Swift runtime allowlist. Every proposed directory still needs owner documentation or other primary evidence, a precise boundary, regeneration details, and a maintainer review of `approvedRoots`.

## Cleanup-rule requirements

- Keep each configuration file to one top-level role. The current app does not display multiple roles from one file.
- Use the existing JSON schema and literal `$HOME/` path grammar. Do not add shell syntax, globs, commands, symlink traversal, or paths outside the home directory.
- Target the smallest self-contained generated cache. Do not include projects, user-authored data, credentials, app databases, device folders, or mixed-use parents.
- Explain what is stored, what is lost, how it is regenerated, and what happens offline. Use only the supported `low` and `medium` risks.
- Keep descriptions evidence-based. The scanner shows aggregate sizes and visible directories; it does not inventory filenames or prove the contents of a folder.
- Imported profiles are opt-in. Do not add background scans or automatic cleanup.

## Pull requests

Include the user-visible change, the reason for it, the verification performed, and any remaining limitation. For UI changes, include a screenshot or a short description of the affected view when practical. For cleanup-rule changes, include direct evidence and the concrete rebuild, download, offline, and workflow impact.

The macOS CI build and cleanup-rule validator must pass. Maintainers may request an issue or design discussion before reviewing broad changes to the schema, path authorization, permissions, or deletion behavior.
