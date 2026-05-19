#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/trojan-auto-cert-renew}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/trojan-auto-cert-renew}"

[ "$(id -u)" -eq 0 ] || {
    echo "please run as root" >&2
    exit 1
}

rm -f "$CRON_FILE"
rm -f "$INSTALL_PATH"

echo "removed $INSTALL_PATH and $CRON_FILE"
