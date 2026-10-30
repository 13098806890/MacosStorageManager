# AI guide: adding cleanup rules

This is the detailed authoring contract for `Config/cleanup-rules.json`. It is written for AI agents and human reviewers who propose new paths. Follow it for every path change.

## 1. What a rule means

The app scans one configured directory and reports its aggregate size. When it contains immediate child directories, the user can expand a breakdown showing each child’s recursive size and can select the parent or individual children for Trash. Parent and child selections for one rule are mutually exclusive. A rule’s optional `subfolderDescriptions` maps exact immediate child directory names to plain-language descriptions; descriptions do not create paths or authorize access. Unconfigured children still appear with names and sizes. The app does not select deeper descendants individually, interpret cleanup commands, or restore files automatically. Be conservative about the exact configured directory boundary.

The app disables App Sandbox and directly reads configured paths under the current user's home directory. This avoids file-selection panels, but gives the process broader access to the user's files and makes this build suitable for direct distribution rather than the Mac App Store. Keep this tradeoff visible in product documentation. Scanning is user initiated; cleanup still requires selecting entries and confirming the move to Trash.

For defense in depth, runtime path parsing only accepts roots explicitly listed in `CleanupRule.approvedRoots` in `Sources/CleanupStore.swift`. The current roots are narrow development caches. Do not add a new root to that list based only on a community config change: first establish the evidence described below, then ask the user before expanding runtime access boundaries. The scanner also rejects the configured target when it is a symbolic link and verifies that its resolved path remains inside the current home directory.

The bundled community configuration must never contain bookmarks or personal absolute paths. Scanning is user initiated; the app does not periodically clean files. Cleanup still requires selecting entries and confirming the move to Trash.

The app can import multiple JSON configuration files from “配置管理”. Each file remains a single-role profile with the schema below; users can enable individual rules from any imported profile, and only enabled rules appear in the scan list. Imported profiles and enabled selections are copied into local Application Support storage; the app does not modify the source file or publish imported data. Runtime rule identity combines the profile ID and rule ID, so IDs only need to be unique and stable within their configuration file. Import does not expand the approved path roots: every rule must still pass the same strict path parser and approved-root check.

The scan page shows total, used, and available capacity for the volume containing the user's home directory. After each manual scan operation (including simulator inventory scans), it records one local available-space history point. The history is private local app data, is not part of cleanup logs, and retains at most the latest 365 points.

The app stores cleanup history locally. Each action record includes the resolved absolute path, rule title and content description, measured bytes, configuration version, action, consent marker, timestamp, and result. Treat logs as sensitive and never add them to the repository.

### Simulator manager boundary

Simulator devices are managed separately from community cleanup rules. The manager reads device names, runtime identifiers, states, data sizes, log sizes, and data paths from `xcrun simctl list ... --json`. It must not directly move or remove CoreSimulator folders. A user-selected, non-booted device is removed only by invoking the fixed `/usr/bin/xcrun simctl delete <validated-UUID>` command after an in-app confirmation; this permanently removes that simulator's installed apps, app data, and settings and is recorded in the local cleanup log. Do not allow config values to become command arguments. Shared Simulator runtimes are managed from Xcode > Settings > Components, where Xcode reports reclaimable space; do not directly delete runtime bundles or widen filesystem path access to them.

### Current scanner limitations

- The UI shows the rule author’s `summary` and `impact`, an aggregate byte count, and—when present—immediate child directory names and recursive sizes. It does **not** inspect or display filenames or independently identify what files mean. Rule and subfolder descriptions must be supported by evidence, not presented as facts discovered by the scan.
- The size walker currently uses `.skipsHiddenFiles`, so hidden descendants are excluded from its displayed size. It sums regular-file allocated size where available and falls back to logical file size. The displayed number can therefore underestimate the target's contents and is an estimate of space, not a complete inventory.
- The cleanup action moves the configured directory or one selected immediate child as a whole. It does not re-scan or compare contents immediately before the move. If files are changing between scan and confirmation, they may also be moved.
- Symbolic-link descendants are not followed for size traversal. The configured target itself is rejected if it is a symbolic link.

