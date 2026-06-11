#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$BASE_DIR/lib/ui.sh"

DATA_DIR="/var/lib/viptrue/cf-clean-ip-scanner"
JOBS_DIR="$DATA_DIR/jobs"
TELEGRAM_ENV="/etc/viptrue/telegram.env"
SCAN_CORE="$DATA_DIR/scan_core.py"

mkdir -p "$DATA_DIR" "$JOBS_DIR" /etc/viptrue

PROFILE_JSON="$DATA_DIR/profile.json"
CUSTOM_FILE="$DATA_DIR/custom-ips.txt"

DEFAULT_DELAY_URL="https://www.cloudflare.com/cdn-cgi/trace"
DEFAULT_DOWNLOAD_URL="https://speed.cloudflare.com/__down?bytes=10000000"
DEFAULT_UPLOAD_URL="https://speed.cloudflare.com/__up"
DEFAULT_UPLOAD_BYTES="5000000"

find_xray() {
  local xray_bin
  xray_bin="$(command -v xray || true)"
  if [[ -z "$xray_bin" ]]; then
    for x in /usr/local/bin/xray /usr/bin/xray /opt/xray/xray /usr/local/xray/xray; do
      [[ -x "$x" ]] && xray_bin="$x" && break
    done
  fi
  echo "$xray_bin"
}

install_xray_for_scanner() {
  title
  echo -e "${CYAN}Install Xray for Scanner${NC}"
  line
  echo "Xray is required because this scanner tests IPs through your real VLESS/XHTTP config."
  echo
  read -r -p "Install Xray now? [y/N]: " ok
  case "$ok" in y|Y|yes|YES) ;; *) return 1 ;; esac

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip ca-certificates

  local arch asset tmp url
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    armv7l) asset="Xray-linux-arm32-v7a.zip" ;;
    *) echo -e "${RED}Unsupported architecture: $arch${NC}"; pause; return 1 ;;
  esac

  tmp="$(mktemp -d)"
  url="https://github.com/XTLS/Xray-core/releases/latest/download/${asset}"
  curl -L --connect-timeout 20 --retry 3 -o "$tmp/xray.zip" "$url"
  unzip -o "$tmp/xray.zip" -d "$tmp/xray" >/dev/null
  install -m 755 "$tmp/xray/xray" /usr/local/bin/xray
  mkdir -p /usr/local/share/xray
  [[ -f "$tmp/xray/geoip.dat" ]] && install -m 644 "$tmp/xray/geoip.dat" /usr/local/share/xray/geoip.dat
  [[ -f "$tmp/xray/geosite.dat" ]] && install -m 644 "$tmp/xray/geosite.dat" /usr/local/share/xray/geosite.dat
  rm -rf "$tmp"

  echo -e "${GREEN}Xray installed.${NC}"
  xray version | head -5 || true
  pause
}

