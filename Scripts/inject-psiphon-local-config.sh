#!/usr/bin/env bash
# Copies distributor keys into the app bundle source tree before compile (gitignored destination).
# Sources (first match wins):
#   1. AzadiTunnel/Resources/Bundled/psiphon-config.local.json (already in place)
#   2. $AZADI_PSIPHON_LOCAL_CONFIG
#   3. $HOME/.config/azaditunnel/psiphon-config.local.json
#   4. PSIPHON_* env vars via merge-shiro-distributor-keys.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/AzadiTunnel/Resources/Bundled/psiphon-config.local.json"
MERGE="${ROOT}/Tooling/psiphon/merge-shiro-distributor-keys.sh"

if [[ -f "$DEST" ]] && [[ -s "$DEST" ]]; then
  exit 0
fi

if [[ -n "${AZADI_PSIPHON_LOCAL_CONFIG:-}" && -f "$AZADI_PSIPHON_LOCAL_CONFIG" ]]; then
  cp "$AZADI_PSIPHON_LOCAL_CONFIG" "$DEST"
  echo "inject-psiphon-local-config: copied AZADI_PSIPHON_LOCAL_CONFIG"
  exit 0
fi

if [[ -f "${HOME}/.config/azaditunnel/psiphon-config.local.json" ]]; then
  cp "${HOME}/.config/azaditunnel/psiphon-config.local.json" "$DEST"
  echo "inject-psiphon-local-config: copied ~/.config/azaditunnel/psiphon-config.local.json"
  exit 0
fi

if [[ -n "${PSIPHON_SERVER_ENTRY_SIGNATURE_PUBLIC_KEY:-}" ]]; then
  "$MERGE"
  echo "inject-psiphon-local-config: wrote from PSIPHON_* env"
  exit 0
fi

exit 0
