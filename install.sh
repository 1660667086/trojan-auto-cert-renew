#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export LANG=C

PREFIX="${PREFIX:-/usr/local}"
INSTALL_PATH="${INSTALL_PATH:-${PREFIX}/sbin/trojan-auto-cert-renew}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/trojan-auto-cert-renew}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/1660667086/trojan-auto-cert-renew/main}"
RENEW_DAYS="${RENEW_DAYS:-7}"
CHECK_MINUTE="${CHECK_MINUTE:-17}"
CHECK_HOUR="${CHECK_HOUR:-4}"
RUN_CHECK="${RUN_CHECK:-1}"
DISABLE_ACME_CRON="${DISABLE_ACME_CRON:-1}"
SERVICE_STOP_LIST="${SERVICE_STOP_LIST:-trojan trojan-go nginx caddy apache2 httpd cloudreve}"
CONFIG_PATH="${CONFIG_PATH:-}"
DOMAIN="${DOMAIN:-}"
TROJAN_CLI="${TROJAN_CLI:-}"
CERT_CHOICE="${CERT_CHOICE:-1}"
DISPLAY_TZ="${DISPLAY_TZ:-Asia/Shanghai}"

usage() {
    cat <<'USAGE'
Usage:
  bash install.sh
  curl -fsSL https://raw.githubusercontent.com/1660667086/trojan-auto-cert-renew/main/install.sh | bash

Environment variables:
  RENEW_DAYS=7
  CHECK_HOUR=4
  CHECK_MINUTE=17
  RUN_CHECK=1
  DISABLE_ACME_CRON=1
  SERVICE_STOP_LIST="trojan trojan-go nginx caddy apache2 httpd cloudreve"
  CONFIG_PATH=/usr/local/etc/trojan/config.json
  DOMAIN=www.example.com
  TROJAN_CLI=/usr/local/bin/trojan
  CERT_CHOICE=1
  DISPLAY_TZ=Asia/Shanghai
  RAW_BASE=https://raw.githubusercontent.com/1660667086/trojan-auto-cert-renew/main
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
        apt-get update
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
    local cmd
    cmd="RENEW_DAYS=$(shell_quote "$RENEW_DAYS")"
    cmd="${cmd} DISABLE_ACME_CRON=$(shell_quote "$DISABLE_ACME_CRON")"
    cmd="${cmd} SERVICE_STOP_LIST=$(shell_quote "$SERVICE_STOP_LIST")"
    cmd="${cmd} CERT_CHOICE=$(shell_quote "$CERT_CHOICE")"
    cmd="${cmd} DISPLAY_TZ=$(shell_quote "$DISPLAY_TZ")"
    [ -n "$CONFIG_PATH" ] && cmd="${cmd} CONFIG_PATH=$(shell_quote "$CONFIG_PATH")"
    [ -n "$DOMAIN" ] && cmd="${cmd} DOMAIN=$(shell_quote "$DOMAIN")"
    [ -n "$TROJAN_CLI" ] && cmd="${cmd} TROJAN_CLI=$(shell_quote "$TROJAN_CLI")"
    cmd="${cmd} ${INSTALL_PATH} >/dev/null 2>&1"

    cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${CHECK_MINUTE} ${CHECK_HOUR} * * * root ${cmd}
EOF
    chmod 644 "$CRON_FILE"
    log "Installed cron: $CRON_FILE"
}

print_install_result() {
    log "[OK] 安装成功: $INSTALL_PATH"

    if [ -f "$CRON_FILE" ] && grep -q "$INSTALL_PATH" "$CRON_FILE"; then
        log "[OK] 定时任务已安装: $CRON_FILE"
        log "自动检查时间: 每天 ${CHECK_HOUR}:${CHECK_MINUTE}"
    else
        die "cron install failed: $CRON_FILE"
    fi
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
        log "正在检查证书状态..."
        if "$INSTALL_PATH" --status; then
            log "[OK] 证书检测成功"
        else
            log "[WARN] 安装已完成，但当前没有检测到有效证书"
            log "需要立即申请/测试时运行: ${INSTALL_PATH} --force"
        fi
    fi

    log "完成。手动状态检查: ${INSTALL_PATH} --status"
    log "手动强制续签: ${INSTALL_PATH} --force"
}

main "$@"