write_scan_core() {
  cat > "$SCAN_CORE" <<'PYCORE'
#!/usr/bin/env python3
import argparse, csv, json, pathlib, random, socket, subprocess, tempfile, time, urllib.parse, urllib.request, urllib.parse as up
import concurrent.futures

def fnum(x, default=999999.0):
    try:
        return float(x)
    except Exception:
        return default

def speed_to_mbps(bytes_per_second):
    return fnum(bytes_per_second, 0.0) * 8 / 1000 / 1000

def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

def parse_profile(profile_file):
    profile = json.loads(pathlib.Path(profile_file).read_text())
    raw = profile["raw"]
    u = urllib.parse.urlparse(raw)
    q = urllib.parse.parse_qs(u.query)

    def one(k, default=""):
        vals = q.get(k, [])
        return vals[0] if vals else default

    extra_headers = {}
    extra_raw = one("extra", "")
    if extra_raw:
        try:
            extra = json.loads(extra_raw)
            if isinstance(extra, dict):
                extra_headers = extra.get("headers", {}) or {}
        except Exception:
            pass

    p = {
        "uuid": profile.get("uuid") or u.username,
        "port": int(profile.get("port") or u.port or 443),
        "network": profile.get("network") or one("type", "xhttp"),
        "security": profile.get("security") or one("security", "tls"),
        "sni": profile.get("sni") or one("sni", "") or profile.get("host"),
        "host": profile.get("host") or one("host", "") or profile.get("sni"),
        "path": profile.get("path") or one("path", "/"),
        "mode": profile.get("mode") or one("mode", "auto"),
        "fingerprint": profile.get("fingerprint") or one("fp", "chrome"),
        "alpn": [x for x in (profile.get("alpn") or one("alpn", "")).replace("|", ",").split(",") if x],
        "headers": extra_headers,
    }
    if not p["path"].startswith("/"):
        p["path"] = "/" + p["path"]
    return p

def build_xray_config(profile, ip, socks_port):
    outbound = {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": ip,
                "port": profile["port"],
                "users": [{"id": profile["uuid"], "encryption": "none"}],
            }]
        },
        "streamSettings": {
            "network": profile["network"],
            "security": profile["security"],
        },
    }

    if profile["security"] == "tls":
        outbound["streamSettings"]["tlsSettings"] = {
            "serverName": profile["sni"],
            "fingerprint": profile["fingerprint"],
            "allowInsecure": False,
        }
        if profile["alpn"]:
            outbound["streamSettings"]["tlsSettings"]["alpn"] = profile["alpn"]

    if profile["network"] == "xhttp":
        outbound["streamSettings"]["xhttpSettings"] = {
            "host": profile["host"],
            "path": profile["path"],
            "mode": profile["mode"],
        }
        if profile["headers"]:
            outbound["streamSettings"]["xhttpSettings"]["headers"] = profile["headers"]

    elif profile["network"] == "ws":
        outbound["streamSettings"]["wsSettings"] = {
            "host": profile["host"],
            "path": profile["path"],
            "headers": profile["headers"],
        }

    return {
        "log": {"loglevel": "error"},
        "inbounds": [{
            "tag": "socks",
            "listen": "127.0.0.1",
            "port": socks_port,
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": True},
        }],
        "outbounds": [
            outbound,
            {"tag": "direct", "protocol": "freedom"},
            {"tag": "block", "protocol": "blackhole"},
        ],
    }

def curl_via_socks(socks_port, url, max_time, upload_file=None):
    if upload_file:
        fmt = "code=%{http_code} connect=%{time_connect} start=%{time_starttransfer} total=%{time_total} size=%{size_upload} speed=%{speed_upload}"
        cmd = [
            "curl", "-sS", "-o", "/dev/null",
            "--socks5-hostname", f"127.0.0.1:{socks_port}",
            "--connect-timeout", "5",
            "--max-time", str(max_time),
            "-X", "POST",
            "--data-binary", f"@{upload_file}",
            "-w", fmt,
            url,
        ]
    else:
        fmt = "code=%{http_code} connect=%{time_connect} start=%{time_starttransfer} total=%{time_total} size=%{size_download} speed=%{speed_download}"
        cmd = [
            "curl", "-L", "-sS", "-o", "/dev/null",
            "--socks5-hostname", f"127.0.0.1:{socks_port}",
            "--connect-timeout", "5",
            "--max-time", str(max_time),
            "-w", fmt,
            url,
        ]

    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    data = {"code": "000", "connect": "0", "start": "0", "total": "0", "size": "0", "speed": "0", "error": (p.stderr or "")[:180]}
    for part in (p.stdout or "").split():
        if "=" in part:
            k, v = part.split("=", 1)
            data[k] = v
    return data

