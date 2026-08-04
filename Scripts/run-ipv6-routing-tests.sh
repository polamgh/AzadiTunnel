#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_dir="$(mktemp -d /tmp/azadi-ipv6-routing-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

swiftc -parse-as-library \
  "$repo_dir/AzadiTunnelShared/AppGroupConstants.swift" \
  "$repo_dir/AzadiTunnelShared/PacketEngineCapabilities.swift" \
  "$repo_dir/AzadiTunnelShared/IPv6PacketRejector.swift" \
  "$repo_dir/AzadiTunnelShared/SharedLogger.swift" \
  "$repo_dir/AzadiTunnelShared/PsiphonLocalProxyEndpoints.swift" \
  "$repo_dir/AzadiTunnelShared/PsiphonTunnelCore.swift" \
  "$repo_dir/AzadiTunnelShared/PsiphonTunnelEngine.swift" \
  "$repo_dir/Tests/IPv6RoutingPolicyTests.swift" \
  -o "$test_dir/ipv6-routing-tests"

"$test_dir/ipv6-routing-tests"
