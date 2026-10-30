# Security policy

## Reporting a vulnerability

Please do not publish exploitable security details in a public issue. Use GitHub's **Report a vulnerability** flow for this repository when it is available. If that option is unavailable, contact the repository owner privately through their GitHub profile and include only the information needed to reproduce the issue.

Include the affected app version, macOS version, impact, and a minimal reproduction. Do not attach cleanup logs or unredacted screenshots: local logs can contain absolute paths.

## Scope

Security reports are especially relevant to path validation, symbolic-link handling, imported configurations, cleanup confirmation, Trash operations, simulator deletion, and local privacy. The app is not sandboxed and is intended for direct distribution; imported cleanup rules remain constrained by the app's supported path grammar and runtime allowlist.