def run_with_xray(xray_bin, profile, ip, url, max_time, upload_file=None):
    socks_port = free_port()
    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix="viptrue-xray-"))
    conf = tmpdir / "config.json"
    conf.write_text(json.dumps(build_xray_config(profile, ip, socks_port), indent=2))

    proc = None
    try:
        proc = subprocess.Popen([xray_bin, "run", "-c", str(conf)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        time.sleep(0.8)

        if proc.poll() is not None:
            err = proc.stderr.read() if proc.stderr else ""
            return {"code": "000", "connect": "0", "start": "0", "total": "0", "size": "0", "speed": "0", "error": ("xray_exit " + err[:160])}

        return curl_via_socks(socks_port, url, max_time, upload_file=upload_file)

    except Exception as e:
        return {"code": "000", "connect": "0", "start": "0", "total": "0", "size": "0", "speed": "0", "error": str(e)[:180]}

    finally:
        if proc and proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=1.5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        try:
            for child in tmpdir.glob("*"):
                child.unlink()
            tmpdir.rmdir()
        except Exception:
            pass

def send_telegram(env_file, text):
    env = {}
    p = pathlib.Path(env_file)
    if not p.exists():
        return False, "telegram env not found"
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")

    token = env.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = env.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        return False, "telegram token/chat_id missing"

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    data = up.urlencode({"chat_id": chat_id, "text": text, "disable_web_page_preview": "true"}).encode()
    try:
        with urllib.request.urlopen(url, data=data, timeout=15) as r:
            return True, r.read().decode()[:120]
    except Exception as e:
        return False, str(e)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--xray", required=True)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--ips", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--scan-mode", default="2")
    ap.add_argument("--limit", type=int, default=300)
    ap.add_argument("--delay-workers", type=int, default=5)
    ap.add_argument("--delay-url", default="https://www.cloudflare.com/cdn-cgi/trace")
    ap.add_argument("--download", action="store_true")
    ap.add_argument("--download-url", default="https://speed.cloudflare.com/__down?bytes=10000000")
    ap.add_argument("--upload", action="store_true")
    ap.add_argument("--upload-url", default="https://speed.cloudflare.com/__up")
    ap.add_argument("--upload-bytes", type=int, default=5000000)
    ap.add_argument("--speed-limit", type=int, default=20)
    ap.add_argument("--speed-workers", type=int, default=3)
    ap.add_argument("--telegram-env", default="/etc/viptrue/telegram.env")
    ap.add_argument("--telegram", action="store_true")
    args = ap.parse_args()

    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    delay_csv = out_dir / "exact-xray-results.csv"
    delay_best_txt = out_dir / "exact-xray-best.txt"
    delay_best_comma = out_dir / "exact-xray-best-comma.txt"

    final_csv = out_dir / "exact-xray-final-results.csv"
    final_best_txt = out_dir / "exact-xray-final-best.txt"
    final_best_comma = out_dir / "exact-xray-final-best-comma.txt"

    profile = parse_profile(args.profile)

    all_ips = [x.strip() for x in pathlib.Path(args.ips).read_text().splitlines() if x.strip()]
    if args.scan_mode == "3" or args.limit == 0:
        ips = all_ips
    elif args.scan_mode == "2":
        ips = random.sample(all_ips, min(args.limit, len(all_ips)))
    else:
        ips = all_ips[:args.limit]

    print("VIPTrue Exact Cloudflare IP Scanner")
    print("-----------------------------------")
    print(f"Total IP list: {len(all_ips)}")
    print(f"Testing IPs:   {len(ips)}")
    print(f"Scan mode:     {args.scan_mode}")
    print(f"SNI:           {profile['sni']}")
    print(f"Host:          {profile['host']}")
    print(f"Port:          {profile['port']}")
    print(f"Path:          {profile['path']}")
    print(f"Delay URL:     {args.delay_url}")
    print(f"Download:      {args.download}")
    print(f"Upload:        {args.upload}")
    print()

    def delay_one(ip):
        d = run_with_xray(args.xray, profile, ip, args.delay_url, 15)
        code = d.get("code", "000")
        total = fnum(d.get("total"), 0.0)
        ok = "1" if code not in ("000", "") and total > 0 else "0"
        return {
            "ip": ip, "ok": ok, "code": code,
            "connect": d.get("connect", "0"),
            "start": d.get("start", "0"),
            "total": d.get("total", "0"),
            "delay_ms": f"{total * 1000:.1f}",
            "error": d.get("error", "")[:180],
        }

    delay_results = []
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.delay_workers) as ex:
        futs = [ex.submit(delay_one, ip) for ip in ips]
        for fut in concurrent.futures.as_completed(futs):
            delay_results.append(fut.result())
            done += 1
            if done % 10 == 0 or done == len(ips):
                print(f"Delay progress: {done}/{len(ips)}", flush=True)

    delay_results.sort(key=lambda r: (r["ok"] != "1", fnum(r["total"]), fnum(r["start"])))

    with delay_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["ip", "ok", "code", "connect", "start", "total", "delay_ms", "error"])
        w.writeheader()
        w.writerows(delay_results)

    alive = [r for r in delay_results if r["ok"] == "1"]
    delay_best_txt.write_text("\n".join(r["ip"] for r in alive[:30]) + ("\n" if alive else ""))
    delay_best_comma.write_text(",".join(r["ip"] for r in alive[:30]) + ("\n" if alive else ""))

    print()
    print(f"Alive IPs: {len(alive)}")
    print("Top delay:")
    for r in alive[:10]:
        print(f'{r["ip"]:15} code={r["code"]} delay={r["delay_ms"]}ms')

    final_rows = []
    speed_ips = [r["ip"] for r in alive[:args.speed_limit]]

    upload_file = None
    if args.upload:
        upload_file = out_dir / f"upload-{args.upload_bytes}.bin"
        if not upload_file.exists() or upload_file.stat().st_size != args.upload_bytes:
            with upload_file.open("wb") as f:
                f.write(b"\0" * args.upload_bytes)

    if (args.download or args.upload) and speed_ips:
        print()
        print("Running download/upload tests...")
        print(f"Speed IPs: {len(speed_ips)}")
        print()

        def speed_one(ip):
            row = {
                "ip": ip,
                "download_code": "000",
                "download_mbps": "0",
                "download_total": "0",
                "upload_code": "000",
                "upload_mbps": "0",
                "upload_total": "0",
                "delay_ms": "999999",
                "score": "0",
                "error": "",
            }

            match = next((x for x in alive if x["ip"] == ip), None)
            if match:
                row["delay_ms"] = match.get("delay_ms", "999999")

            if args.download:
                d = run_with_xray(args.xray, profile, ip, args.download_url, 35)
                row["download_code"] = d.get("code", "000")
                row["download_total"] = d.get("total", "0")
                row["download_mbps"] = f"{speed_to_mbps(d.get('speed', '0')):.3f}"
                if d.get("error"):
                    row["error"] += "DL:" + d.get("error", "")[:60] + " "

            if args.upload:
                u = run_with_xray(args.xray, profile, ip, args.upload_url, 35, upload_file=str(upload_file))
                row["upload_code"] = u.get("code", "000")
                row["upload_total"] = u.get("total", "0")
                row["upload_mbps"] = f"{speed_to_mbps(u.get('speed', '0')):.3f}"
                if u.get("error"):
                    row["error"] += "UP:" + u.get("error", "")[:60] + " "

            dl = fnum(row["download_mbps"], 0)
            upv = fnum(row["upload_mbps"], 0)
            delay_s = fnum(row["delay_ms"], 999999) / 1000
            score = dl * 0.45 + upv * 0.35 - delay_s * 20
            row["score"] = f"{score:.3f}"
            return row

        done2 = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.speed_workers) as ex:
            futs = [ex.submit(speed_one, ip) for ip in speed_ips]
            for fut in concurrent.futures.as_completed(futs):
                final_rows.append(fut.result())
                done2 += 1
                print(f"Speed progress: {done2}/{len(speed_ips)}", flush=True)

        final_rows.sort(key=lambda r: -fnum(r["score"], -999999))
    else:
        for r in alive:
            final_rows.append({
                "ip": r["ip"],
                "download_code": "",
                "download_mbps": "",
                "download_total": "",
                "upload_code": "",
                "upload_mbps": "",
                "upload_total": "",
                "delay_ms": r.get("delay_ms", ""),
                "score": f"{0 - (fnum(r.get('delay_ms'), 999999)/1000)*20:.3f}",
                "error": r.get("error", ""),
            })

    with final_csv.open("w", newline="") as f:
        fields = ["ip", "score", "delay_ms", "download_code", "download_mbps", "download_total", "upload_code", "upload_mbps", "upload_total", "error"]
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in final_rows:
            w.writerow({k: r.get(k, "") for k in fields})

    good = [r for r in final_rows if fnum(r.get("score"), -999999) > -999999]
    final_best_txt.write_text("\n".join(r["ip"] for r in good[:30]) + ("\n" if good else ""))
    final_best_comma.write_text(",".join(r["ip"] for r in good[:30]) + ("\n" if good else ""))

    print()
    print("Top final results:")
    for r in good[:10]:
        print(f'{r["ip"]:15} score={r["score"]:>8} delay={r["delay_ms"]}ms dl={r["download_mbps"]}Mbps up={r["upload_mbps"]}Mbps')

    print()
    print(f"Final CSV:   {final_csv}")
    print(f"Final Best:  {final_best_txt}")
    print(f"Final Comma: {final_best_comma}")

    if args.telegram:
        top = good[:8]
        lines = ["✅ VIPTrue Cloudflare IP Scan Finished", ""]
        for i, r in enumerate(top, 1):
            lines.append(f"{i}. {r['ip']} | score={r['score']} | delay={r['delay_ms']}ms | DL={r['download_mbps']}Mbps | UP={r['upload_mbps']}Mbps")
        lines.append("")
        lines.append("Comma:")
        lines.append(",".join(r["ip"] for r in good[:10]))
        ok, msg = send_telegram(args.telegram_env, "\n".join(lines))
        print()
        print(f"Telegram notify: {ok} {msg}")

