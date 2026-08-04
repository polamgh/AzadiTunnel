#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/azadi-secure-dns.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

swiftc -O -parse-as-library \
  "$repo_dir/AzadiTunnelShared/SecureDNSWire.swift" \
  "$repo_dir/AzadiTunnelShared/SecureDNSCache.swift" \
  "$repo_dir/AzadiTunnelShared/SecureDNSClock.swift" \
  "$repo_dir/AzadiTunnelShared/SecureDNSConcurrencyLimiter.swift" \
  "$repo_dir/AzadiTunnelShared/SecureDNSResolutionCoordinator.swift" \
  "$repo_dir/AzadiTunnelShared/SecureDNSBootstrap.swift" \
  "$repo_dir/AzadiTunnelShared/SecureDNSFailoverPolicy.swift" \
  "$repo_dir/Tests/SecureDNSResolverTests.swift" \
  -o "$test_dir/secure-dns-tests"
"$test_dir/secure-dns-tests"

swiftc -O -parse-as-library -DSECURE_DNS_STANDALONE_TEST \
  "$repo_dir/AzadiTunnelShared/AppSettings.swift" \
  "$repo_dir/AzadiTunnelShared/SharedSettingsMigration.swift" \
  "$repo_dir/Tests/StandaloneAppSettingsTypes.swift" \
  "$repo_dir/Tests/SharedSettingsMigrationTests.swift" \
  -o "$test_dir/settings-migration-tests"
"$test_dir/settings-migration-tests"

if rg -n 'tcpDnsQuery|queryDoT|dotEndpoint|/resolve|http://dns\.|URLSession\.|systemHTTPProxyPort|startSystemHttpListener|SECURE_DNS_SYSTEM_HTTP|FDRelaySession|loopbackUpstream' \
  "$repo_dir/AzadiTunnelPacketTunnel" "$repo_dir/AzadiTunnelShared"; then
  echo "secure DNS cleartext escape check failed" >&2
  exit 1
fi

if rg -n 'logRaw\([^\n]*(qname|queryId)|log\([^\n]*(qname|queryId)' \
  "$repo_dir/AzadiTunnelPacketTunnel/SecureDNSDoHClient.swift" \
  "$repo_dir/AzadiTunnelPacketTunnel/SecureDNSResolver.swift" \
  "$repo_dir/AzadiTunnelPacketTunnel/TunnelDnsForwarder.swift"; then
  echo "secure DNS query metadata logging check failed" >&2
  exit 1
fi

if rg -n 'SECURE_DNS_DOH_ATTEMPT(_FAILED)?' \
  "$repo_dir/AzadiTunnelPacketTunnel/SecureDNSDoHClient.swift" \
  "$repo_dir/AzadiTunnelPacketTunnel/SecureDNSResolver.swift"; then
  echo "secure DNS contains per-attempt persistent logging" >&2
  exit 1
fi

rg -q 'SECURE_DNS_ADMISSION_CONFIG' \
  "$repo_dir/AzadiTunnelPacketTunnel/SecureDNSResolver.swift"

rg -q 'Content-Type: application/dns-message' "$repo_dir/AzadiTunnelPacketTunnel/SecureDNSDoHClient.swift"
if rg -n 'Content-Type: application/json|Accept: application/json' \
  "$repo_dir/AzadiTunnelPacketTunnel/SecureDNSDoHClient.swift"; then
  echo "DoH client contains JSON media type" >&2
  exit 1
fi

echo "secure-dns-tests: cleartext checks PASS"
