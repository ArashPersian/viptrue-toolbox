#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$BASE_DIR/lib/ui.sh"

DATA_DIR="/var/lib/viptrue/cf-clean-ip-scanner"
mkdir -p "$DATA_DIR"

PROFILE_JSON="$DATA_DIR/profile.json"
CUSTOM_FILE="$DATA_DIR/custom-ips.txt"

DELAY_CSV="$DATA_DIR/exact-xray-results.csv"
DELAY_BEST_TXT="$DATA_DIR/exact-xray-best.txt"
DELAY_BEST_COMMA="$DATA_DIR/exact-xray-best-comma.txt"

SPEED_CSV="$DATA_DIR/exact-xray-speed-results.csv"
SPEED_BEST_TXT="$DATA_DIR/exact-xray-speed-best.txt"
SPEED_BEST_COMMA="$DATA_DIR/exact-xray-speed-best-comma.txt"

DEFAULT_DELAY_URL="https://www.cloudflare.com/cdn-cgi/trace"
DEFAULT_SPEED_URL="https://speed.cloudflare.com/__down?bytes=10000000"

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
  echo
  echo "Xray is required because this scanner tests IPs through your real VLESS/XHTTP config."
  echo
  read -r -p "Install Xray now? [y/N]: " ok
  case "$ok" in
    y|Y|yes|YES) ;;
    *) return 1 ;;
  esac

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip ca-certificates

  local arch asset tmp url
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    armv7l) asset="Xray-linux-arm32-v7a.zip" ;;
    *)
      echo -e "${RED}Unsupported architecture: $arch${NC}"
      pause
      return 1
      ;;
  esac

  tmp="$(mktemp -d)"
  url="https://github.com/XTLS/Xray-core/releases/latest/download/${asset}"

  echo "Downloading: $url"
  curl -L --connect-timeout 20 --retry 3 -o "$tmp/xray.zip" "$url"
  unzip -o "$tmp/xray.zip" -d "$tmp/xray" >/dev/null

  install -m 755 "$tmp/xray/xray" /usr/local/bin/xray

  mkdir -p /usr/local/share/xray
  [[ -f "$tmp/xray/geoip.dat" ]] && install -m 644 "$tmp/xray/geoip.dat" /usr/local/share/xray/geoip.dat
  [[ -f "$tmp/xray/geosite.dat" ]] && install -m 644 "$tmp/xray/geosite.dat" /usr/local/share/xray/geosite.dat

  rm -rf "$tmp"

  echo
  echo -e "${GREEN}Xray installed.${NC}"
  xray version | head -5 || true
  echo
  pause
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

ua = ""
extra_raw = one("extra", "")
if extra_raw:
    try:
        extra = json.loads(extra_raw)
        headers = extra.get("headers", {}) if isinstance(extra, dict) else {}
        ua = headers.get("User-Agent", "") or headers.get("user-agent", "")
    except Exception:
        pass

if not path.startswith("/"):
    path = "/" + path

profile = {
    "raw": raw,
    "uuid": u.username,
    "address": address,
    "port": port,
    "sni": sni,
    "host": host,
    "path": path,
    "alpn": alpn,
    "security": security,
    "network": network,
    "mode": mode,
    "fingerprint": fp,
    "user_agent": ua
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
  echo
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

  tr ', \t' '\n' < "$CUSTOM_FILE.tmp" \
    | sed 's/\r//g' \
    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
    | sort -u > "$CUSTOM_FILE.new"

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
  echo
  pause
}