if __name__ == "__main__":
    main()
PYCORE

  chmod +x "$SCAN_CORE"
}

paste_config_profile() {
  title
  echo -e "${CYAN}Paste / Update VLESS Config${NC}"
  line
  echo
  read -r -p "Config: " config

  if [[ -z "$config" ]]; then
    echo -e "${RED}Empty config.${NC}"
    pause
    return
  fi

  python3 - "$config" "$PROFILE_JSON" <<'PY'
import sys, json, urllib.parse
raw = sys.argv[1].strip()
out = sys.argv[2]
if not raw.startswith("vless://"):
    raise SystemExit("Only vless:// links are supported.")
u = urllib.parse.urlparse(raw)
q = urllib.parse.parse_qs(u.query)
def one(key, default=""):
    vals = q.get(key, [])
    return vals[0] if vals else default
address = u.hostname or ""
port = str(u.port or 443)
sni = one("sni", "") or one("serverName", "")
host = one("host", "") or sni or address
path = one("path", "/")
alpn = one("alpn", "")
security = one("security", "tls")
network = one("type", "xhttp")
mode = one("mode", "auto")
fp = one("fp", "chrome")
if not path.startswith("/"):
    path = "/" + path
profile = {
    "raw": raw, "uuid": u.username, "address": address, "port": port,
    "sni": sni, "host": host, "path": path, "alpn": alpn,
    "security": security, "network": network, "mode": mode,
    "fingerprint": fp
}
open(out, "w").write(json.dumps(profile, indent=2, ensure_ascii=False))
print()
print("Saved config profile:")
print(f"  Address: {address}")
print(f"  Port:    {port}")
print(f"  SNI:     {sni}")
print(f"  Host:    {host}")
print(f"  Path:    {path}")
print(f"  ALPN:    {alpn}")
print(f"  Network: {network}")
PY
  echo
  echo -e "${GREEN}Profile saved.${NC}"
  pause
}

