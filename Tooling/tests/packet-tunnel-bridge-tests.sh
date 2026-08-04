#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/azadi-packet-tunnel-tests.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT

swiftc \
  "${REPO_ROOT}/AzadiTunnelShared/PsiphonPacketTunnelCapabilities.swift" \
  "${REPO_ROOT}/AzadiTunnelPacketTunnel/PsiphonPacketTunnelPacketQueue.swift" \
  "${SCRIPT_DIR}/PacketTunnelBridgeTests.swift" \
  -o "${TEST_ROOT}/packet-tunnel-bridge-tests"

"${TEST_ROOT}/packet-tunnel-bridge-tests"
