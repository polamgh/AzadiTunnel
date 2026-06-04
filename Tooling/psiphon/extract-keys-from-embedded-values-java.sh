#!/usr/bin/env bash
# Parse Shiro EmbeddedValues.java (after ./gradlew generateEmbeddedValues with secrets) → psiphon-config.local.json
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JAVA_FILE="${1:-}"

if [[ -z "$JAVA_FILE" || ! -f "$JAVA_FILE" ]]; then
  echo "Usage: $0 /path/to/shiro-android/.../EmbeddedValues.java" >&2
  exit 1
fi

export PSIPHON_SERVER_ENTRY_SIGNATURE_PUBLIC_KEY="$(
  sed -n 's/.*SERVER_ENTRY_SIGNATURE_PUBLIC_KEY = "\([^"]*\)".*/\1/p' "$JAVA_FILE" | head -1
)"
export PSIPHON_SERVER_ENTRY_EXCHANGE_OBFUSCATION_KEY="$(
  sed -n 's/.*SERVER_ENTRY_EXCHANGE_OBFUSCATION_KEY = "\([^"]*\)".*/\1/p' "$JAVA_FILE" | head -1
)"
export PSIPHON_REMOTE_SERVER_LIST_URLS_JSON="$(
  sed -n 's/.*REMOTE_SERVER_LIST_URLS_JSON = "\(.*\)".*/\1/p' "$JAVA_FILE" | head -1 | sed 's/\\"/"/g'
)"
export PSIPHON_REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY="$(
  sed -n 's/.*REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY = "\([^"]*\)".*/\1/p' "$JAVA_FILE" | head -1
)"
export PSIPHON_OBFUSCATED_SERVER_LIST_ROOT_URLS_JSON="$(
  sed -n 's/.*OBFUSCATED_SERVER_LIST_ROOT_URLS_JSON = "\(.*\)".*/\1/p' "$JAVA_FILE" | head -1 | sed 's/\\"/"/g'
)"

if [[ -z "$PSIPHON_SERVER_ENTRY_SIGNATURE_PUBLIC_KEY" ]]; then
  echo "No SERVER_ENTRY_SIGNATURE_PUBLIC_KEY in $JAVA_FILE — build Shiro with distributor secrets first." >&2
  exit 1
fi

exec "$(dirname "$0")/merge-shiro-distributor-keys.sh"