paste_ips_manual() {
  title
  echo -e "${CYAN}Paste Custom IPs Manually${NC}"
  line
  echo "Paste IPs. Separators: comma, space, or new line."
  echo "When finished, type exactly:"
  echo
  echo "END_VIPTRUE_IPS"
  echo

  : > "$CUSTOM_FILE.tmp"
  while IFS= read -r line; do
    [[ "$line" == "END_VIPTRUE_IPS" ]] && break
    printf '%s\n' "$line" >> "$CUSTOM_FILE.tmp"
  done

  tr ', \t' '\n' < "$CUSTOM_FILE.tmp" | sed 's/\r//g' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u > "$CUSTOM_FILE.new"
  rm -f "$CUSTOM_FILE.tmp"

  if [[ -s "$CUSTOM_FILE" ]]; then
    cat "$CUSTOM_FILE" "$CUSTOM_FILE.new" | sort -u > "$CUSTOM_FILE.merged"
    mv "$CUSTOM_FILE.merged" "$CUSTOM_FILE"
    rm -f "$CUSTOM_FILE.new"
  else
    mv "$CUSTOM_FILE.new" "$CUSTOM_FILE"
  fi

  echo
  echo -e "${GREEN}Saved IP list:${NC} $CUSTOM_FILE"
  wc -l "$CUSTOM_FILE"
  pause
}

