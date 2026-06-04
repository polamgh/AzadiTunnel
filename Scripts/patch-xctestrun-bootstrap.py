#!/usr/bin/env python3
"""Strip injected dylibs from xctestrun that break XCTest bootstrap on physical devices (exit 74)."""
from __future__ import annotations

import plistlib
import sys
from pathlib import Path

STRIP_KEYS = {
    "DYLD_INSERT_LIBRARIES",
    "OS_ACTIVITY_DT_MODE",
    "PERFC_ENABLE_EXTENDED_DIAGNOSTIC_FORMAT",
    "PERFC_ENABLE_PROFILE_MODE",
    "PERFC_RESET_INSERT_LIBRARIES",
    "PERFC_SUPPRESS_SYSTEM_REPORTS",
    "SQLITE_ENABLE_THREAD_ASSERTIONS",
}


def scrub_env(env: dict) -> bool:
    changed = False
    for key in list(env.keys()):
        if key in STRIP_KEYS:
            del env[key]
            changed = True
    return changed


def inject_launch_timeout(env: dict) -> bool:
    if env.get("XCTUIApplicationLaunchDefaultTimeout") == "120":
        return False
    env["XCTUIApplicationLaunchDefaultTimeout"] = "120"
    return True


def walk(node) -> bool:
    changed = False
    if isinstance(node, dict):
        if "EnvironmentVariables" in node and isinstance(node["EnvironmentVariables"], dict):
            if scrub_env(node["EnvironmentVariables"]):
                changed = True
            if inject_launch_timeout(node["EnvironmentVariables"]):
                changed = True
        if "TestingEnvironmentVariables" in node and isinstance(node["TestingEnvironmentVariables"], dict):
            if scrub_env(node["TestingEnvironmentVariables"]):
                changed = True
            if inject_launch_timeout(node["TestingEnvironmentVariables"]):
                changed = True
        if "UITargetAppEnvironmentVariables" in node and isinstance(node["UITargetAppEnvironmentVariables"], dict):
            if inject_launch_timeout(node["UITargetAppEnvironmentVariables"]):
                changed = True
        if node.get("UITargetAppPerformanceAntipatternCheckerEnabled") is True:
            node["UITargetAppPerformanceAntipatternCheckerEnabled"] = False
            changed = True
        if node.get("DiagnosticCollectionPolicy") == 1:
            node["DiagnosticCollectionPolicy"] = 0
            changed = True
        for value in node.values():
            if walk(value):
                changed = True
    elif isinstance(node, list):
        for item in node:
            if walk(item):
                changed = True
    return changed


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to.xctestrun>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    data = plistlib.loads(path.read_bytes())
    if not walk(data):
        print(f"no bootstrap patches applied: {path}")
        return 0
    path.write_bytes(plistlib.dumps(data))
    print(f"patched xctestrun for device bootstrap: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
