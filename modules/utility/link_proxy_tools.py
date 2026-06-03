#!/usr/bin/env python3
import argparse
import base64
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse, parse_qs, unquote


def b64decode_padded(data: str) -> str:
    data = data.strip().replace("-", "+").replace("_", "/")
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


def mask_link(link: str) -> str:
    masked = re.sub(r'(://)[^:@/]+:[^@/]+@', r'\1***:***@', link)
    masked = re.sub(r'(password=)[^&]+', r'\1***', masked, flags=re.I)
    masked = re.sub(r'(uuid=)[^&]+', r'\1***', masked, flags=re.I)
    masked = re.sub(r'(id=)[^&]+', r'\1***', masked, flags=re.I)

    if masked.startswith(("vless://", "trojan://")):
        try:
            p = urlparse(masked)
            if p.username:
                masked = masked.replace(p.username, "***", 1)
        except Exception:
            pass

    return masked[:180]


def parse_blocks(path: Path):
    if not path.exists():
        return []

    blocks = []
    current = {}

    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue

        if line.startswith("[") and line.endswith("]"):
            if current:
                blocks.append(current)
            current = {"id": line[1:-1]}
        elif "=" in line and current is not None:
            k, v = line.split("=", 1)
            current[k.strip()] = v.strip()

    if current:
        blocks.append(current)

    return blocks


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

    tls = {"enabled": True}

    sni = first(q, "sni", "serverName", "servername", "peer")
    if sni:
        tls["server_name"] = sni

    if is_true(first(q, "allowInsecure", "insecure", "skip-cert-verify")):
        tls["insecure"] = True

    fp = first(q, "fp", "fingerprint")
    if fp and fp.lower() != "none":
        tls["utls"] = {
            "enabled": True,
            "fingerprint": fp,
        }

    if security == "reality":
        pbk = first(q, "pbk", "publicKey", "public_key")
        sid = first(q, "sid", "shortId", "short_id")

        reality = {"enabled": True}

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
        transport = {"type": "ws", "path": path}
        if host:
            transport["headers"] = {"Host": host.split(",")[0]}
        return transport

    if transport_type == "grpc":
        service_name = first(q, "serviceName", "service_name", "path")
        transport = {"type": "grpc"}
        if service_name:
            transport["service_name"] = service_name.lstrip("/")
        return transport

    if transport_type in ("httpupgrade", "http_upgrade"):
        host = first(q, "host")
        path = first(q, "path", default="/")
        transport = {"type": "httpupgrade", "path": path}
        if host:
            transport["headers"] = {"Host": host.split(",")[0]}
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
            port = int(hostport[end + 2:])
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
            port = int(hostport[end + 2:])
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

    tls = build_tls(q, first(q, "security", default="none").lower())
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
        "network": "tcp",
    }

    tls = build_tls(q, first(q, "security", default="tls").lower())
    if tls:
        outbound["tls"] = tls

    transport = build_transport(q)
    if transport:
        outbound["transport"] = transport

    return outbound


def parse_vmess(uri: str):
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
        "alter_id": safe_int(obj.get("aid") or obj.get("alterId"), 0),
    }

    tls_mode = (obj.get("tls") or "").lower()
    if tls_mode in ("tls", "reality"):
        q = {
            "sni": [obj.get("sni") or obj.get("serverName") or obj.get("peer") or ""],
            "fp": [obj.get("fp") or obj.get("fingerprint") or ""],
            "allowInsecure": [str(obj.get("allowInsecure") or obj.get("insecure") or "")],
        }
        tls = build_tls(q, tls_mode)
        if tls:
            outbound["tls"] = tls

    net = (obj.get("net") or obj.get("type") or "tcp").lower()

    if net in ("ws", "websocket"):
        path = obj.get("path") or "/"
        host = obj.get("host") or ""
        transport = {"type": "ws", "path": path}
        if host:
            transport["headers"] = {"Host": str(host).split(",")[0]}
        outbound["transport"] = transport

    elif net == "grpc":
        service_name = obj.get("path") or obj.get("serviceName") or obj.get("service_name") or ""
        transport = {"type": "grpc"}
        if service_name:
            transport["service_name"] = str(service_name).lstrip("/")
        outbound["transport"] = transport

    elif net in ("httpupgrade", "http_upgrade"):
        path = obj.get("path") or "/"
        host = obj.get("host") or ""
        transport = {"type": "httpupgrade", "path": path}
        if host:
            transport["headers"] = {"Host": str(host).split(",")[0]}
        outbound["transport"] = transport

    return outbound


def link_to_outbound(link: str):
    if link.startswith("ss://"):
        return parse_ss(link)
    if link.startswith("vless://"):
        return parse_vless(link)
    if link.startswith("trojan://"):
        return parse_trojan(link)
    if link.startswith("vmess://"):
        return parse_vmess(link)
    raise ValueError("Unsupported link type")