add_cloudflare_range_samples() {
  title
  echo -e "${CYAN}Add Sample IPs From Cloudflare Ranges${NC}"
  line
  read -r -p "Sample IPs per Cloudflare range [20]: " sample
  sample="${sample:-20}"

  python3 - "$CUSTOM_FILE" "$sample" <<'PY'
import sys, ipaddress, random, pathlib
out = pathlib.Path(sys.argv[1])
sample = int(sys.argv[2])
ranges = """
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
""".strip().splitlines()
ips = set()
if out.exists():
    for line in out.read_text().splitlines():
        if line.strip():
            ips.add(line.strip())
for line in ranges:
    net = ipaddress.ip_network(line.strip(), strict=False)
    total = net.num_addresses
    for _ in range(sample):
        idx = random.randint(1, total - 2)
        ips.add(str(net.network_address + idx))
out.write_text("\n".join(sorted(ips)) + "\n")
print(f"Saved total IPs: {len(ips)}")
print(f"File: {out}")
PY
  echo
  nl -ba "$CUSTOM_FILE" | head -40 || true
  pause
}

show_ip_list() {
  title
  echo -e "${CYAN}Current IP List${NC}"
  line
  if [[ -s "$CUSTOM_FILE" ]]; then
    echo "File: $CUSTOM_FILE"
    wc -l "$CUSTOM_FILE"
    echo
    nl -ba "$CUSTOM_FILE" | head -80
  else
    echo "No IP list saved yet."
  fi
  pause
}

ip_list_menu() {
  while true; do
    title
    echo -e "${CYAN}Paste / Update Custom IP List${NC}"
    line
    echo "1. Paste custom IPs manually"
    echo "2. Add sample IPs from Cloudflare ranges"
    echo "3. Show current IP list"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-3]: " sub
    case "$sub" in
      1) paste_ips_manual ;;
      2) add_cloudflare_range_samples ;;
      3) show_ip_list ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

ensure_xray() {
  local xray_bin
  xray_bin="$(find_xray)"

  if [[ -z "$xray_bin" ]]; then
    echo -e "${YELLOW}xray binary not found.${NC}" >&2
    install_xray_for_scanner >&2 || true
    xray_bin="$(find_xray)"
  fi

  if [[ -z "$xray_bin" ]] || [[ ! -x "$xray_bin" ]]; then
    echo -e "${RED}Xray is still not available. Install it first.${NC}" >&2
    echo >&2
    echo "Quick install:" >&2
    echo '  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install' >&2
    echo >&2
    pause >&2
    return 1
  fi

  printf '%s\n' "$xray_bin"
}

