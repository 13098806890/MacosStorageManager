#!/usr/bin/env python3
"""Validate the static shape and non-overlap of a cleanup profile."""

import json
import re
import sys
from pathlib import Path


ID_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
COMPONENT_PATTERN = re.compile(r"^[A-Za-z0-9._ -]+$")
REQUIRED_RULE_FIELDS = {
    "id",
    "role",
    "title",
    "path",
    "summary",
    "impact",
    "risk",
    "category",
}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: validate_cleanup_rules.py <profile.json>")

    path = Path(sys.argv[1])
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read valid JSON: {error}")

    if not isinstance(config, dict):
        fail("top-level value must be an object")
    if type(config.get("schemaVersion")) is not int or config["schemaVersion"] != 1:
        fail("schemaVersion must be integer 1")
    if not isinstance(config.get("configVersion"), str) or not config["configVersion"].strip():
        fail("configVersion must be a non-empty string")
    role = config.get("role")
    if not isinstance(role, str) or not role.strip():
        fail("role must be a non-empty string")
    rules = config.get("rules")
    if not isinstance(rules, list):
        fail("rules must be an array")

    seen_ids: set[str] = set()
    paths: list[tuple[str, tuple[str, ...]]] = []
    for index, rule in enumerate(rules):
        label = f"rules[{index}]"
        if not isinstance(rule, dict):
            fail(f"{label} must be an object")
        missing = REQUIRED_RULE_FIELDS - rule.keys()
        if missing:
            fail(f"{label} is missing fields: {', '.join(sorted(missing))}")

        rule_id = rule["id"]
        if not isinstance(rule_id, str) or not ID_PATTERN.fullmatch(rule_id):
            fail(f"{label}.id must be lowercase kebab-case")
        if rule_id in seen_ids:
            fail(f"duplicate rule id: {rule_id}")
        seen_ids.add(rule_id)

        if rule["role"] != role:
            fail(f"{label}.role must match the top-level role")
        for field in ("title", "summary", "impact", "category"):
            if not isinstance(rule[field], str) or not rule[field].strip():
                fail(f"{label}.{field} must be a non-empty string")
        if not isinstance(rule["risk"], str) or rule["risk"] not in {"low", "medium"}:
            fail(f"{label}.risk must be low or medium")

        configured_path = rule["path"]
        if not isinstance(configured_path, str) or not configured_path.startswith("$HOME/"):
            fail(f"{label}.path must start with the literal $HOME/ prefix")
        components = tuple(configured_path[len("$HOME/") :].split("/"))
        if not components or any(
            component in {"", ".", ".."} or not COMPONENT_PATTERN.fullmatch(component)
            for component in components
        ):
            fail(f"{label}.path contains an unsupported component")

        descriptions = rule.get("subfolderDescriptions")
        if descriptions is not None and (
            not isinstance(descriptions, dict)
            or any(
                not isinstance(key, str)
                or not COMPONENT_PATTERN.fullmatch(key)
                or key in {".", ".."}
                or "/" in key
                or not isinstance(value, str)
                for key, value in descriptions.items()
            )
        ):
            fail(f"{label}.subfolderDescriptions must map strings to strings")
        paths.append((rule_id, components))

    for index, (left_id, left_path) in enumerate(paths):
        for right_id, right_path in paths[index + 1 :]:
            shared_length = min(len(left_path), len(right_path))
            if left_path[:shared_length] == right_path[:shared_length]:
                fail(f"overlapping paths: {left_id} and {right_id}")

    print(f"Validated {len(rules)} cleanup rules in {path}.")
    print("Approved-root membership and deletion safety still require maintainer review.")


if __name__ == "__main__":
    main()
