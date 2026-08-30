#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export LANG=C

PREFIX="${PREFIX:-/usr/local}"
INSTALL_PATH="${INSTALL_PATH:-${PREFIX}/sbin/trojan-auto-cert-renew}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/trojan-auto-cert-renew}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/1660667086/trojan-auto-cert-renew/main}"
RENEW_DAYS="${RENEW_DAYS:-15}"
CHECK_MINUTE="${CHECK_MINUTE:-17}"
CHECK_HOUR="${CHECK_HOUR:-4}"
DAILY_RESTART="${DAILY_RESTART:-1}"
RESTART_MINUTE="${RESTART_MINUTE:-47}"
RESTART_HOUR="${RESTART_HOUR:-4}"
RUN_CHECK="${RUN_CHECK:-1}"
INSTALL_ACTION="${INSTALL_ACTION:-ask}"
MANUAL_DOMAIN="${MANUAL_DOMAIN:-}"
DISABLE_ACME_CRON="${DISABLE_ACME_CRON:-1}"
SERVICE_STOP_LIST="${SERVICE_STOP_LIST:-trojan trojan-go trojan-web nginx caddy apache2 httpd cloudreve}"
CONFIG_PATH="${CONFIG_PATH:-}"
DOMAIN="${DOMAIN:-}"
TROJAN_CLI="${TROJAN_CLI:-}"
TROJAN_SERVICE="${TROJAN_SERVICE:-}"
CERT_CHOICE="${CERT_CHOICE:-1}"
ALWAYS_START_TROJAN="${ALWAYS_START_TROJAN:-1}"
DISPLAY_TZ="${DISPLAY_TZ:-Asia/Shanghai}"
FIX_APT_ARCHIVE="${FIX_APT_ARCHIVE:-0}"

usage() {
    cat <<'USAGE'
Usage:
  bash install.sh
  curl -fsSL https://raw.githubusercontent.com/1660667086/trojan-auto-cert-renew/main/install.sh | bash

Environment variables:
  RENEW_DAYS=15
  CHECK_HOUR=4
  CHECK_MINUTE=17
  DAILY_RESTART=1
  RESTART_HOUR=4
  RESTART_MINUTE=47
  RUN_CHECK=1
  INSTALL_ACTION=ask
  MANUAL_DOMAIN=www.example.com
  DISABLE_ACME_CRON=1
  SERVICE_STOP_LIST="trojan trojan-go trojan-web nginx caddy apache2 httpd cloudreve"
  CONFIG_PATH=/usr/local/etc/trojan/config.json
  DOMAIN=www.example.com
  TROJAN_CLI=/usr/local/bin/trojan
  TROJAN_SERVICE=trojan
  CERT_CHOICE=1
  ALWAYS_START_TROJAN=1
  DISPLAY_TZ=Asia/Shanghai
  FIX_APT_ARCHIVE=0
  RAW_BASE=https://raw.githubusercontent.com/1660667086/trojan-auto-cert-renew/main

For Debian 10 buster with expired mirror sources:
  curl -fsSL https://raw.githubusercontent.com/1660667086/trojan-auto-cert-renew/main/install.sh | FIX_APT_ARCHIVE=1 bash
USAGE
}

log() {
    printf '[trojan-auto-cert] %s\n' "$*"
}

die() {
    printf '[trojan-auto-cert] ERROR: %s\n' "$*" >&2
    exit 1
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "please run as root"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

os_codename() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        printf '%s' "${VERSION_CODENAME:-}"
    fi
}

configure_debian_buster_archive() {
    local codename backup_dir file
    codename="$(os_codename)"
    [ "$codename" = "buster" ] || die "FIX_APT_ARCHIVE=1 only supports Debian 10 buster; detected: ${codename:-unknown}"

    backup_dir="/root/apt-sources-backup-$(date '+%Y%m%d%H%M%S')"
    mkdir -p "$backup_dir"

    [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$backup_dir/sources.list"
    if [ -d /etc/apt/sources.list.d ]; then
        cp -a /etc/apt/sources.list.d "$backup_dir/sources.list.d" 2>/dev/null || true
    fi

    log "Backing up APT sources to $backup_dir"
    for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -f "$file" ] || continue
        sed -i.bak '/buster/ s/^/# disabled by trojan-auto-cert: /' "$file"
    done

    cat > /etc/apt/sources.list.d/debian-buster-archive.list <<'EOF'
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian buster-updates main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main contrib non-free
EOF

    cat > /etc/apt/apt.conf.d/99trojan-auto-cert-archive <<'EOF'
Acquire::Check-Valid-Until "false";
EOF

    log "Switched Debian buster APT sources to archive.debian.org"
}