run_scan() {
  title
  echo -e "${CYAN}Run Scan${NC}"
  line
  echo

  local xray_bin
  xray_bin="$(ensure_xray)" || return

  if [[ ! -s "$PROFILE_JSON" ]]; then
    echo -e "${YELLOW}No VLESS config profile found. Use option 1 first.${NC}"
    pause
    return
  fi
  if [[ ! -s "$CUSTOM_FILE" ]]; then
    echo -e "${YELLOW}No IP list found. Use option 2 first.${NC}"
    pause
    return
  fi

  echo "Run mode:"
  echo "1. Foreground"
  echo "2. Background"
  echo
  read -r -p "Choose run mode [1]: " run_mode
  run_mode="${run_mode:-1}"

  echo
  echo "Scan mode:"
  echo "1. First N IPs"
  echo "2. Random N IPs"
  echo "3. All IPs"
  echo
  read -r -p "Choose scan mode [2]: " scan_mode
  scan_mode="${scan_mode:-2}"

  case "$scan_mode" in
    1) read -r -p "How many first IPs? [100]: " limit; limit="${limit:-100}" ;;
    2) read -r -p "How many random IPs? [300]: " limit; limit="${limit:-300}" ;;
    3) limit="0" ;;
    *) echo -e "${RED}Invalid scan mode.${NC}"; pause; return ;;
  esac

  read -r -p "Delay workers [5]: " delay_workers
  delay_workers="${delay_workers:-5}"

  read -r -p "Delay test URL [$DEFAULT_DELAY_URL]: " delay_url
  delay_url="${delay_url:-$DEFAULT_DELAY_URL}"

  echo
  read -r -p "Test download speed? [Y/n]: " dl_yes
  case "$dl_yes" in n|N|no|NO) download_flag="" ;; *) download_flag="--download" ;; esac

  download_url="$DEFAULT_DOWNLOAD_URL"
  if [[ -n "$download_flag" ]]; then
    read -r -p "Download URL [$DEFAULT_DOWNLOAD_URL]: " download_url
    download_url="${download_url:-$DEFAULT_DOWNLOAD_URL}"
  fi

  read -r -p "Test upload speed? [y/N]: " up_yes
  upload_flag=""
  upload_url="$DEFAULT_UPLOAD_URL"
  upload_bytes="$DEFAULT_UPLOAD_BYTES"
  if [[ "$up_yes" =~ ^[yY] ]]; then
    upload_flag="--upload"
    read -r -p "Upload URL [$DEFAULT_UPLOAD_URL]: " upload_url
    upload_url="${upload_url:-$DEFAULT_UPLOAD_URL}"
    read -r -p "Upload bytes per IP [$DEFAULT_UPLOAD_BYTES]: " upload_bytes
    upload_bytes="${upload_bytes:-$DEFAULT_UPLOAD_BYTES}"
  fi

  read -r -p "How many best delay IPs for speed tests? [20]: " speed_limit
  speed_limit="${speed_limit:-20}"

  read -r -p "Speed workers [3]: " speed_workers
  speed_workers="${speed_workers:-3}"

  read -r -p "Send result to Telegram after finish? [y/N]: " tg_yes
  telegram_flag=""
  [[ "$tg_yes" =~ ^[yY] ]] && telegram_flag="--telegram"

  write_scan_core

  local cmd
  cmd=(python3 "$SCAN_CORE"
    --xray "$xray_bin"
    --profile "$PROFILE_JSON"
    --ips "$CUSTOM_FILE"
    --out-dir "$DATA_DIR"
    --scan-mode "$scan_mode"
    --limit "$limit"
    --delay-workers "$delay_workers"
    --delay-url "$delay_url"
    --download-url "$download_url"
    --upload-url "$upload_url"
    --upload-bytes "$upload_bytes"
    --speed-limit "$speed_limit"
    --speed-workers "$speed_workers"
    --telegram-env "$TELEGRAM_ENV"
  )

  [[ -n "$download_flag" ]] && cmd+=("$download_flag")
  [[ -n "$upload_flag" ]] && cmd+=("$upload_flag")
  [[ -n "$telegram_flag" ]] && cmd+=("$telegram_flag")

  echo
  echo "Start scan?"
  read -r -p "[y/N]: " ok
  case "$ok" in y|Y|yes|YES) ;; *) return ;; esac

  if [[ "$run_mode" == "2" ]]; then
    local job_id job_dir log_file pid_file
    job_id="$(date +%F-%H%M%S)"
    job_dir="$JOBS_DIR/$job_id"
    mkdir -p "$job_dir"
    log_file="$job_dir/scan.log"
    pid_file="$job_dir/scan.pid"

    nohup "${cmd[@]}" > "$log_file" 2>&1 &
    echo $! > "$pid_file"

    echo
    echo -e "${GREEN}Background scan started.${NC}"
    echo "Job ID: $job_id"
    echo "PID:    $(cat "$pid_file")"
    echo "Log:    $log_file"
    echo
    echo "You can close SSH. The scan will continue."
    pause
  else
    "${cmd[@]}"
    echo
    pause
  fi
}