add_cloudflare_range_samples() {
  title
  echo -e "${CYAN}Add Sample IPs From Cloudflare Ranges${NC}"
  line
  echo

  read -r -p "Sample IPs per Cloudflare range [20]: " sample
  sample="${sample:-20}"

  if ! [[ "$sample" =~ ^[0-9]+$ ]] || ((sample < 1)); then
    echo -e "${RED}Invalid number.${NC}"
    pause
    return
  fi

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
        line = line.strip()
        if line:
            ips.add(line)

for line in ranges:
    net = ipaddress.ip_network(line.strip(), strict=False)
    total = net.num_addresses
    if total <= 2:
        continue
    for _ in range(sample):
        idx = random.randint(1, total - 2)
        ips.add(str(net.network_address + idx))

out.write_text("\n".join(sorted(ips)) + "\n")
print(f"Saved total IPs: {len(ips)}")
print(f"File: {out}")
PY

  echo
  nl -ba "$CUSTOM_FILE" | head -40 || true
  echo
  pause
}

show_ip_list() {
  title
  echo -e "${CYAN}Current IP List${NC}"
  line
  echo

  if [[ -s "$CUSTOM_FILE" ]]; then
    echo "File: $CUSTOM_FILE"
    echo
    wc -l "$CUSTOM_FILE"
    echo
    nl -ba "$CUSTOM_FILE" | head -80
  else
    echo "No IP list saved yet."
  fi

  echo
  pause
}

paste_custom_ips() {
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

run_exact_scan() {
  title
  echo -e "${CYAN}Run Exact Config Scan${NC}"
  line
  echo

  local xray_bin
  xray_bin="$(find_xray)"

  if [[ -z "$xray_bin" ]]; then
    echo -e "${YELLOW}xray binary not found.${NC}"
    echo
    if install_xray_for_scanner; then
      xray_bin="$(find_xray)"
    fi

    if [[ -z "$xray_bin" ]]; then
      echo -e "${RED}Xray is still not available.${NC}"
      pause
      return
    fi
  fi

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

  local ip_count
  ip_count="$(wc -l < "$CUSTOM_FILE" | tr -d ' ')"

  echo "Xray: $xray_bin"
  echo "IPs loaded: $ip_count"
  echo

  read -r -p "How many IPs to test? [100, 0 = all]: " limit
  limit="${limit:-100}"

  read -r -p "Parallel workers for delay [5]: " workers
  workers="${workers:-5}"

  read -r -p "Delay test URL [$DEFAULT_DELAY_URL]: " delay_url
  delay_url="${delay_url:-$DEFAULT_DELAY_URL}"

  echo
  read -r -p "Run speed test after delay scan? [y/N]: " run_speed

  speed_url=""
  speed_limit="20"
  speed_workers="3"

  if [[ "$run_speed" =~ ^[yY] ]]; then
    read -r -p "Speed test URL [$DEFAULT_SPEED_URL]: " speed_url
    speed_url="${speed_url:-$DEFAULT_SPEED_URL}"

    read -r -p "How many best delay IPs to speed test? [20]: " speed_limit
    speed_limit="${speed_limit:-20}"

    read -r -p "Parallel workers for speed [3]: " speed_workers
    speed_workers="${speed_workers:-3}"
  fi

  echo
  echo "Start scan?"
  read -r -p "[y/N]: " ok
  case "$ok" in
    y|Y|yes|YES) ;;
    *) return ;;
  esac

  python3 - "$xray_bin" "$PROFILE_JSON" "$CUSTOM_FILE" "$DELAY_CSV" "$DELAY_BEST_TXT" "$DELAY_BEST_COMMA" "$SPEED_CSV" "$SPEED_BEST_TXT" "$SPEED_BEST_COMMA" "$limit" "$workers" "$delay_url" "$speed_url" "$speed_limit" "$speed_workers" <<'PY'
import sys, json, pathlib, urllib.parse, subprocess, tempfile, time, socket, concurrent.futures, csv