def make_proxy_config(link: str, listen_port: int):
    outbound = link_to_outbound(link)

    return {
        "log": {
            "level": "error",
            "timestamp": False,
        },
        "inbounds": [
            {
                "type": "mixed",
                "tag": "local-test-proxy",
                "listen": "127.0.0.1",
                "listen_port": listen_port,
            }
        ],
        "outbounds": [
            outbound,
            {
                "type": "direct",
                "tag": "direct",
            },
        ],
        "route": {
            "final": "install-out",
        },
    }


def load_items(raw_file: Path, sub_file: Path):
    items = []

    for b in parse_blocks(raw_file):
        if b.get("link") and b.get("type"):
            b["source"] = "single"
            items.append(b)

    for b in parse_blocks(sub_file):
        if b.get("link") and b.get("type"):
            b["source"] = "subscription"
            items.append(b)

    return items


def test_real_delay(sing_box: str, link: str, port: int, timeout: int = 9):
    tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    tmp_path = tmp.name
    proc = None

    try:
        config = make_proxy_config(link, port)
        json.dump(config, tmp, indent=2)
        tmp.close()

        proc = subprocess.Popen(
            [sing_box, "run", "-c", tmp_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

        time.sleep(0.8)

        if proc.poll() is not None:
            return None, "START_FAILED"

        curl = subprocess.run(
            [
                "curl",
                "-4fsS",
                "--connect-timeout",
                "4",
                "--max-time",
                str(timeout),
                "-x",
                f"http://127.0.0.1:{port}",
                "-o",
                "/dev/null",
                "-w",
                "%{time_total}",
                "https://cp.cloudflare.com/generate_204",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout + 2,
        )

        if curl.returncode != 0:
            return None, "FAILED"

        seconds = float(curl.stdout.strip())
        return int(seconds * 1000), "OK"

    except Exception:
        return None, "ERROR"

    finally:
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except Exception:
                try:
                    proc.terminate()
                except Exception:
                    pass

            try:
                proc.wait(timeout=2)
            except Exception:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except Exception:
                    pass

        try:
            os.unlink(tmp_path)
        except Exception:
            pass


def cmd_select(args):
    raw_file = Path(args.raw)
    sub_file = Path(args.sub)
    out_file = Path(args.out)

    items = load_items(raw_file, sub_file)

    if not items:
        print("NO_ITEMS")
        out_file.write_text("")
        return 0

    test_count = args.test_count
    if test_count == 0:
        test_count = len(items)
    test_count = min(max(test_count, 1), len(items))

    print()
    print(f"Found outbounds: {len(items)}")
    print(f"Real delay test count: {test_count}")
    print()

    base_port = 19100

    for idx, item in enumerate(items, 1):
        item["delay_ms"] = ""
        item["test_status"] = "NOT_TESTED"

        if idx <= test_count:
            typ = item.get("type", "unknown")
            item_id = item.get("id", "")
            print(f"Testing {idx}/{test_count} [{typ}] [{item_id}] ... ", end="", flush=True)

            ms, status = test_real_delay(args.sing_box, item.get("link", ""), base_port, args.timeout)

            if ms is None:
                item["test_status"] = status
                print(status)
            else:
                item["delay_ms"] = str(ms)
                item["test_status"] = "OK"
                print(f"{ms} ms")

    tested_ok = [x for x in items if x.get("test_status") == "OK"]
    tested_bad = [x for x in items if x.get("test_status") not in ("OK", "NOT_TESTED")]
    not_tested = [x for x in items if x.get("test_status") == "NOT_TESTED"]

    tested_ok.sort(key=lambda x: int(x.get("delay_ms") or "999999"))
    sorted_items = tested_ok + tested_bad + not_tested

    print()
    print("Sorted outbounds:")
    print()

    lines = []

    for i, b in enumerate(sorted_items, 1):
        source = b.get("source", "")
        typ = b.get("type", "unknown")
        item_id = b.get("id", "")
        sub_name = b.get("sub_name", "")
        delay = b.get("delay_ms", "")
        status = b.get("test_status", "")

        delay_label = f"{delay} ms" if delay else status or "N/A"

        label = f"{i}. [{delay_label}] [{source}] [{typ}] [{item_id}]"
        if sub_name:
            label += f" {sub_name}"

        print(label)
        print(f"   {mask_link(b.get('link',''))}")
        print()

        lines.append(
            "\t".join(
                [
                    str(i),
                    b.get("id", ""),
                    b.get("type", ""),
                    b.get("source", ""),
                    b.get("sub_id", ""),
                    b.get("sub_name", ""),
                    b.get("link", ""),
                    b.get("delay_ms", ""),
                    b.get("test_status", ""),
                ]
            )
        )

    out_file.write_text("\n".join(lines) + "\n")
    return 0


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("select")
    p.add_argument("--raw", required=True)
    p.add_argument("--sub", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--sing-box", required=True)
    p.add_argument("--test-count", type=int, default=50)
    p.add_argument("--timeout", type=int, default=9)

    args = parser.parse_args()

    if args.command == "select":
        return cmd_select(args)

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
