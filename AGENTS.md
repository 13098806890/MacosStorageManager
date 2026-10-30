# Instructions for AI contributors

These instructions apply to every change in this repository. Read [`docs/AI_RULE_AUTHORING.md`](docs/AI_RULE_AUTHORING.md) before adding, editing, or removing a cleanup path.

## Repository purpose

CleanUpForMacOS lets a person inspect configured cache directories and move selected directories to the macOS Trash after an explicit confirmation. A cleanup rule is destructive data, even when it is described as a cache. Treat every rule as an untrusted deletion proposal that needs evidence and a clear explanation.

## Required workflow for cleanup rules

1. Inspect `Config/cleanup-rules.json`, `Sources/CleanupStore.swift`, and the rule-authoring guide before editing configuration. Reuse the existing schema and UI behavior; do not invent fields or path syntax.
2. Establish from authoritative, current evidence that the exact directory is generated cache data and explain what is lost when it is removed. Prefer the owning vendor's documentation or source. If the path, contents, or regeneration behavior cannot be established, do not add the rule; report what evidence is missing.
3. Choose the smallest self-contained cache directory. Never propose a parent that may contain source code, user documents, credentials, app state, databases, archives, device data, or unrelated files. Never use globs to broaden the target.
4. Use only the path grammar supported by the app: a literal `$HOME/` prefix followed by static path components. Do not include a username, machine-specific path, `~`, other variables, shell syntax, glob syntax, `.` or `..` components.
5. Give every rule a unique, stable kebab-case `id`; fill every schema field; describe actual contents in `summary`; state concrete rebuild, download, offline, and workflow impact in `impact`; and use only supported `risk` values.
6. Check all rules for exact duplicates and ancestor/descendant overlap. Overlapping targets can make the second cleanup stale after the first moves a parent directory to Trash; avoid them.
7. Validate the JSON and project diff. For configuration-only edits, use the checks in the guide. Do not claim a path was tested on a Mac unless it was actually inspected there. Do not perform cleanup while validating a rule.
8. In the final report, list added/changed rule IDs, summarize the evidence and risk, identify checks run, and disclose any unresolved assumptions.

## Safety rules

- Never add system-wide paths, paths outside `$HOME`, root directories, home-directory roots, or targets requiring elevated privileges. The current app intentionally rejects paths outside its supported home-relative format.
- Never add commands, scripts, glob patterns, URL downloads, symlink traversal, or configuration-controlled executable behavior.
- Never label data safe to delete based only on a directory name containing `cache`, `tmp`, `build`, or similar wording.
- Do not claim the scan inventories filenames or counts hidden descendants; the current UI only shows configured descriptions and an aggregate size that may omit hidden files.
- This project intentionally disables App Sandbox so the user does not need to select directories. Direct distribution only; do not represent this build as Mac App Store compatible. Preserve the approved cache-root allowlist in `CleanupRule`, strict `$HOME` path parsing, canonical home-boundary check, symlink rejection, explicit cleanup confirmation, Trash-based removal, and local privacy protections. Never broaden the approved roots without explicit user authorization.
- Do not log, commit, or publish a user's expanded absolute paths, security-scoped bookmarks, cleanup logs, or machine-specific data. Rule paths must remain variable-based.
- The app currently supports one top-level role per configuration file. Do not add another role to the existing file and assume the app will display it; request or implement a deliberate schema/UI change first.

## Scope and implementation changes

Before changing public models, configuration schema, path parsing, permission behavior, or cleanup semantics, search for existing callers and describe the impact. If a proposed change expands a shared API or changes behavior for other rules, ask the user before coding unless the user has already authorized that specific change.

Keep the app's core promise intact: the user initiates scans, sees what a path contains and the consequences, selects the target, and confirms before it is moved to Trash.