xray_bin = sys.argv[1]
profile_file = pathlib.Path(sys.argv[2])
ip_file = pathlib.Path(sys.argv[3])
delay_csv = pathlib.Path(sys.argv[4])
delay_best_txt = pathlib.Path(sys.argv[5])
delay_best_comma = pathlib.Path(sys.argv[6])
speed_csv = pathlib.Path(sys.argv[7])
speed_best_txt = pathlib.Path(sys.argv[8])
speed_best_comma = pathlib.Path(sys.argv[9])
limit = int(sys.argv[10])
workers = int(sys.argv[11])
delay_url = sys.argv[12]
speed_url = sys.argv[13]
speed_limit = int(sys.argv[14]) if sys.argv[14] else 20
speed_workers = int(sys.argv[15]) if sys.argv[15] else 3

profile = json.loads(profile_file.read_text())
raw = profile["raw"]

u = urllib.parse.urlparse(raw)
q = urllib.parse.parse_qs(u.query)

def one(k, default=""):
    vals = q.get(k, [])
    return vals[0] if vals else default

uuid = profile.get("uuid") or u.username
port = int(profile.get("port") or u.port or 443)
network = profile.get("network") or one("type", "xhttp")
security = profile.get("security") or one("security", "tls")
sni = profile.get("sni") or one("sni", "") or profile.get("host")
host = profile.get("host") or one("host", "") or sni
path = profile.get("path") or one("path", "/")
mode = profile.get("mode") or one("mode", "auto")
fp = profile.get("fingerprint") or one("fp", "chrome")
alpn_raw = profile.get("alpn") or one("alpn", "")
alpn = [x for x in alpn_raw.replace("|", ",").split(",") if x]

extra_headers = {}
extra_raw = one("extra", "")
if extra_raw:
    try:
        extra = json.loads(extra_raw)
        if isinstance(extra, dict):
            extra_headers = extra.get("headers", {}) or {}
    except Exception:
        pass

if not path.startswith("/"):
    path = "/" + path

ips = [x.strip() for x in ip_file.read_text().splitlines() if x.strip()]
if limit > 0:
    ips = ips[:limit]

def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

def build_config(ip, socks_port):
    outbound = {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": ip,
                "port": port,
                "users": [{"id": uuid, "encryption": "none"}]
            }]
        },
        "streamSettings": {
            "network": network,
            "security": security
        }
    }

    if security == "tls":
        outbound["streamSettings"]["tlsSettings"] = {
            "serverName": sni,
            "fingerprint": fp,
            "allowInsecure": False
        }
        if alpn:
            outbound["streamSettings"]["tlsSettings"]["alpn"] = alpn

    if network == "xhttp":
        outbound["streamSettings"]["xhttpSettings"] = {
            "host": host,
            "path": path,
            "mode": mode
        }
        if extra_headers:
            outbound["streamSettings"]["xhttpSettings"]["headers"] = extra_headers

    elif network == "ws":
        outbound["streamSettings"]["wsSettings"] = {
            "host": host,
            "path": path,
            "headers": extra_headers
        }

    return {
        "log": {"loglevel": "error"},
        "inbounds": [{
            "tag": "socks",
            "listen": "127.0.0.1",
            "port": socks_port,
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": True}
        }],
        "outbounds": [
            outbound,
            {"tag": "direct", "protocol": "freedom"},
            {"tag": "block", "protocol": "blackhole"}
        ]
    }

def curl_socks(socks_port, url, max_time):
    fmt = "code=%{http_code} connect=%{time_connect} start=%{time_starttransfer} total=%{time_total} size=%{size_download} speed=%{speed_download}"
    cmd = [
        "curl",
        "-sS",
        "-o", "/dev/null",
        "--socks5-hostname", f"127.0.0.1:{socks_port}",
        "--connect-timeout", "5",
        "--max-time", str(max_time),
        "-w", fmt,
        url
    ]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    data = {"code": "000", "connect": "0", "start": "0", "total": "0", "size": "0", "speed": "0", "error": (p.stderr or "")[:180]}
    for part in (p.stdout or "").split():
        if "=" in part:
            k, v = part.split("=", 1)
            data[k] = v
    return data

