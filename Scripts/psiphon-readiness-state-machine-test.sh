#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/azadi-readiness-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc \
  "$repo_dir/AzadiTunnelShared/PsiphonLocalProxyEndpoints.swift" \
  "$repo_dir/AzadiTunnelShared/PsiphonReadinessStateMachine.swift" \
  "$repo_dir/Tests/PsiphonReadinessStateMachineTests.swift" \
  -o "$test_dir/PsiphonReadinessStateMachineTests"

"$test_dir/PsiphonReadinessStateMachineTests"
