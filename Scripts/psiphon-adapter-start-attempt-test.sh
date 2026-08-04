#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/azadi-adapter-start-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc \
  "$repo_dir/AzadiTunnelPacketTunnel/PsiphonStartAttemptCoordinator.swift" \
  "$repo_dir/Tests/PsiphonTunnelAdapterStartAttemptTests.swift" \
  -o "$test_dir/PsiphonTunnelAdapterStartAttemptTests"

"$test_dir/PsiphonTunnelAdapterStartAttemptTests"