apt_update_or_fix() {
    if apt-get update; then
        return 0
    fi

    if [ "$FIX_APT_ARCHIVE" = "1" ]; then
        log "apt-get update failed; trying Debian buster archive source fix..."
        configure_debian_buster_archive
        apt-get update
        return 0
    fi

    die "apt-get update failed. If this is Debian 10 buster, rerun with: curl -fsSL https://raw.githubusercontent.com/1660667086/trojan-auto-cert-renew/main/install.sh | FIX_APT_ARCHIVE=1 bash"
}

install_packages() {
    local packages=()
    local p

    for p in bash curl openssl expect socat; do
        has_cmd "$p" || packages+=("$p")
    done

    if ! has_cmd python3 && ! has_cmd python; then
        packages+=(python3)
    fi

    [ "${#packages[@]}" -eq 0 ] && return 0

    log "Installing dependencies: ${packages[*]}"
    if has_cmd apt-get; then
        apt_update_or_fix
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    elif has_cmd dnf; then
        dnf install -y "${packages[@]}"
    elif has_cmd yum; then
        yum install -y "${packages[@]}"
    elif has_cmd zypper; then
        zypper --non-interactive install "${packages[@]}"
    else
        die "unsupported package manager; please install manually: ${packages[*]}"
    fi
}

install_script() {
    local source_dir
    local script_path
    local tmp
    script_path="${BASH_SOURCE[0]-}"
    if [ -n "$script_path" ] && [ -f "$script_path" ]; then
        source_dir="$(cd "$(dirname "$script_path")" && pwd)"
    else
        source_dir=""
    fi

    if [ -n "$source_dir" ] && [ -f "${source_dir}/trojan-auto-cert-renew" ]; then
        install -m 700 "${source_dir}/trojan-auto-cert-renew" "$INSTALL_PATH"
    else
        has_cmd curl || die "curl is required to fetch trojan-auto-cert-renew"
        tmp="$(mktemp)"
        curl -fsSL "${RAW_BASE%/}/trojan-auto-cert-renew" -o "$tmp"
        install -m 700 "$tmp" "$INSTALL_PATH"
        rm -f "$tmp"
    fi
    log "Installed $INSTALL_PATH"
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

install_cron() {
    local cmd restart_cmd restart_line
    cmd="RENEW_DAYS=$(shell_quote "$RENEW_DAYS")"
    cmd="${cmd} TROJAN_AUTO_CERT_CRON=1"
    cmd="${cmd} DISABLE_ACME_CRON=$(shell_quote "$DISABLE_ACME_CRON")"
    cmd="${cmd} SERVICE_STOP_LIST=$(shell_quote "$SERVICE_STOP_LIST")"
    cmd="${cmd} CERT_CHOICE=$(shell_quote "$CERT_CHOICE")"
    cmd="${cmd} ALWAYS_START_TROJAN=$(shell_quote "$ALWAYS_START_TROJAN")"
    cmd="${cmd} DISPLAY_TZ=$(shell_quote "$DISPLAY_TZ")"
    [ -n "$CONFIG_PATH" ] && cmd="${cmd} CONFIG_PATH=$(shell_quote "$CONFIG_PATH")"
    [ -n "$DOMAIN" ] && cmd="${cmd} DOMAIN=$(shell_quote "$DOMAIN")"
    [ -n "$TROJAN_CLI" ] && cmd="${cmd} TROJAN_CLI=$(shell_quote "$TROJAN_CLI")"
    [ -n "$TROJAN_SERVICE" ] && cmd="${cmd} TROJAN_SERVICE=$(shell_quote "$TROJAN_SERVICE")"
    cmd="${cmd} ${INSTALL_PATH} --scheduled >/dev/null 2>&1"

    restart_line=""
    if [ "$DAILY_RESTART" = "1" ]; then
        restart_cmd="TROJAN_AUTO_CERT_CRON=1"
        restart_cmd="${restart_cmd} DISPLAY_TZ=$(shell_quote "$DISPLAY_TZ")"
        [ -n "$TROJAN_SERVICE" ] && restart_cmd="${restart_cmd} TROJAN_SERVICE=$(shell_quote "$TROJAN_SERVICE")"
        restart_cmd="${restart_cmd} ${INSTALL_PATH} --restart >/dev/null 2>&1"
        restart_line="${RESTART_MINUTE} ${RESTART_HOUR} * * * root ${restart_cmd}"
    fi

    cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${CHECK_MINUTE} ${CHECK_HOUR} * * * root ${cmd}
${restart_line}
EOF
    chmod 644 "$CRON_FILE"
    log "Installed cron: $CRON_FILE"
}

print_install_result() {
    log "[OK] 安装成功: $INSTALL_PATH"

    if [ -f "$CRON_FILE" ] && grep -q "$INSTALL_PATH" "$CRON_FILE"; then
        log "[OK] 定时任务已安装: $CRON_FILE"
        log "自动检查时间: 每天 ${CHECK_HOUR}:${CHECK_MINUTE}"
        if [ "$DAILY_RESTART" = "1" ]; then
            log "Trojan 自动重启时间: 每天 ${RESTART_HOUR}:${RESTART_MINUTE}（每 24 小时一次）"
        fi
    else
        die "cron install failed: $CRON_FILE"
    fi
}

choose_install_action() {
    local choice

    case "$INSTALL_ACTION" in
        automatic|immediate|domain|status)
            return 0
            ;;
        ask)
            ;;
        *)
            log "[WARN] 未识别的 INSTALL_ACTION=$INSTALL_ACTION，改用自动模式"
            INSTALL_ACTION="automatic"
            return 0
            ;;
    esac

    if [ ! -t 1 ] || [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        INSTALL_ACTION="automatic"
        log "没有交互终端，默认使用自动模式"
        return 0
    fi

    printf '\n请选择本次证书处理方式：\n' > /dev/tty
    printf '  1) 自动模式（推荐）：自动识别域名，仅在证书缺失或不足 %s 天时申请\n' "$RENEW_DAYS" > /dev/tty
    printf '  2) 手动立即申请：自动识别域名并马上申请、安装\n' > /dev/tty
    printf '  3) 手动指定域名：输入域名并马上申请、安装\n' > /dev/tty
    printf '  4) 只查看域名、证书和到期时间\n' > /dev/tty
    printf '请选择 [1-4，默认 1]: ' > /dev/tty
    IFS= read -r choice < /dev/tty || choice="1"

    case "${choice:-1}" in
        1) INSTALL_ACTION="automatic" ;;
        2) INSTALL_ACTION="immediate" ;;
        3) INSTALL_ACTION="domain" ;;
        4) INSTALL_ACTION="status" ;;
        *)
            log "[WARN] 选择无效，默认使用自动模式"
            INSTALL_ACTION="automatic"
            ;;
    esac

    if [ "$INSTALL_ACTION" = "domain" ] && [ -z "$MANUAL_DOMAIN" ]; then
        printf '请输入要申请证书的域名: ' > /dev/tty
        IFS= read -r MANUAL_DOMAIN < /dev/tty || MANUAL_DOMAIN=""
    fi
}

