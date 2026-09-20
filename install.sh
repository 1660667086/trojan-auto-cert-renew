#!/usr/bin/env bash
set -Eeuo pipefail

RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/1660667086/trojan-auto-cert-renew/main}"
SCRIPT_DIR=""
SCRIPT_PATH="${BASH_SOURCE[0]-}"

if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
fi

if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/trojan-auto-cert-renew" ]; then
    exec bash "${SCRIPT_DIR}/trojan-auto-cert-renew" --install "$@"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "${RAW_BASE%/}/trojan-auto-cert-renew?ts=$(date +%s)" -o "$tmp"
bash "$tmp" --install "$@"
