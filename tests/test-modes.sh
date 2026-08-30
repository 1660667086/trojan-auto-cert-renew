#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/trojan-auto-cert-renew"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="${TMP_DIR}/bin"
CONFIG="${TMP_DIR}/config.json"
CERT="${TMP_DIR}/fullchain.cer"
KEY="${TMP_DIR}/domain.key"
EXPECT_MARKER="${TMP_DIR}/expect-called"
SYSTEMCTL_MARKER="${TMP_DIR}/systemctl-restarted"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$FAKE_BIN"
printf '%s\n' certificate > "$CERT"
printf '%s\n' private-key > "$KEY"
printf '{"ssl":{"cert":"%s","key":"%s","sni":"1.2.3.4"}}\n' "$CERT" "$KEY" > "$CONFIG"

cat > "${FAKE_BIN}/id" <<'SH'
#!/usr/bin/env sh
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH

cat > "${FAKE_BIN}/systemctl" <<'SH'
#!/usr/bin/env sh
case "${1:-}" in
    show) echo 'LoadState=not-found' ;;
    is-active) [ -e "$SYSTEMCTL_MARKER" ] ;;
    list-units|list-unit-files|cat) exit 0 ;;
    restart) : > "$SYSTEMCTL_MARKER" ;;
    start|stop) exit 0 ;;
    *) exit 0 ;;
esac
SH

cat > "${FAKE_BIN}/trojan" <<'SH'
#!/usr/bin/env sh
if [ "${1:-}" = "info" ]; then
    [ "${TROJAN_INFO_EMPTY:-0}" = "1" ] && exit 0
    echo 'trojan://test@auto.example.com:443'
fi
SH

cat > "${FAKE_BIN}/openssl" <<'SH'
#!/usr/bin/env sh
case " $* " in
    *' -checkend '*) exit 0 ;;
    *' -enddate '*) echo 'notAfter=Nov 27 13:28:13 2026 GMT' ;;
    *' -subject '*) echo 'subject=CN = auto.example.com' ;;
    *' -issuer '*) echo "issuer=C = US, O = Let's Encrypt, CN = Test" ;;
    *' -ext subjectAltName '*) echo 'X509v3 Subject Alternative Name: DNS:auto.example.com' ;;
    *) exit 0 ;;
esac
SH

cat > "${FAKE_BIN}/expect" <<'SH'
#!/usr/bin/env sh
cat >/dev/null
: > "$EXPECT_MARKER"
SH

cat > "${FAKE_BIN}/socat" <<'SH'
#!/usr/bin/env sh
exit 0
SH

chmod 700 "${FAKE_BIN}"/*
export PATH="${FAKE_BIN}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CONFIG_PATH="$CONFIG"
export LOG_FILE="${TMP_DIR}/run.log"
export BACKUP_DIR="${TMP_DIR}/backups"
export DISABLE_ACME_CRON=0
export SERVICE_STOP_LIST=""
export EXPECT_MARKER
export SYSTEMCTL_MARKER
unset DOMAIN TROJAN_CLI TROJAN_SERVICE

dry_output="$($SCRIPT --dry-run)"
grep -Fq '域名: auto.example.com' <<<"$dry_output"
grep -Fq '域名来源: trojan info share link' <<<"$dry_output"
grep -Fq '到期时间: 2026 年 11 月 27 日 21:28:13' <<<"$dry_output"

cert_output="$(TROJAN_INFO_EMPTY=1 $SCRIPT --dry-run)"
grep -Fq '域名: auto.example.com' <<<"$cert_output"
grep -Fq '域名来源: current certificate' <<<"$cert_output"

rm -f "$EXPECT_MARKER"
scheduled_output="$($SCRIPT --scheduled)"
grep -Fq '定时检查完成' <<<"$scheduled_output"
[ ! -e "$EXPECT_MARKER" ]

legacy_cron_output="$(TROJAN_AUTO_CERT_CRON=1 $SCRIPT)"
grep -Fq '定时检查完成' <<<"$legacy_cron_output"
[ ! -e "$EXPECT_MARKER" ]

restart_output="$(TROJAN_SERVICE=trojan $SCRIPT --restart)"
grep -Fq '[OK] Trojan 服务已重启并运行: trojan' <<<"$restart_output"
[ -e "$SYSTEMCTL_MARKER" ]

manual_output="$($SCRIPT)"
grep -Fq '手动运行模式' <<<"$manual_output"
grep -Fq '[OK] 证书申请并安装成功' <<<"$manual_output"
grep -Fq '到期时间: 2026 年 11 月 27 日 21:28:13' <<<"$manual_output"
[ -e "$EXPECT_MARKER" ]

INSTALLED_SCRIPT="${TMP_DIR}/installed/trojan-auto-cert-renew"
CRON_FILE="${TMP_DIR}/trojan-auto-cert-renew.cron"
mkdir -p "$(dirname "$INSTALLED_SCRIPT")"
rm -f "$EXPECT_MARKER"
install_output="$(INSTALL_PATH="$INSTALLED_SCRIPT" CRON_FILE="$CRON_FILE" \
    RUN_CHECK=1 INSTALL_ACTION=automatic \
    CHECK_HOUR=4 CHECK_MINUTE=17 RESTART_HOUR=4 RESTART_MINUTE=47 \
    "$ROOT_DIR/install.sh")"
grep -Fq '[OK] 已选择自动模式' <<<"$install_output"
[ ! -e "$EXPECT_MARKER" ]
grep -Fq '17 4 * * * root ' "$CRON_FILE"
grep -Fq -- "$INSTALLED_SCRIPT --scheduled" "$CRON_FILE"
grep -Fq '47 4 * * * root ' "$CRON_FILE"
grep -Fq -- "$INSTALLED_SCRIPT --restart" "$CRON_FILE"

echo 'All mode and auto-domain tests passed.'
