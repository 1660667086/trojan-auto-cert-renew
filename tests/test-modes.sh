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

cat > "${FAKE_BIN}/df" <<'SH'
#!/usr/bin/env sh
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo '/dev/test 20971520 1048576 19922944 5% /'
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

manual_domain_output="$(DOMAIN=manual.example.com "$SCRIPT" --force)"
grep -Fq '[OK] 已将域名写入 Trojan 配置 ssl.sni: manual.example.com' <<<"$manual_domain_output"
python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["ssl"]["sni"] == "manual.example.com"' "$CONFIG"

CLOUDREVE_CONFIG_FILE="${TMP_DIR}/cloudreve-conf.ini"
CLOUDREVE_DB="${TMP_DIR}/cloudreve.db"
CLOUDREVE_BACKUPS="${TMP_DIR}/cloudreve-admin-backups"
cat > "$CLOUDREVE_CONFIG_FILE" <<EOF
[Database]
Type = sqlite
DBFile = $CLOUDREVE_DB
TablePrefix = cd_
EOF
python3 - "$CLOUDREVE_DB" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE cd_users (id INTEGER PRIMARY KEY, email TEXT UNIQUE, nick TEXT, password TEXT, status INTEGER, group_id INTEGER, storage INTEGER, deleted_at TEXT, updated_at TEXT)")
db.execute("CREATE TABLE cd_groups (id INTEGER PRIMARY KEY, name TEXT, max_storage INTEGER, deleted_at TEXT, updated_at TEXT)")
db.execute("INSERT INTO cd_users VALUES (1, 'admin@cloudreve.org', 'admin', '1234567890abcdef:0000000000000000000000000000000000000000', 0, 1, 0, NULL, CURRENT_TIMESTAMP)")
db.execute("INSERT INTO cd_groups VALUES (1, 'Admin', 1073741824, NULL, CURRENT_TIMESTAMP)")
db.commit()
db.close()
PY
cloudreve_output="$(CLOUDREVE_CONFIG="$CLOUDREVE_CONFIG_FILE" \
    CLOUDREVE_ADMIN_EMAIL=owner@example.com CLOUDREVE_ADMIN_NICK=owner \
    CLOUDREVE_ADMIN_PASSWORD=SecurePass123 CLOUDREVE_BACKUP_DIR="$CLOUDREVE_BACKUPS" \
    "$SCRIPT" --cloudreve-admin)"
grep -Fq '[OK] Cloudreve 管理员账号和密码修改成功' <<<"$cloudreve_output"
python3 - "$CLOUDREVE_DB" <<'PY'
import hashlib
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
email, nick, stored = db.execute("SELECT email,nick,password FROM cd_users WHERE id=1").fetchone()
quota = db.execute("SELECT max_storage FROM cd_groups WHERE id=1").fetchone()[0]
salt, digest = stored.split(":", 1)
assert email == "owner@example.com"
assert nick == "owner"
assert len(salt) == 16
assert hashlib.sha1(("SecurePass123" + salt).encode()).hexdigest() == digest
assert quota == 20 * 1024 * 1024 * 1024
PY
[ "$(find "$CLOUDREVE_BACKUPS" -type f | wc -l | tr -d ' ')" = "1" ]

INSTALLED_SCRIPT="${TMP_DIR}/installed/trojan-auto-cert-renew"
CRON_FILE="${TMP_DIR}/trojan-auto-cert-renew.cron"
mkdir -p "$(dirname "$INSTALLED_SCRIPT")"
rm -f "$EXPECT_MARKER"
install_output="$(INSTALL_PATH="$INSTALLED_SCRIPT" CRON_FILE="$CRON_FILE" \
    RUN_CHECK=1 INSTALL_ACTION=automatic \
    CHECK_HOUR=4 CHECK_MINUTE=17 RESTART_HOUR=4 RESTART_MINUTE=47 \
    "$SCRIPT" --install)"
grep -Fq '[OK] 已选择自动模式' <<<"$install_output"
grep -Fq '[OK] 一体化脚本安装完成' <<<"$install_output"
[ ! -e "$EXPECT_MARKER" ]
grep -Fq '17 4 * * * root ' "$CRON_FILE"
grep -Fq -- "$INSTALLED_SCRIPT --scheduled" "$CRON_FILE"
grep -Fq '47 4 * * * root ' "$CRON_FILE"
grep -Fq -- "$INSTALLED_SCRIPT --restart" "$CRON_FILE"

PIPE_INSTALLED_SCRIPT="${TMP_DIR}/pipe-installed/trojan-auto-cert-renew"
PIPE_CRON_FILE="${TMP_DIR}/pipe-install.cron"
pipe_install_output="$(cat "$SCRIPT" | \
    RAW_BASE="file://${ROOT_DIR}" INSTALL_PATH="$PIPE_INSTALLED_SCRIPT" \
    CRON_FILE="$PIPE_CRON_FILE" RUN_CHECK=0 bash -s -- --install)"
grep -Fq '[OK] 一体化脚本安装完成' <<<"$pipe_install_output"
cmp -s "$SCRIPT" "$PIPE_INSTALLED_SCRIPT"
grep -Fq -- "$PIPE_INSTALLED_SCRIPT --scheduled" "$PIPE_CRON_FILE"

UNINSTALL_LOG="${TMP_DIR}/uninstall.log"
UNINSTALL_BACKUPS="${TMP_DIR}/uninstall-backups"
mkdir -p "$UNINSTALL_BACKUPS"
touch "$UNINSTALL_LOG" "${UNINSTALL_BACKUPS}/config.json.test"
uninstall_output="$(INSTALL_PATH="$INSTALLED_SCRIPT" CRON_FILE="$CRON_FILE" \
    LOG_FILE="$UNINSTALL_LOG" BACKUP_DIR="$UNINSTALL_BACKUPS" \
    "$SCRIPT" --uninstall --purge)"
grep -Fq '[OK] 已卸载' <<<"$uninstall_output"
[ ! -e "$INSTALLED_SCRIPT" ]
[ ! -e "$CRON_FILE" ]
[ ! -e "$UNINSTALL_LOG" ]
[ ! -e "$UNINSTALL_BACKUPS" ]

INSTALL_PATH="$PIPE_INSTALLED_SCRIPT" CRON_FILE="$PIPE_CRON_FILE" \
    "$SCRIPT" --uninstall >/dev/null
[ ! -e "$PIPE_INSTALLED_SCRIPT" ]
[ ! -e "$PIPE_CRON_FILE" ]

echo 'All mode and auto-domain tests passed.'