Do not claim the UI has inspected filenames or measured every byte. When proposing rules, select a stable, dedicated cache leaf whose entire contents are appropriate to move, even if its displayed size is incomplete. If a proposed target can mix valuable files with cache data, leave it out. Changes to these scanner limitations are implementation changes and must be handled as such, not worked around by broadening a path.

## 2. Current configuration shape

The built-in file has one profile:

```json
{
  "schemaVersion": 1,
  "configVersion": "YYYY.MM.N",
  "role": "programmer",
  "rules": []
}
```

The app currently filters `rules` to the single top-level `role`. Adding a new role to this same file will not make a second profile work. Keep contributions in the existing `programmer` profile unless the user explicitly requests and authorizes a schema/UI change.

Each rule must contain these required fields (extra fields are not currently consumed by the app):

| Field | Type | Contract |
|---|---|---|
| `id` | string | Unique, stable lowercase kebab-case key. Do not rename an ID just to polish its display title. |
| `role` | string | Must match the file's top-level `role`; currently `programmer`. |
| `title` | string | Short, recognizable UI name. Include the owning tool where useful. |
| `path` | string | `$HOME/` plus literal relative path components, as defined below. |
| `summary` | string | Plain-language description of the actual data expected in this directory. |
| `impact` | string | Concrete consequences: what is regenerated or downloaded, likely delay, and offline/workflow impact. |
| `risk` | string | Only `low` or `medium` are supported. If the proposed target deserves higher or unclear risk, omit it rather than forcing a label. |
| `category` | string | Existing UI grouping such as `Xcode` or `包管理器`; reuse a suitable category where possible. |
| `subfolderDescriptions` | object, optional | Exact immediate child directory name to plain-language description. This annotates folders discovered during scanning; it does not add paths or change the approved-root boundary. Omit when there are no stable child names to describe. |

Keep `configVersion` unchanged for a one-rule edit unless the repository's release convention says otherwise. Use an intentional version bump for a reviewed configuration release; do not fabricate semantic meaning for the current date-based value.

## 3. Supported path grammar

The contribution policy allows only:

```text
$HOME/<literal-component>/<literal-component>/...
```

For example:

```text
$HOME/Library/Caches/example-tool
```

The current parser requires the `$HOME/` prefix, allows only ASCII letters, digits, dot, underscore, space and hyphen in components, rejects empty, `.` and `..` components, and checks that the path belongs to an approved cache root. It does not expand shell variables or glob patterns. Use only static directory names. Do not use:

- a real username or any machine-specific absolute path;
- `~`, `$USER`, `$TMPDIR`, environment substitutions, or other variables;
- shell expressions, command substitutions, or URLs;
- `*`, `?`, `{}`, regular expressions, or any other pattern syntax;
- `.` or `..` path components;
- a path outside the user's home directory.

The app rejects malformed components, rejects a configured target when it is a symbolic link, verifies the canonical target remains in the home directory, and enforces approved cache roots. Do not assume this protects arbitrary path grammars: only add the literal path form above. Prefer targets whose parent components are normal user-owned directories, and report symlink or alias ambiguity rather than trying to resolve around it.

The path is the exact directory the app scans and moves to Trash. Never point at a broad shared parent just because the desired cache is somewhere below it. Never point at a project root, repository, package checkout, simulator device root, Xcode archive directory, password/keychain store, browser profile, mail/photo library, application support root, or other mixed user data.

## 4. Evidence required before proposing a path

For every proposed rule, establish all of the following:

1. **Ownership:** Identify which tool owns the directory and which versions/platforms use it.
2. **Contents:** Determine what files are actually stored there. A cache-sounding name is not evidence.
3. **Rebuildability:** Confirm the user can recreate the contents through the owning tool or redownload them. Identify anything that is not reproducible, such as local edits, downloaded-only assets, device records, or offline-required packages.
4. **Boundary:** Confirm the exact path contains only the intended generated data, not sibling caches, settings, user state, project files, or valuable historical output. If adding `subfolderDescriptions`, establish what each exact named child stores and describe it accurately; descriptions are annotations, not scan-derived facts.
5. **Currentness:** Check the owning vendor's current documentation/source or inspect a supported clean installation. Cite the evidence in the change summary or PR. If evidence disagrees across versions, include the version scope in the rule text or leave the rule out.
6. **User impact:** Write what the user will need to wait for, download again, rebuild, or temporarily lose access to after cleanup.

