#!/usr/bin/env bash
# Dedicated Ubuntu/Debian VPS only. Run --check first. No remote shell scripts.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME
umask 077
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE=/var/lib/vless-timeweb-cdn
CONFIG=/usr/local/etc/xray/config.json
BIN=/usr/local/bin/xray
UNIT=/etc/systemd/system/xray.service
SITE=/etc/nginx/conf.d/vless-timeweb-cdn.conf
DOMAIN=""
INBOUND=""
OUTBOUND=""
CDN_DOMAIN=""
PORT=443
FALLBACK=26869
XRAY_VERSION=26.11.9
ACTION=check
UPDATE=false
XRAY_ARCHIVE=""
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for arg in "$@"; do
    case "$arg" in
        --check) ACTION=check ;;
        --install) ACTION=install ;;
        --update) ACTION=install; UPDATE=true ;;
        --archive=*) XRAY_ARCHIVE=${arg#--archive=} ;;
        --domain=*) DOMAIN=${arg#--domain=} ;;
        --inbound=*) INBOUND=${arg#--inbound=} ;;
        --outbound=*) OUTBOUND=${arg#--outbound=} ;;
        --cdn-domain=*) CDN_DOMAIN=${arg#--cdn-domain=} ;;
        --help|-h) printf 'Usage: sudo bash install.sh --check | --install [--domain=vpn.example.com --inbound=IP --cdn-domain=cdn.example.com [--outbound=IP]] [--archive=/path/Xray-linux-64.zip]\nUpdate managed VPN: sudo bash install.sh --update\n'; exit 0 ;;
        *) die "Unknown option: $arg" ;;
    esac
done
for file in config.py preflight.py probe.py panel.py panel_setup.py admin.py; do
    [[ -f "$BASE/$file" ]] || die "Missing bundle file: $file"
done
[[ $EUID -eq 0 ]] || die 'Run --check/--install with sudo.'
for cmd in python3 ip ss systemctl; do command -v "$cmd" >/dev/null || die "Missing $cmd"; done
[[ -d /run/systemd/system ]] || die 'A Linux host with systemd is required.'
# shellcheck source=inputs.sh
source "$BASE/inputs.sh"
if [[ "$UPDATE" == true ]]; then
    [[ -z "$DOMAIN$INBOUND$OUTBOUND$CDN_DOMAIN" ]] || die 'Update uses saved settings; omit domain/IP overrides.'
    SAVED=$(python3 "$BASE/update_guard.py" parameters) || die 'Managed state incomplete; refusing to generate replacement credentials.'
    mapfile -t VALUES <<< "$SAVED"
    [[ ${#VALUES[@]} -eq 4 ]] || die 'Invalid saved network settings.'
    DOMAIN=${VALUES[0]}; INBOUND=${VALUES[1]}; OUTBOUND=${VALUES[2]}; CDN_DOMAIN=${VALUES[3]}
fi
collect_inputs
# shellcheck source=/dev/null
source /etc/os-release
case "${ID}:${VERSION_ID}" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
    *) die "Supported: Ubuntu 22.04/24.04, Debian 12/13; found $ID $VERSION_ID" ;;
esac
case "$(uname -m)" in
    x86_64) ARCH=64; SHA=b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82 ;;
    aarch64|arm64) ARCH=arm64-v8a; SHA=64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be ;;
    *) die 'Supported CPU architectures: x86_64 and ARM64.' ;;
esac
python3 "$BASE/preflight.py" --domain "$DOMAIN" --inbound "$INBOUND" --outbound "$OUTBOUND" --cdn-domain "$CDN_DOMAIN"
MANAGED=false
if [[ -f "$STATE/settings.json" ]]; then
    python3 - "$STATE/settings.json" "$DOMAIN" "$INBOUND" "$OUTBOUND" "$CDN_DOMAIN" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
if s.get('deployment') != 'timeweb-cdn':
    raise SystemExit('Existing installation is not Timeweb CDN; use a clean VPS.')
if [s['domain'], s['inbound_ip'], s['outbound_ip'], s['cdn_domain']] != sys.argv[2:]:
    raise SystemExit('Saved settings differ. An explicit migration is required.')
PY
    MANAGED=true