def run_with_xray(ip, url, max_time):
    socks_port = free_port()
    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix="viptrue-xray-"))
    conf = tmpdir / "config.json"
    conf.write_text(json.dumps(build_config(ip, socks_port), indent=2))

    proc = None
    try:
        proc = subprocess.Popen(
            [xray_bin, "run", "-c", str(conf)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True
        )
        time.sleep(0.8)

        if proc.poll() is not None:
            err = proc.stderr.read() if proc.stderr else ""
            return {"code": "000", "connect": "0", "start": "0", "total": "0", "size": "0", "speed": "0", "error": ("xray_exit " + err[:160])}

        return curl_socks(socks_port, url, max_time)

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

def fnum(x):
    try:
        return float(x)
    except Exception:
        return 999999

def speednum(r):
    try:
        return float(r.get("speed", "0"))
    except Exception:
        return 0.0

def delay_test_ip(ip):
    d = run_with_xray(ip, delay_url, 15)
    total = float(d.get("total", "0") or 0)
    code = d.get("code", "000")
    ok = "1" if code not in ("000", "") and total > 0 else "0"
    return {
        "ip": ip,
        "ok": ok,
        "code": code,
        "connect": d.get("connect", "0"),
        "start": d.get("start", "0"),
        "total": d.get("total", "0"),
        "size": d.get("size", "0"),
        "speed": d.get("speed", "0"),
        "error": d.get("error", "")[:180]
    }

print("Exact config scan:")
print(f"  Port:    {port}")
print(f"  Network: {network}")
print(f"  SNI:     {sni}")
print(f"  Host:    {host}")
print(f"  Path:    {path}")
print(f"  ALPN:    {','.join(alpn) if alpn else '-'}")
print(f"  Delay:   {delay_url}")
print(f"  IPs:     {len(ips)}")
print(f"  Workers: {workers}")
print()

results = []
done = 0

with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
    futs = [ex.submit(delay_test_ip, ip) for ip in ips]
    for fut in concurrent.futures.as_completed(futs):
        r = fut.result()
        results.append(r)
        done += 1
        if done % 10 == 0 or done == len(ips):
            print(f"Delay progress: {done}/{len(ips)}", flush=True)

results.sort(key=lambda r: (r.get("ok") != "1", fnum(r.get("total")), fnum(r.get("start"))))

with delay_csv.open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["ip", "ok", "code", "connect", "start", "total", "size", "speed", "error"])
    w.writeheader()
    for r in results:
        w.writerow({k: r.get(k, "") for k in w.fieldnames})

alive = [r for r in results if r.get("ok") == "1"]
delay_best_txt.write_text("\n".join(r["ip"] for r in alive[:30]) + ("\n" if alive else ""))
delay_best_comma.write_text(",".join(r["ip"] for r in alive[:30]) + ("\n" if alive else ""))

print()
print(f"Alive IPs: {len(alive)}")
print(f"Delay CSV: {delay_csv}")
print(f"Delay Best: {delay_best_txt}")
print()
print("Top delay results:")
for r in alive[:15]:
    print(f'{r["ip"]:15} code={r["code"]:>3} total={r["total"]} start={r["start"]}')

