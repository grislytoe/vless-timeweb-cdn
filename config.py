#!/usr/bin/env python3
"""Pure configuration builders. No remote code, shell interpolation or private-key output."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import tempfile
from urllib.parse import quote, urlencode
import uuid

VERSION = "26.11.9"  # Pinned official Xray core, not the kit version.
# Safe documentation values only. Installation always requires explicit parameters.
DEFAULTS = dict(domain="vpn.example.com", inbound_ip="192.0.2.10",
                outbound_ip="192.0.2.10", port=443, fallback_port=26869,
                cdn_domain="cdn.example.com", deployment="timeweb-cdn")


def validate(settings):
    if settings.get("deployment") != "timeweb-cdn":
        raise ValueError("This installer only manages Timeweb CDN deployments; no automatic REALITY migration.")
    domain = settings["domain"]
    if len(domain) > 253 or not re.fullmatch(
        r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
        r"[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?", domain
    ):
        raise ValueError("Use a lower-case ASCII DNS name (punycode if needed).")
    for name in ("inbound_ip", "outbound_ip"):
        ipaddress.IPv4Address(settings[name])
    cdn = settings.get("cdn_domain", "")
    if len(cdn) > 253 or not re.fullmatch(
        r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
        r"[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?", cdn
    ) or cdn == domain:
        raise ValueError("Use a separate lower-case ASCII CDN DNS name.")
    for key in ("port", "fallback_port"):
        if type(settings[key]) is not int or not 1024 <= settings[key] <= 65535:
            if key != "port" or settings[key] != 443:
                raise ValueError("Invalid port.")
    if settings["port"] in (22, 80) or settings["fallback_port"] in (22, 80, settings["port"]):
        raise ValueError("SSH, HTTP, public and fallback ports must not conflict.")
    if settings.get("fingerprint", "firefox") not in ("chrome", "firefox"):
        raise ValueError("Unsupported fingerprint.")
    if "panel_path" in settings and not re.fullmatch(r"/manage-[0-9a-f]{32}", settings["panel_path"]):
        raise ValueError("Invalid panel path.")
    return settings


def validate_credentials(value):
    uuid.UUID(value["uuid"])
    if not re.fullmatch(r"/[A-Za-z0-9/_-]{1,160}", value["path"]):
        raise ValueError("Invalid XHTTP path.")
    return value


def new_credentials(xray):
    # The argument is retained for the shared administrative/test API. TLS needs no REALITY keys.
    return validate_credentials(dict(uuid=str(uuid.uuid4()),
        path="/api/v2/session/" + secrets.token_hex(16)))


def timeweb_extra():
    """Timeweb preset adapted from web-panel-proxy/wpp_cdn.py (MIT)."""
    return {
        "mode": "packet-up", "uplinkHTTPMethod": "GET", "uplinkDataPlacement": "body",
        "sessionIDPlacement": "query", "sessionIDKey": "session",
        "seqPlacement": "query", "seqKey": "part",
        "scMaxEachPostBytes": "400000-800000", "scMaxBufferedPosts": 48,
        "scMinPostsIntervalMs": "50-100", "xPaddingBytes": "550-1450",
        "xPaddingObfsMode": True, "xPaddingHeader": "X-Request-ID",
        "xPaddingPlacement": "header", "xPaddingMethod": "tokenish",
        "xmux": {"maxConcurrency": "4-8", "maxConnections": 0, "cMaxReuseTimes": 0,
                 "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000",
                 "hKeepAlivePeriod": 0}, "enableXmux": True,
    }


def server_config(settings, credentials, clients=None, stats_address='/run/xray-cdn-stats/api.sock'):
    s, c = validate(settings), validate_credentials(credentials)
    ids = [c["uuid"]] if clients is None else [str(uuid.UUID(v["id"])) for v in clients if v["active"]]
    return {
        "stats": {},
        "api": {"tag": "stats-api", "listen": stats_address, "services": ["StatsService"]},
        "policy": {"levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True, "statsUserOnline": True}}},
        "log": {"access": "none", "loglevel": "warning"},
        "inbounds": [{"tag": "vless-xhttp", "listen": "127.0.0.1",
            "port": s["fallback_port"], "protocol": "vless",
            "settings": {"clients": [{"id": value, "email": value} for value in ids], "decryption": "none"},
            "streamSettings": {"network": "xhttp", "security": "none",
                "xhttpSettings": {"path": c["path"], **timeweb_extra()}},
            "sniffing": {"enabled": False}}],
        "outbounds": [{"tag": "direct", "protocol": "freedom",
            "sendThrough": s["outbound_ip"],
            "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4"}}}],
    }


def client_config(settings, credentials, socks_port=10808, address=None, origin=False):
    s, c = validate(settings), validate_credentials(credentials)
    return {"log": {"access": "none", "loglevel": "warning"},
        "inbounds": [{"listen": "127.0.0.1", "port": socks_port,
            "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}],
        "outbounds": [{"protocol": "vless", "settings": {"vnext": [{
            "address": address or (s["domain"] if origin else s["cdn_domain"]), "port": s["port"],
            "users": [{"id": c["uuid"], "encryption": "none"}]}]},
            "streamSettings": {"network": "xhttp", "security": "tls",
                "tlsSettings": {"serverName": s["domain"] if origin else s["cdn_domain"],
                    "fingerprint": s.get("fingerprint", "firefox"), "alpn": ["h2"]},
                "xhttpSettings": {"path": c["path"] + "/index.json",
                    "host": s["domain"] if origin else s["cdn_domain"],
                    "extra": timeweb_extra(), "mode": "packet-up"}}}]}


def client_url(settings, credentials, name="Timeweb-CDN"):
    s, c = validate(settings), validate_credentials(credentials)
    params = {"encryption": "none", "security": "tls", "sni": s["cdn_domain"],
        "fp": s.get("fingerprint", "firefox"), "type": "xhttp", "host": s["cdn_domain"],
        "path": c["path"] + "/index.json", "mode": "packet-up", "alpn": "h2",
        "extra": json.dumps(timeweb_extra(), separators=(",", ":"))}
    return f"vless://{c['uuid']}@{s['cdn_domain']}:{s['port']}?{urlencode(params)}#{quote(name, safe='')}"


def nginx_config(settings, tls=False, credentials=None):
    s = validate(settings)
    domain, inbound, fallback = s["domain"], s["inbound_ip"], s["fallback_port"]
    text = f"""# Managed by vless-timeweb-cdn. HTTP-01 renewal never takes over port 443.