else
    for account in xray vless-cdn-panel; do
        if getent passwd "$account" >/dev/null; then die "Reserved account $account already exists; inspect before first installation."; fi
    done
    if getent group vless-cdn-admin >/dev/null; then die 'Reserved vless-cdn-admin group already exists; inspect its members.'; fi
    [[ ! -e /etc/nginx/nginx.conf && ! -e "$CONFIG" && ! -e "$UNIT" && ! -e "$BIN" ]] \
        || die 'Existing Nginx/Xray found. Inspect and migrate manually; this installer is for a clean VPS.'
    if systemctl cat xray.service >/dev/null 2>&1; then die 'Existing Xray service found.'; fi
    [[ ! -e /opt/nginx-selfsteal ]] || die 'Existing Selfsteal found; do not mix installers.'
    [[ ! -e /opt/vless-timeweb-cdn && ! -e /etc/vless-cdn-panel && ! -e /etc/systemd/system/vless-cdn-panel.service ]] \
        || die 'Existing panel files found without a managed server marker; inspect first.'
    for port in 80 "$PORT" "$FALLBACK"; do
        [[ -z "$(ss -ltnH "sport = :$port")" ]] || die "TCP port $port is already in use."
    done
fi
printf 'Preflight passed. Incoming: %s:%s; outgoing source: %s; XHTTP backend: loopback:%s\n' "$INBOUND" "$PORT" "$OUTBOUND" "$FALLBACK"
if command -v ufw >/dev/null; then ufw status || true; fi
printf 'Required external access: TCP 80 (HTTP-01), TCP 443 (VPN); keep your current SSH port.\n'
printf 'No MTU, firewall, TCP buffers or global queue changes by default.\n'
ss -ltnp "( sport = :80 or sport = :443 or sport = :26869 )"
tc qdisc show || true
sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control
[[ "$ACTION" == install ]] || exit 0
[[ $EUID -eq 0 ]] || die 'Run --install with sudo.'
command -v flock >/dev/null || die 'Install util-linux (flock) first.'
install -d -m 700 -o root -g root /run/vless-timeweb-cdn-lock
exec 9>/run/vless-timeweb-cdn-lock/install.lock
flock -n 9 || die 'Another installation is running.'
if [[ -f "$STATE/pending.json" ]]; then python3 "$BASE/admin.py" recover; fi
install -d -m 700 -o root -g root "$STATE" "$STATE/backups"
# The ownership/settings marker survives an interrupted first install to permit retries.
if [[ ! -f "$STATE/settings.json" ]]; then
    python3 "$BASE/config.py" settings --settings "$STATE/settings.json" \
        --domain "$DOMAIN" --inbound "$INBOUND" --outbound "$OUTBOUND" --cdn-domain "$CDN_DOMAIN"
fi
WORK=$(mktemp -d "$STATE/work.XXXXXXXX")
BACKUP=$(mktemp -d "$STATE/backups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
declare -a RECORDED=()
snapshot() {
    local target=$1
    RECORDED+=("$target")
    if [[ -e "$target" || -L "$target" ]]; then
        mkdir -p "$BACKUP$(dirname "$target")"
        cp -a -- "$target" "$BACKUP$target"
    fi
}
XRAY_ACTIVE=false; NGINX_ACTIVE=false
ADMIN_ACTIVE=false; PANEL_ACTIVE=false
systemctl is-active --quiet vless-cdn-admin && ADMIN_ACTIVE=true
systemctl is-active --quiet vless-cdn-panel && PANEL_ACTIVE=true
systemctl is-active --quiet xray && XRAY_ACTIVE=true
systemctl is-active --quiet nginx && NGINX_ACTIVE=true
SUCCESS=false
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "$SUCCESS" != true ]]; then
        printf 'Installation failed; restoring managed files. Backup: %s\n' "$BACKUP" >&2
        systemctl stop xray >/dev/null 2>&1 || true
        systemctl stop vless-cdn-panel vless-cdn-admin >/dev/null 2>&1 || true
        if [[ "$PANEL_ACTIVE" != true ]]; then systemctl disable vless-cdn-panel >/dev/null 2>&1 || true; fi
        if [[ "$ADMIN_ACTIVE" != true ]]; then systemctl disable vless-cdn-admin >/dev/null 2>&1 || true; fi
        if [[ "$MANAGED" != true ]]; then systemctl disable xray >/dev/null 2>&1 || true; fi
        for target in "${RECORDED[@]}"; do
            if [[ -e "$BACKUP$target" || -L "$BACKUP$target" ]]; then
                rm -f -- "$target"
                cp -a -- "$BACKUP$target" "$target"
            else
                rm -f -- "$target"
            fi
        done
        systemctl daemon-reload || true
        if [[ "$NGINX_ACTIVE" == true ]]; then
            systemctl restart nginx || true
        elif systemctl cat nginx.service >/dev/null 2>&1; then
            systemctl stop nginx || true
        fi
        if [[ "$XRAY_ACTIVE" == true ]]; then systemctl restart xray || true; fi
        if [[ "$ADMIN_ACTIVE" == true ]]; then systemctl restart vless-cdn-admin || true; fi
        if [[ "$PANEL_ACTIVE" == true ]]; then systemctl restart vless-cdn-panel || true; fi
        printf 'Installed packages/certificates and persistent credentials are retained for retry.\n' >&2
    fi
    # WORK is a freshly created directory below the fixed STATE path.
    [[ "$WORK" == "$STATE"/work.* ]] && rm -rf -- "$WORK"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Also stop old releases using the legacy lock before taking snapshots.
