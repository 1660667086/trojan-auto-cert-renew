#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/trojan-auto-cert-renew}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/trojan-auto-cert-renew}"
LOG_FILE="${LOG_FILE:-/var/log/trojan-auto-cert-renew.log}"
BACKUP_DIR="${BACKUP_DIR:-/root/trojan-cert-backups}"
PURGE="${PURGE:-0}"

log() {
    printf '[trojan-auto-cert] %s\n' "$*"
}

[ "$(id -u)" -eq 0 ] || {
    echo "please run as root" >&2
    exit 1
}

rm -f "$CRON_FILE"
rm -f "$INSTALL_PATH"

if command -v crontab >/dev/null 2>&1; then
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v 'trojan-auto-cert-renew' > "$tmp" || true
    crontab "$tmp" || true
    rm -f "$tmp"
fi

log "removed: $INSTALL_PATH"
log "removed: $CRON_FILE"
log "removed old root crontab entries matching trojan-auto-cert-renew"

if [ "$PURGE" = "1" ]; then
    rm -f "$LOG_FILE"
    rm -rf "$BACKUP_DIR"
    log "purged log: $LOG_FILE"
    log "purged backups: $BACKUP_DIR"
fi

log "done. Certificates, acme.sh, Trojan config, and Trojan service were not removed."
