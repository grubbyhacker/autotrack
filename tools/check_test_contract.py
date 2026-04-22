#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAKEFILE_PATH = ROOT / "Makefile"
CONFIG_PATH = ROOT / "tools" / "test_bridge_config.json"
DISPATCHER_PATH = ROOT / "src" / "orchestrator" / "TestDispatcher.luau"

NON_SUITE_TARGETS = {
    "test",
    "test-list",
    "test-contracts",
    "export-llm-trace",
    "endurance-trace",
    "inspect-llm-trace",
}


def load_makefile_suite_targets() -> set[str]:
    text = MAKEFILE_PATH.read_text(encoding="utf-8")
    lines = text.splitlines()
    body_parts: list[str] = []
    collecting = False

    for line in lines:
        if line.startswith(".PHONY:"):
            collecting = True
            body_parts.append(line[len(".PHONY:") :].strip())
            continue

        if not collecting:
            continue

        body_parts.append(line.strip())
        if not line.rstrip().endswith("\\"):
            break

    if not body_parts:
        raise RuntimeError("Could not find .PHONY block in Makefile.")

    body = " ".join(part.rstrip("\\").strip() for part in body_parts if part.strip())
    return {token for token in body.split() if token not in NON_SUITE_TARGETS}


def load_config_suites() -> set[str]:
    payload = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    suites = payload.get("suites")
    if not isinstance(suites, dict):
        raise RuntimeError("test_bridge_config.json is missing a suites object.")
    return set(suites.keys())


def load_dispatcher_suites() -> set[str]:
    text = DISPATCHER_PATH.read_text(encoding="utf-8")
    return set(re.findall(r'cmd == "([^"]+)"', text))


def print_mismatch(name: str, expected: set[str], actual: set[str]) -> bool:
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if not missing and not extra:
        return False

    print(f"{name} mismatch:")
    if missing:
        print(f"  missing: {', '.join(missing)}")
    if extra:
        print(f"  extra: {', '.join(extra)}")
    return True


def main() -> int:
    makefile_suites = load_makefile_suite_targets()
    config_suites = load_config_suites()
    dispatcher_suites = load_dispatcher_suites()

    has_error = False
    has_error |= print_mismatch("Makefile vs config", config_suites, makefile_suites)
    has_error |= print_mismatch("Dispatcher vs config", config_suites, dispatcher_suites)

    if has_error:
        return 1

    print(f"Suite contract OK: {len(config_suites)} suites aligned across Makefile, config, and dispatcher.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"test-contracts error: {exc}", file=sys.stderr)
        raise SystemExit(2)