show_results_jobs() {
  while true; do
    title
    echo -e "${CYAN}Results / Jobs / Logs${NC}"
    line
    echo "1. Show final best results"
    echo "2. Show final CSV path"
    echo "3. List background jobs"
    echo "4. Tail latest job log"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-4]: " c

    case "$c" in
      1)
        title
        echo -e "${CYAN}Final Best Results${NC}"
        line
        if [[ -s "$DATA_DIR/exact-xray-final-best.txt" ]]; then
          echo "Best IPs:"
          nl -ba "$DATA_DIR/exact-xray-final-best.txt" | head -30
          echo
          echo "Comma:"
          cat "$DATA_DIR/exact-xray-final-best-comma.txt"
        elif [[ -s "$DATA_DIR/exact-xray-best.txt" ]]; then
          echo "Best IPs by delay:"
          nl -ba "$DATA_DIR/exact-xray-best.txt" | head -30
          echo
          cat "$DATA_DIR/exact-xray-best-comma.txt"
        else
          echo "No results yet."
        fi
        echo
        pause
        ;;
      2)
        echo
        echo "Data directory:"
        echo "  $DATA_DIR"
        echo
        ls -lh "$DATA_DIR"/*.csv "$DATA_DIR"/*.txt 2>/dev/null || true
        echo
        pause
        ;;
      3)
        echo
        echo "Jobs:"
        find "$JOBS_DIR" -maxdepth 2 -type f -name "scan.pid" -print 2>/dev/null | sort | while read -r pidfile; do
          pid="$(cat "$pidfile" 2>/dev/null || true)"
          job="$(basename "$(dirname "$pidfile")")"
          if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$job  PID=$pid  RUNNING"
          else
            echo "$job  PID=$pid  DONE/STOPPED"
          fi
        done
        echo
        pause
        ;;
      4)
        latest="$(find "$JOBS_DIR" -maxdepth 2 -type f -name "scan.log" 2>/dev/null | sort | tail -1 || true)"
        if [[ -z "$latest" ]]; then
          echo "No job log found."
          pause
        else
          echo "Log: $latest"
          echo "Press Ctrl+C to stop watching."
          sleep 1
          tail -f "$latest"
        fi
        ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

telegram_settings() {
  while true; do
    title
    echo -e "${CYAN}Telegram Settings${NC}"
    line
    echo "1. Set bot token and chat ID"
    echo "2. Show current settings"
    echo "3. Send test message"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-3]: " c

    case "$c" in
      1)
        read -r -p "Telegram Bot Token: " token
        read -r -p "Telegram Chat ID: " chat_id
        cat > "$TELEGRAM_ENV" <<ENV
TELEGRAM_BOT_TOKEN="$token"
TELEGRAM_CHAT_ID="$chat_id"
ENV
        chmod 600 "$TELEGRAM_ENV"
        echo -e "${GREEN}Saved:${NC} $TELEGRAM_ENV"
        pause
        ;;
      2)
        if [[ -f "$TELEGRAM_ENV" ]]; then
          sed 's/TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN="***hidden***"/' "$TELEGRAM_ENV"
        else
          echo "No Telegram settings saved."
        fi
        pause
        ;;
      3)
        if [[ ! -f "$TELEGRAM_ENV" ]]; then
          echo "No Telegram settings saved."
          pause
          continue
        fi
        source "$TELEGRAM_ENV"
        curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
          -d "chat_id=${TELEGRAM_CHAT_ID}" \
          -d "text=✅ VIPTrue Scanner Telegram test message" >/dev/null && echo "Sent."
        pause
        ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}

reset_data() {
  title
  echo -e "${CYAN}Reset Scanner Data${NC}"
  line
  echo "This removes profile, IP list, results and jobs:"
  echo "  $DATA_DIR"
  echo
  read -r -p "Continue? [y/N]: " ok
  case "$ok" in
    y|Y|yes|YES)
      rm -rf "$DATA_DIR"
      mkdir -p "$DATA_DIR" "$JOBS_DIR"
      echo -e "${GREEN}Scanner data reset.${NC}"
      ;;
  esac
  pause
}

while true; do
  title
  echo -e "${CYAN}Cloudflare Clean IP Scanner${NC}"
  line
  echo "1. Paste / Update VLESS Config"
  echo "2. Paste / Update Custom IP List"
  echo "3. Run Scan"
  echo "4. Results / Jobs / Logs"
  echo "5. Telegram Settings"
  echo "6. Reset Scanner Data"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-6]: " choice

  case "$choice" in
    1) paste_config_profile ;;
    2) ip_list_menu ;;
    3) run_scan ;;
    4) show_results_jobs ;;
    5) telegram_settings ;;
    6) reset_data ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