if speed_url and alive:
    print()
    print("Running speed test through real Xray config...")
    print(f"  Speed URL: {speed_url}")
    print(f"  IPs:       {min(speed_limit, len(alive))}")
    print(f"  Workers:   {speed_workers}")
    print()

    speed_ips = [r["ip"] for r in alive[:speed_limit]]

    def speed_test_ip(ip):
        d = run_with_xray(ip, speed_url, 35)
        sp = speednum(d)
        mbps = sp * 8 / 1000 / 1000
        code = d.get("code", "000")
        ok = "1" if code not in ("000", "") and sp > 0 else "0"
        return {
            "ip": ip,
            "ok": ok,
            "code": code,
            "connect": d.get("connect", "0"),
            "start": d.get("start", "0"),
            "total": d.get("total", "0"),
            "size": d.get("size", "0"),
            "speed": d.get("speed", "0"),
            "mbps": f"{mbps:.3f}",
            "error": d.get("error", "")[:180]
        }

    speed_results = []
    done2 = 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=speed_workers) as ex:
        futs = [ex.submit(speed_test_ip, ip) for ip in speed_ips]
        for fut in concurrent.futures.as_completed(futs):
            r = fut.result()
            speed_results.append(r)
            done2 += 1
            print(f"Speed progress: {done2}/{len(speed_ips)}", flush=True)

    speed_results.sort(key=lambda r: (r.get("ok") != "1", -speednum(r), fnum(r.get("total"))))

    with speed_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["ip", "ok", "code", "connect", "start", "total", "size", "speed", "mbps", "error"])
        w.writeheader()
        for r in speed_results:
            w.writerow({k: r.get(k, "") for k in w.fieldnames})

    speed_alive = [r for r in speed_results if r.get("ok") == "1"]
    speed_best_txt.write_text("\n".join(r["ip"] for r in speed_alive[:30]) + ("\n" if speed_alive else ""))
    speed_best_comma.write_text(",".join(r["ip"] for r in speed_alive[:30]) + ("\n" if speed_alive else ""))

    print()
    print(f"Speed CSV: {speed_csv}")
    print(f"Speed Best: {speed_best_txt}")
    print()
    print("Top speed results:")
    for r in speed_alive[:15]:
        print(f'{r["ip"]:15} code={r["code"]:>3} speed={r["mbps"]} Mbps total={r["total"]} size={r["size"]}')

    print()
    print("Final recommended order is based on SPEED.")
else:
    print()
    print("Speed test skipped. Final order is based on DELAY.")
PY

  echo
  pause
}

show_export_results() {
  title
  echo -e "${CYAN}Show / Export Results${NC}"
  line
  echo

  echo "Data directory:"
  echo "  $DATA_DIR"
  echo

  if [[ -s "$SPEED_BEST_TXT" ]]; then
    echo "Best IPs by SPEED:"
    nl -ba "$SPEED_BEST_TXT" | head -30
    echo
    echo "PasarGuard comma output by SPEED:"
    cat "$SPEED_BEST_COMMA"
  elif [[ -s "$DELAY_BEST_TXT" ]]; then
    echo "Best IPs by DELAY:"
    nl -ba "$DELAY_BEST_TXT" | head -30
    echo
    echo "PasarGuard comma output by DELAY:"
    cat "$DELAY_BEST_COMMA"
  else
    echo "No results yet."
  fi

  echo
  pause
}

reset_data() {
  title
  echo -e "${CYAN}Reset Scanner Data${NC}"
  line
  echo
  echo "This will remove saved profile, IP list, and scan results:"
  echo "  $DATA_DIR"
  echo
  read -r -p "Continue? [y/N]: " ok
  case "$ok" in
    y|Y|yes|YES)
      rm -f "$DATA_DIR"/*.json "$DATA_DIR"/*.txt "$DATA_DIR"/*.csv "$DATA_DIR"/*.tmp
      echo -e "${GREEN}Scanner data reset.${NC}"
      ;;
    *) ;;
  esac
  pause
}

while true; do
  title
  echo -e "${CYAN}Cloudflare Clean IP Scanner${NC}"
  line
  echo "1. Paste / Update VLESS Config"
  echo "2. Paste / Update Custom IP List"
  echo "3. Run Exact Config Scan"
  echo "4. Show / Export Results"
  echo "5. Reset Scanner Data"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-5]: " choice

  case "$choice" in
    1) paste_config_profile ;;
    2) paste_custom_ips ;;
    3) run_exact_scan ;;
    4) show_export_results ;;
    5) reset_data ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