systemctl stop vless-cdn-panel vless-cdn-admin >/dev/null 2>&1 || true
if [[ -f "$STATE/clients.json" ]]; then python3 "$BASE/admin.py" collect; fi
if [[ -f "$STATE/pending.json" ]]; then python3 "$BASE/admin.py" recover; fi
if [[ "$UPDATE" == true ]]; then
    python3 "$BASE/update_guard.py" capture --snapshot "$WORK/update-guard.json"
fi
for target in "$CONFIG" "$BIN" "$UNIT" "$SITE" \
    /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf /var/www/vless-cover/index.html \
    /etc/apt/sources.list.d/vless-nginx.list /etc/apt/preferences.d/vless-nginx \
    /usr/share/keyrings/vless-nginx.gpg \
    /etc/letsencrypt/renewal-hooks/deploy/vless-nginx \
    "$STATE/client.txt" "$STATE/client.json" "$STATE/client-qr.png" \
    "$STATE/settings.json" "$STATE/clients.json" "$STATE/credentials.json" "$STATE/kit-version" "$STATE/traffic.sqlite3" /etc/vless-cdn-panel/admin.json \
    /var/lib/vless-cdn-panel/security.sqlite3 \
    /etc/systemd/system/vless-cdn-admin.service /etc/systemd/system/vless-cdn-panel.service; do snapshot "$target"; done