Use primary evidence where possible: official vendor documentation, source code maintained by the owning project, or a reproducible inspection of a clean install. Search results and other cleanup apps' lists can be leads, but are not enough to establish safety. Never claim a local path was inspected unless it actually was.

If any condition is uncertain, do not add the path. Report the unresolved question and ask for evidence or clarification in the task summary.

## 5. Risk labels

- `low`: narrow, generated cache; confirmed to contain no user-authored or uniquely retained data; routine regeneration is reliable and impact is limited to a rebuild or index recreation.
- `medium`: still reproducible, but removal can require a large re-download, be unavailable offline, affect device/debug preparation, or cause a substantial first-run delay. Explain the particular impact in `impact`.
- Anything that can remove unique user data, project sources, archives, application state, credentials, or data whose regeneration is unclear is not a rule. Do not use `medium` to excuse uncertainty.

Do not downgrade risk just because the app moves items to Trash. Trash is a recovery aid, not proof that the target is safe.

## 6. Overlap and duplicate checks

Before adding a rule, compare its resolved relative path against every existing rule:

- reject duplicate IDs;
- reject duplicate paths, even if titles or descriptions differ;
- reject ancestor/descendant pairs, such as a parent cache and a child cache in separate rules;
- reject rules whose paths overlap after normalizing separators or redundant components.

The current UI can select multiple rules, including rules from different profiles. If a parent is moved first, a selected child path may no longer exist; overlapping rules create confusing partial cleanup and logs. Keep exactly one rule for each non-overlapping target across profiles where possible.

## 7. Example rule

This is a structural example only. Do not copy the example path for a real tool without independently establishing ownership and safety:

```json
{
  "id": "example-tool-download-cache",
  "role": "programmer",
  "title": "Example Tool Download Cache",
  "path": "$HOME/Library/Caches/example-tool",
  "summary": "Downloaded package archives used as a reusable cache by Example Tool.",
  "impact": "The tool may need to download packages again. Offline installs may fail until the cache is repopulated.",
  "risk": "medium",
  "category": "包管理器",
  "subfolderDescriptions": {
    "archives": "Downloaded package archives.",
    "metadata": "Package index and cache metadata."
  }
}
```

The example is not an approved real cleanup path. The description keys refer to exact immediate child directory names. The scanner displays every actual immediate child folder whether described or not; the user may select a displayed child for cleanup. Selecting a child moves only that child directory to Trash, while selecting the parent moves the whole configured directory. The UI prevents selecting both at once for the same rule.

## 8. Required validation before finishing

For a configuration-only change:

1. Validate JSON syntax:

   ```sh
   python3 -m json.tool Config/cleanup-rules.json >/dev/null
   ```

2. Review the diff and verify every rule has all required fields, supported types/values, a matching role, and a unique ID.
3. Check path grammar, uniqueness, and overlap manually. Do not rely on JSON parsing to validate deletion safety.
4. Check the repository diff for accidental local data:

   ```sh
   git diff --check
   git status --short
   ```

5. Build the app when practical to verify the bundled configuration still compiles with the app:

   ```sh
   xcodebuild -project CleanUpForMacOS.xcodeproj -scheme CleanUpForMacOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
   ```

   A successful build does not prove a configured path exists or is safe. Never run the app's cleanup action as a validation step.

For a change to the parser, authorization, scanning, or deletion implementation, inspect all call sites and run an app build. Add focused tests only when requested by the user or when the repository introduces an established test target and the change requires it.

## 9. PR / completion report format

Report:

- the exact rule IDs added, edited, or removed;
- the primary evidence used to establish contents and rebuildability;
- the stated user impact and risk choice;
- JSON and build checks run;
- any path/version uncertainty that remains.

Do not say “safe” without explaining the scope and evidence. Do not say “tested” when only syntax validation or compilation was performed.
