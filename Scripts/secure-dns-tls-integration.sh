#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/azadi-secure-dns-tls.XXXXXX")"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT

mkdir -p "$test_dir/capture"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$test_dir/server.key" \
  -out "$test_dir/server.pem" \
  -days 1 \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost" \
  >/dev/null 2>&1
openssl x509 -in "$test_dir/server.pem" -outform der -out "$test_dir/server.der"

python3 "$repo_dir/Tests/local_tls_doh_server.py" \
  --cert "$test_dir/server.pem" \
  --key "$test_dir/server.key" \
  --port-file "$test_dir/port" \
  --capture-dir "$test_dir/capture" \
  --sni-file "$test_dir/sni.txt" \
  >/dev/null 2>&1 &
server_pid=$!

for _ in {1..100}; do
  [[ -s "$test_dir/port" ]] && break
  sleep 0.05
done
[[ -s "$test_dir/port" ]] || { echo "TLS integration server did not start" >&2; exit 1; }
port="$(<"$test_dir/port")"

xcrun swiftc -O -parse-as-library -DSECURE_DNS_INTEGRATION_TEST \
  "$repo_dir/AzadiTunnelShared/SecureDNSClock.swift" \
  "$repo_dir/AzadiTunnelPacketTunnel/NWConnectionTLSClient.swift" \
  "$repo_dir/Tests/SecureDNSTLSIntegration.swift" \
  -o "$test_dir/secure-dns-tls-integration"

"$test_dir/secure-dns-tls-integration" "$port" "$test_dir/server.der" "$test_dir/capture"
echo "secure-dns-tls-integration: PASS"