server {{
    listen {inbound}:80 default_server;
    server_name _;
    return 404;
}}
server {{
    listen {inbound}:80;
    server_name {domain};
    root /var/www/vless-cover;
    location ^~ /.well-known/acme-challenge/ {{ try_files $uri =404; }}
    location / {{ try_files $uri $uri/ =404; }}
}}
"""
    if tls:
        c = validate_credentials(credentials)
        panel = ""
        if s.get("panel_path"):
            p = s["panel_path"]
            panel = f"""
    location = {p} {{ access_log off; return 302 {p}/; }}
    location ^~ {p}/ {{
        access_log off;
        client_max_body_size 8k;
        limit_req zone=vless_panel burst=20 nodelay;
        proxy_pass http://unix:/run/vless-cdn-panel/http.sock;
        proxy_set_header Host {domain};
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For "";
        proxy_set_header X-Forwarded-SSL "";
        proxy_set_header X-Forwarded-Protocol "";
        proxy_set_header Forwarded "";
        proxy_http_version 1.0;
        proxy_request_buffering on;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
    }}
"""
            text = "limit_req_zone $binary_remote_addr zone=vless_panel:10m rate=2r/s;\n" + text
        text += f"""server {{
    listen {inbound}:{s["port"]} ssl http2 default_server;
    server_name _;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_reject_handshake on;
}}
server {{
    listen {inbound}:{s["port"]} ssl http2;
    server_name {domain};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate /etc/letsencrypt/live/{domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;
    ssl_session_cache shared:VLESS:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    root /var/www/vless-cover;
    index index.html;
    {panel}
    location ^~ {c['path']}/ {{
        # CDN forwards ordinary HTTP requests, never REALITY handshakes.
        access_log off;
        client_max_body_size 2m;
        proxy_pass http://127.0.0.1:{fallback};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        add_header Cache-Control "no-store, no-cache" always;
        add_header CDN-Cache-Control "no-store" always;
        add_header X-Accel-Buffering "no" always;
    }}
    location / {{ try_files $uri $uri/ =404; }}
}}
"""
    return text


def write(path, value, private=True):
    path = Path(path)
    data = json.dumps(value, indent=2) + "\n" if not isinstance(value, str) else value
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        if os.name != "nt":
            os.chmod(temporary, 0o600 if private else 0o644)
        os.replace(temporary, path)
        if os.name == 'posix':
            directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["settings", "credentials", "render", "http"])
    parser.add_argument("--settings", required=True)
    parser.add_argument("--credentials")
    parser.add_argument("--output")
    parser.add_argument("--xray")
    parser.add_argument("--domain")
    parser.add_argument("--inbound")
    parser.add_argument("--outbound")
    parser.add_argument("--cdn-domain")
    args = parser.parse_args()
    if args.command == "settings":
        if not all((args.domain, args.inbound, args.cdn_domain)):
            parser.error("settings requires --domain, --inbound and --cdn-domain")
        write(args.settings, validate(dict(DEFAULTS, domain=args.domain, inbound_ip=args.inbound,
              outbound_ip=args.outbound or args.inbound, cdn_domain=args.cdn_domain, fingerprint="firefox", panel_path="/manage-" + secrets.token_hex(16))))
        return
    s = validate(json.loads(Path(args.settings).read_text(encoding="utf-8")))
    if args.command == "http":
        write(args.output, nginx_config(s))
        return
    path = Path(args.credentials)
    if args.command == "credentials":
        if path.exists():
            validate_credentials(json.loads(path.read_text(encoding="utf-8")))
        else:
            write(path, new_credentials(args.xray))
        return
    c = validate_credentials(json.loads(path.read_text(encoding="utf-8")))
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    clients_path = Path(args.settings).with_name("clients.json")
    clients = json.loads(clients_path.read_text(encoding="utf-8")) if clients_path.exists() else None
    write(out / "config.json", server_config(s, c, clients))
    write(out / "client.json", client_config(s, c))
    write(out / "client.txt", client_url(s, c) + "\n")
    write(out / "nginx.conf", nginx_config(s, tls=True, credentials=c))


if __name__ == "__main__":
    main()