# Local mutations remain stopped throughout the upgrade.
for file in config.py admin.py panel.py panel_setup.py security_state.py traffic_stats.py; do snapshot "/opt/vless-timeweb-cdn/$file"; done
for file in "$BASE"/templates/*.html "$BASE"/static/*; do snapshot "/opt/vless-timeweb-cdn/${file#"$BASE/"}"; done
python3 - "$STATE/settings.json" <<'PY'
import json, secrets, sys
from pathlib import Path
p = Path(sys.argv[1])
s = json.loads(p.read_text())
# Preserve an old client's fingerprint; only new installations default to Chrome.
s.setdefault('fingerprint', 'firefox')
s.setdefault('panel_path', '/manage-' + secrets.token_hex(16))
p.write_text(json.dumps(s, indent=2) + '\n')
PY
getent group vless-cdn-admin >/dev/null || groupadd --system vless-cdn-admin
if ! id vless-cdn-panel >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --shell /usr/sbin/nologin vless-cdn-panel
fi
install -d -m 750 -o root -g vless-cdn-admin /etc/vless-cdn-panel
python3 "$BASE/panel_setup.py"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl unzip python3 python3-venv certbot openssl qrencode python3-flask python3-werkzeug python3-jinja2 python3-itsdangerous python3-markupsafe python3-qrcode python3-pil
bash "$BASE/runtime.sh"
if [[ "$ID:$VERSION_ID" == ubuntu:22.04 ]]; then
    # Jammy's stock 1.18 lacks ssl_reject_handshake. Use the official signed
    # stable repository, scoped to this repository's signing key.
    apt-get install -y gnupg ubuntu-keyring
    curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 15 --max-time 60 \
        https://nginx.org/keys/nginx_signing.key -o "$WORK/nginx_signing.key"
    printf '%s  %s\n' 55385da31d198fa6a5012d40ae98ecb272a6c4e8fffffba94719ffd3e87de37a "$WORK/nginx_signing.key" | sha256sum -c -
    gpg --batch --dearmor --output "$WORK/nginx.gpg" "$WORK/nginx_signing.key"
    install -m 644 "$WORK/nginx.gpg" /usr/share/keyrings/vless-nginx.gpg
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/vless-nginx.gpg] https://nginx.org/packages/ubuntu jammy nginx' \
        > /etc/apt/sources.list.d/vless-nginx.list
    printf 'Package: nginx*\nPin: origin nginx.org\nPin-Priority: 900\n' > /etc/apt/preferences.d/vless-nginx
    chmod 644 /etc/apt/sources.list.d/vless-nginx.list /etc/apt/preferences.d/vless-nginx
    apt-get update
fi
apt-get install -y nginx
if [[ -n "$XRAY_ARCHIVE" ]]; then
    [[ -f "$XRAY_ARCHIVE" ]] || die "Archive not found: $XRAY_ARCHIVE"
    cp -- "$XRAY_ARCHIVE" "$WORK/xray.zip"
else
    curl --proto '=https' --tlsv1.2 -fSL --connect-timeout 15 --max-time 300 --retry 3 \
        "https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/Xray-linux-$ARCH.zip" -o "$WORK/xray.zip"
fi
printf '%s  %s\n' "$SHA" "$WORK/xray.zip" | sha256sum -c -
unzip -p "$WORK/xray.zip" xray > "$WORK/xray"
chmod 755 "$WORK/xray"
"$WORK/xray" version
python3 "$BASE/config.py" credentials --settings "$STATE/settings.json" \
    --credentials "$STATE/credentials.json" --xray "$WORK/xray"
python3 "$BASE/admin.py" init
python3 "$BASE/config.py" render --settings "$STATE/settings.json" \
    --credentials "$STATE/credentials.json" --output "$WORK/render"
"$WORK/xray" run -test -config "$WORK/render/config.json"
install -d -m 755 /var/www/vless-cover/.well-known/acme-challenge
install -d -m 755 /etc/nginx/conf.d
if [[ ! -f /var/www/vless-cover/index.html ]]; then
    printf '<!doctype html><html lang="en"><meta charset="utf-8"><title>%s</title><h1>Welcome</h1><p>Personal website.</p></html>\n' "$DOMAIN" \
        > /var/www/vless-cover/index.html
fi
chmod 644 /var/www/vless-cover/index.html
if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    python3 "$BASE/config.py" http --settings "$STATE/settings.json" --output "$WORK/http.conf"
    install -m 644 "$WORK/http.conf" "$SITE"
else
    install -m 644 "$WORK/render/nginx.conf" "$SITE"
fi
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/conf.d/default.conf
nginx -t
systemctl enable --now nginx
systemctl reload nginx
# No email invented on the user's behalf; a contact can be registered later.
certbot certonly --webroot --webroot-path /var/www/vless-cover \
    --cert-name "$DOMAIN" -d "$DOMAIN" --non-interactive --agree-tos \
    --register-unsafely-without-email --keep-until-expiring --key-type ecdsa
install -m 644 "$WORK/render/nginx.conf" "$SITE"
nginx -t
systemctl reload nginx
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/vless-nginx <<'HOOK'
#!/bin/sh
set -eu
/usr/sbin/nginx -t
/bin/systemctl reload nginx
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/vless-nginx
systemctl enable --now certbot.timer
# Validate the public origin certificate and H2 before changing Xray.
python3 "$BASE/tls_check.py" --domain "$DOMAIN" --address "$INBOUND" --port "$PORT"
if ! id xray >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --shell /usr/sbin/nologin xray
fi
install -d -m 750 -o root -g xray /usr/local/etc/xray
# Stage validation has passed. Atomic replacements stay on the target filesystem.
install -m 755 "$WORK/xray" /usr/local/bin/xray.vless-new
mv -f /usr/local/bin/xray.vless-new "$BIN"
install -m 640 -o root -g xray "$WORK/render/config.json" "$CONFIG.vless-new"
mv -f "$CONFIG.vless-new" "$CONFIG"
cat > "$WORK/xray.service" <<'UNIT'
[Unit]
Description=VLESS XHTTP Timeweb CDN
Wants=network-online.target nginx.service
After=network-online.target nginx.service
StartLimitIntervalSec=60
StartLimitBurst=10
[Service]
User=xray
Group=xray
RuntimeDirectory=xray-cdn-stats
RuntimeDirectoryMode=0750
UMask=0007
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
[Install]
WantedBy=multi-user.target
UNIT
install -m 644 "$WORK/xray.service" "$UNIT"
systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || die 'Xray is not active; inspect journalctl -u xray.'
[[ -n "$(ss -ltnH "src $INBOUND sport = :$PORT")" ]] || die 'Public listener not found.'
# Exercise the real origin. CDN is created after origin installation; test it separately.
python3 "$BASE/probe.py" --xray "$BIN" --settings "$STATE/settings.json" \
    --credentials "$STATE/credentials.json" --origin
# Do not recreate a revoked initial export during an upgrade.
if python3 - "$STATE" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
initial = json.loads((p / 'credentials.json').read_text())['uuid']
raise SystemExit(0 if any(c['id'] == initial and c['active'] for c in json.loads((p / 'clients.json').read_text())) else 1)
PY
then
    install -m 600 "$WORK/render/client.txt" "$STATE/client.txt"
    install -m 600 "$WORK/render/client.json" "$STATE/client.json"
    qrencode -o "$STATE/client-qr.png" -s 8 -r "$STATE/client.txt"
    chmod 600 "$STATE/client-qr.png"
fi
install -d -m 755 /opt/vless-timeweb-cdn /opt/vless-timeweb-cdn/templates /opt/vless-timeweb-cdn/static
for file in config.py admin.py panel.py panel_setup.py security_state.py traffic_stats.py; do install -m 644 "$BASE/$file" "/opt/vless-timeweb-cdn/$file"; done
install -m 644 "$BASE"/templates/*.html /opt/vless-timeweb-cdn/templates/
install -m 644 "$BASE"/static/* /opt/vless-timeweb-cdn/static/
install -m 644 "$BASE"/services/*.service /etc/systemd/system/
# nginx.org packages use nginx; Debian/Ubuntu packages usually use www-data.
NGINX_USER=$(awk '/^[[:space:]]*user[[:space:]]/ {gsub(/;/, "", $2); print $2; exit}' /etc/nginx/nginx.conf)
[[ "$NGINX_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die 'Cannot determine Nginx worker user.'
NGINX_GROUP=$(id -gn "$NGINX_USER")
[[ "$NGINX_GROUP" =~ ^[a-z_][a-z0-9_-]*$ ]] || die 'Invalid Nginx worker group.'
sed "s/^Group=www-data$/Group=$NGINX_GROUP/" "$BASE/services/vless-cdn-panel.service" > /etc/systemd/system/vless-cdn-panel.service
systemctl daemon-reload
systemctl enable vless-cdn-admin vless-cdn-panel
systemctl restart vless-cdn-admin vless-cdn-panel
sleep 2
systemctl is-active --quiet vless-cdn-admin || die 'Local key manager failed.'
systemctl is-active --quiet vless-cdn-panel || die 'Panel failed.'
PANEL_PATH=$(python3 -c 'import json; print(json.load(open("/var/lib/vless-timeweb-cdn/settings.json"))["panel_path"])')
curl -fsS --connect-timeout 10 --max-time 20 --resolve "$DOMAIN:443:$INBOUND" \
    "https://$DOMAIN$PANEL_PATH/login" -o "$WORK/panel-check.html"
certbot renew --dry-run --no-random-sleep-on-renew
if [[ "$UPDATE" == true ]]; then
    python3 "$BASE/update_guard.py" verify --snapshot "$WORK/update-guard.json"
fi
install -m 600 "$BASE/VERSION" "$STATE/kit-version"
SUCCESS=true
printf 'Installed. Backup: %s\nHapp link: sudo cat %s/client.txt\nQR: %s/client-qr.png\n' "$BACKUP" "$STATE" "$STATE"
printf 'Next: configure Timeweb CDN as described in README.md, run the CDN probe, then import into Happ.\n'
printf 'Panel: \033[1;32mhttps://%s%s/\033[0m (use the login/password entered during installation)\n' "$DOMAIN" "$PANEL_PATH"