run_install_action() {
    case "$INSTALL_ACTION" in
        automatic)
            log "[OK] 已选择自动模式：开始识别域名并检查证书到期时间"
            "$INSTALL_PATH" --scheduled
            ;;
        immediate)
            log "已选择手动立即申请：开始自动识别域名"
            "$INSTALL_PATH" --force
            ;;
        domain)
            if [ -z "$MANUAL_DOMAIN" ]; then
                log "[WARN] 未输入域名，改为自动识别并立即申请"
                "$INSTALL_PATH" --force
            else
                log "已选择手动指定域名: $MANUAL_DOMAIN"
                DOMAIN="$MANUAL_DOMAIN" "$INSTALL_PATH" --force
            fi
            ;;
        status)
            log "已选择只查看状态"
            "$INSTALL_PATH" --status
            ;;
    esac
}

main() {
    case "${1:-}" in
        --help|-h)
            usage
            exit 0
            ;;
    esac

    need_root
    install_packages
    install_script
    install_cron
    print_install_result

    if [ "$RUN_CHECK" = "1" ]; then
        choose_install_action
        if ! run_install_action; then
            log "[WARN] 安装和定时任务已完成，但本次证书操作没有成功"
            log "可检查日志后重试: ${INSTALL_PATH}"
        fi
    fi

    log "完成。手动状态检查: ${INSTALL_PATH} --status"
    log "手动立即申请并安装: ${INSTALL_PATH}"
    log "定时到期检查模式: ${INSTALL_PATH} --scheduled"
    log "手动重启 Trojan: ${INSTALL_PATH} --restart"
}

main "$@"
