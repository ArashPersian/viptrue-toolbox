#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

start = text.index("generate_proxy_config_from_active_link() {")
end = text.index("\nwrite_proxy_systemd_service() {", start)

new_func = r'''generate_proxy_config_from_active_link() {
  ensure_dirs

  if [[ ! -f "$ACTIVE_LINK_FILE" ]]; then
    echo -e "${RED}No active config link found.${NC}"
    return 1
  fi

  local link_type link
  link_type="$(get_active_link_type || true)"
  link="$(get_active_link_value || true)"

  if [[ "$link_type" != "shadowsocks" && "$link_type" != "vless" && "$link_type" != "trojan" && "$link_type" != "vmess" ]]; then
    echo -e "${RED}Proxy Mode currently supports ss://, vless://, trojan:// and vmess:// links.${NC}"
    echo "Active type: ${link_type:-UNKNOWN}"
    echo
    echo "Next step: Subscription import/update."
    return 1
  fi

  python3 - "$link" "$PROXY_CONFIG_FILE" <<'PY2'
import base64
import json
import sys
from urllib.parse import urlparse, parse_qs, unquote

link = sys.argv[1].strip()
out_path = sys.argv[2]

def b64decode_padded(data: str) -> str:
    data = data.strip()
    data = data.replace("-", "+").replace("_", "/")
    data += "=" * (-len(data) % 4)
    return base64.b64decode(data).decode("utf-8", errors="replace")

def first(q, *keys, default=""):
    for k in keys:
        if k in q and q[k]:
            return q[k][0]
    return default

def is_true(value: str) -> bool:
    return str(value).lower() in ("1", "true", "yes", "y")

def safe_int(value, default=0):
    try:
        if value is None or value == "":
            return default
        return int(str(value))
    except Exception:
        return default

def normalize_security(sec: str, default="auto"):
    sec = (sec or default).lower()
    mapping = {
        "chacha20-poly1305": "chacha20-poly1305",
        "chacha20-ietf-poly1305": "chacha20-poly1305",
        "aes-128-gcm": "aes-128-gcm",
        "aes-128-ctr": "aes-128-ctr",
        "none": "none",
        "zero": "zero",
        "auto": "auto",
    }
    return mapping.get(sec, default)

def build_tls(q, security):
    security = (security or "none").lower()

    if security not in ("tls", "reality"):
        return None

    tls = {
        "enabled": True
    }

    sni = first(q, "sni", "serverName", "servername", "peer")
    if sni:
        tls["server_name"] = sni

    if is_true(first(q, "allowInsecure", "insecure", "skip-cert-verify")):
        tls["insecure"] = True

    fp = first(q, "fp", "fingerprint")
    if fp and fp.lower() != "none":
        tls["utls"] = {
            "enabled": True,
            "fingerprint": fp
        }

    if security == "reality":
        pbk = first(q, "pbk", "publicKey", "public_key")
        sid = first(q, "sid", "shortId", "short_id")

        reality = {
            "enabled": True
        }

        if pbk:
            reality["public_key"] = pbk

        if sid:
            reality["short_id"] = sid

        tls["reality"] = reality

    return tls

def build_transport(q):
    transport_type = first(q, "type", "net", default="tcp").lower()

    if transport_type in ("ws", "websocket"):
        host = first(q, "host")
        path = first(q, "path", default="/")

        transport = {
            "type": "ws",
            "path": path
        }

        if host:
            transport["headers"] = {
                "Host": host.split(",")[0]
            }

        return transport

    if transport_type == "grpc":
        service_name = first(q, "serviceName", "service_name", "path")

        transport = {
            "type": "grpc"
        }

        if service_name:
            transport["service_name"] = service_name.lstrip("/")

        return transport

    if transport_type in ("httpupgrade", "http_upgrade"):
        host = first(q, "host")
        path = first(q, "path", default="/")

        transport = {
            "type": "httpupgrade",
            "path": path
        }

        if host:
            transport["headers"] = {
                "Host": host.split(",")[0]
            }

        return transport

    return None

def parse_ss(uri: str):
    raw = uri[5:]

    if "#" in raw:
        raw, _frag = raw.split("#", 1)

    if "?" in raw:
        raw, _query = raw.split("?", 1)

    raw = unquote(raw)

    if "@" in raw:
        userinfo, hostport = raw.rsplit("@", 1)

        try:
            decoded_userinfo = b64decode_padded(userinfo)
        except Exception:
            decoded_userinfo = userinfo

        method, password = decoded_userinfo.split(":", 1)

        if hostport.startswith("["):
            end = hostport.find("]")
            server = hostport[1:end]
            port = int(hostport[end+2:])
        else:
            server, port_s = hostport.rsplit(":", 1)
            port = int(port_s)
    else:
        decoded = b64decode_padded(raw)
        userinfo, hostport = decoded.rsplit("@", 1)
        method, password = userinfo.split(":", 1)

        if hostport.startswith("["):
            end = hostport.find("]")
            server = hostport[1:end]
            port = int(hostport[end+2:])
        else:
            server, port_s = hostport.rsplit(":", 1)
            port = int(port_s)

    return {
        "type": "shadowsocks",
        "tag": "install-out",
        "server": server,
        "server_port": int(port),
        "method": method,
        "password": password,
    }

def parse_vless(uri: str):
    u = urlparse(uri)
    q = parse_qs(u.query)

    uuid = unquote(u.username or "")
    server = u.hostname or ""
    port = u.port or 443

    if not uuid or not server:
        raise ValueError("Invalid VLESS link: missing uuid or server")

    outbound = {
        "type": "vless",
        "tag": "install-out",
        "server": server,
        "server_port": int(port),
        "uuid": uuid,
    }

    flow = first(q, "flow")
    if flow:
        outbound["flow"] = flow

    packet_encoding = first(q, "packetEncoding", "packet_encoding")
    if packet_encoding:
        outbound["packet_encoding"] = packet_encoding

    security = first(q, "security", default="none").lower()

    tls = build_tls(q, security)
    if tls:
        outbound["tls"] = tls

    transport = build_transport(q)
    if transport:
        outbound["transport"] = transport

    return outbound

def parse_trojan(uri: str):
    u = urlparse(uri)
    q = parse_qs(u.query)

    password = unquote(u.username or "")
    server = u.hostname or ""
    port = u.port or 443

    if not password or not server:
        raise ValueError("Invalid Trojan link: missing password or server")

    outbound = {
        "type": "trojan",
        "tag": "install-out",
        "server": server,
        "server_port": int(port),
        "password": password,
        "network": "tcp"
    }

    security = first(q, "security", default="tls").lower()

    tls = build_tls(q, security)
    if tls:
        outbound["tls"] = tls

    transport = build_transport(q)
    if transport:
        outbound["transport"] = transport

    return outbound

def parse_vmess(uri: str):
    if not uri.startswith("vmess://"):
        raise ValueError("Not a VMess link")

    raw = uri[8:].strip()

    if "#" in raw:
        raw, _frag = raw.split("#", 1)

    decoded = b64decode_padded(raw)
    obj = json.loads(decoded)

    server = obj.get("add") or obj.get("server") or ""
    port = safe_int(obj.get("port"), 443)
    uuid = obj.get("id") or obj.get("uuid") or ""

    if not server or not uuid:
        raise ValueError("Invalid VMess link: missing server or uuid")

    outbound = {
        "type": "vmess",
        "tag": "install-out",
        "server": server,
        "server_port": int(port),
        "uuid": uuid,
        "security": normalize_security(obj.get("scy") or obj.get("security") or "auto", "auto"),
        "alter_id": safe_int(obj.get("aid") or obj.get("alterId"), 0)
    }

    packet_encoding = obj.get("packet_encoding") or obj.get("packetEncoding")
    if packet_encoding:
        outbound["packet_encoding"] = packet_encoding

    # VMess TLS
    tls_mode = (obj.get("tls") or "").lower()
    if tls_mode in ("tls", "reality"):
        q = {
            "sni": [obj.get("sni") or obj.get("serverName") or obj.get("peer") or ""],
            "fp": [obj.get("fp") or obj.get("fingerprint") or ""],
            "allowInsecure": [str(obj.get("allowInsecure") or obj.get("insecure") or "")]
        }
        tls = build_tls(q, tls_mode)
        if tls:
            outbound["tls"] = tls

    # VMess transport
    net = (obj.get("net") or obj.get("type") or "tcp").lower()

    if net in ("ws", "websocket"):
        path = obj.get("path") or "/"
        host = obj.get("host") or ""

        transport = {
            "type": "ws",
            "path": path
        }

        if host:
            transport["headers"] = {
                "Host": str(host).split(",")[0]
            }

        outbound["transport"] = transport

    elif net == "grpc":
        service_name = obj.get("path") or obj.get("serviceName") or obj.get("service_name") or ""

        transport = {
            "type": "grpc"
        }

        if service_name:
            transport["service_name"] = str(service_name).lstrip("/")

        outbound["transport"] = transport

    elif net in ("httpupgrade", "http_upgrade"):
        path = obj.get("path") or "/"
        host = obj.get("host") or ""

        transport = {
            "type": "httpupgrade",
            "path": path
        }

        if host:
            transport["headers"] = {
                "Host": str(host).split(",")[0]
            }

        outbound["transport"] = transport

    return outbound

if link.startswith("ss://"):
    proxy_outbound = parse_ss(link)
elif link.startswith("vless://"):
    proxy_outbound = parse_vless(link)
elif link.startswith("trojan://"):
    proxy_outbound = parse_trojan(link)
elif link.startswith("vmess://"):
    proxy_outbound = parse_vmess(link)
else:
    raise ValueError("Unsupported link type for proxy mode")

config = {
    "log": {
        "level": "info",
        "timestamp": True
    },
    "inbounds": [
        {
            "type": "mixed",
            "tag": "local-install-proxy",
            "listen": "127.0.0.1",
            "listen_port": 19080
        }
    ],
    "outbounds": [
        proxy_outbound,
        {
            "type": "direct",
            "tag": "direct"
        }
    ],
    "route": {
        "final": "install-out"
    }
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)

print(f"Proxy config generated for {proxy_outbound['type']} server: {proxy_outbound['server']}:{proxy_outbound['server_port']}")
PY2
}'''

text = text[:start] + new_func + text[end:]

text = text.replace(
'''echo "- trojan:// Trojan"''',
'''echo "- trojan:// Trojan"
  echo "- vmess:// VMess"'''
)

text = text.replace(
'''Proxy Mode currently supports ss://, vless:// and trojan:// links.''',
'''Proxy Mode currently supports ss://, vless://, trojan:// and vmess:// links.'''
)

text = text.replace(
'''Next steps: VMess / Subscription.''',
'''Next step: Subscription import/update.'''
)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 16 completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add VMess support to proxy mode' && git push"
