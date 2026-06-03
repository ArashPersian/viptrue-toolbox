#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

# Add subscription files variables
if 'SUB_LINKS_FILE=' not in text:
    text = text.replace(
        'RAW_LINKS_FILE="$OUTBOUNDS_DIR/single-links.txt"\n',
        'RAW_LINKS_FILE="$OUTBOUNDS_DIR/single-links.txt"\n'
        'SUB_LINKS_FILE="$SUBS_DIR/subscriptions.txt"\n'
        'SUB_OUTBOUNDS_FILE="$OUTBOUNDS_DIR/subscription-outbounds.txt"\n'
    )

# Replace show_saved_links
start = text.index("show_saved_links() {")
end = text.index("\ngenerate_proxy_config_from_active_link() {", start)

new_show = r'''show_saved_links() {
  title
  echo -e "${CYAN}Saved Config Links / Subscriptions${NC}"
  line
  echo

  ensure_dirs

  python3 - "$RAW_LINKS_FILE" "$SUB_LINKS_FILE" "$SUB_OUTBOUNDS_FILE" <<'PY2'
import sys, re
from pathlib import Path
from urllib.parse import urlparse, unquote

raw_file = Path(sys.argv[1])
subs_file = Path(sys.argv[2])
sub_outbounds_file = Path(sys.argv[3])

def mask_link(link: str) -> str:
    link = re.sub(r'(://)[^:@/]+:[^@/]+@', r'\1***:***@', link)
    link = re.sub(r'(password=)[^&]+', r'\1***', link, flags=re.I)
    link = re.sub(r'(uuid=)[^&]+', r'\1***', link, flags=re.I)
    link = re.sub(r'(id=)[^&]+', r'\1***', link, flags=re.I)
    if link.startswith("vless://") or link.startswith("trojan://"):
        try:
            p = urlparse(link)
            safe = link.replace(p.username or "", "***", 1) if p.username else link
            return safe
        except Exception:
            return link
    return link

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

print("Single links:")
raw = parse_blocks(raw_file)
if not raw:
    print("  None")
else:
    for b in raw:
        print(f"  [{b.get('id','')}] type={b.get('type','unknown')}")
        print(f"    link={mask_link(b.get('link',''))}")

print()
print("Subscriptions:")
subs = parse_blocks(subs_file)
if not subs:
    print("  None")
else:
    for b in subs:
        print(f"  [{b.get('id','')}] name={b.get('name','')}")
        print(f"    url={mask_link(b.get('url',''))}")

print()
print("Subscription outbounds:")
outs = parse_blocks(sub_outbounds_file)
if not outs:
    print("  None")
else:
    for b in outs[:80]:
        print(f"  [{b.get('id','')}] type={b.get('type','unknown')} source={b.get('source','')}")
        print(f"    link={mask_link(b.get('link',''))}")
    if len(outs) > 80:
        print(f"  ... and {len(outs)-80} more")
PY2

  echo
  echo -e "${YELLOW}Active link:${NC}"
  if [[ -f "$ACTIVE_LINK_FILE" ]]; then
    grep -E '^(id|type|source|sub_id)=' "$ACTIVE_LINK_FILE" || true
    grep '^link=' "$ACTIVE_LINK_FILE" | sed -E \
      -e 's#(://)[^:@/]+:[^@/]+@#\1***:***@#g' \
      -e 's#(password=)[^&]+#\1***#Ig' \
      -e 's#(uuid=)[^&]+#\1***#Ig' \
      -e 's#(id=)[^&]+#\1***#Ig' || true
  else
    echo "None"
  fi
  echo

  pause
}

add_subscription_link() {
  title
  echo -e "${CYAN}Add Subscription Link${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  echo "Paste your subscription URL."
  echo "Supported extracted config types:"
  echo "- ss://"
  echo "- vless://"
  echo "- trojan://"
  echo "- vmess://"
  echo
  read -r -p "Subscription name, example Backup-Sub: " sub_name
  read -r -p "Subscription URL: " sub_url

  if [[ -z "${sub_url// /}" ]]; then
    echo -e "${RED}Empty subscription URL.${NC}"
    pause
    return
  fi

  local id
  id="$(date +%Y%m%d-%H%M%S)"

  {
    echo "[$id]"
    echo "name=${sub_name:-Subscription-$id}"
    echo "url=$sub_url"
    echo
  } >> "$SUB_LINKS_FILE"

  chmod 600 "$SUB_LINKS_FILE" 2>/dev/null || true

  echo
  echo -e "${GREEN}Subscription saved.${NC}"
  echo "ID: $id"
  echo
  echo "Now run:"
  echo "Config Links > Update subscriptions"
  echo

  pause
}

update_subscriptions() {
  title
  echo -e "${CYAN}Update Subscriptions${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  if [[ ! -f "$SUB_LINKS_FILE" ]]; then
    echo -e "${YELLOW}No subscription saved yet.${NC}"
    pause
    return
  fi

  apt-get update >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates >/dev/null 2>&1 || true

  local tmp_out
  tmp_out="$(mktemp)"
  : > "$tmp_out"

  python3 - "$SUB_LINKS_FILE" <<'PY2' | while IFS=$'\t' read -r sub_id sub_name sub_url; do
from pathlib import Path
import sys

path = Path(sys.argv[1])
current = {}
blocks = []

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

for b in blocks:
    print(f"{b.get('id','')}\t{b.get('name','')}\t{b.get('url','')}")
PY2
    [[ -n "${sub_id:-}" && -n "${sub_url:-}" ]] || continue

    echo
    echo -e "${YELLOW}Updating:${NC} $sub_name [$sub_id]"

    local tmp_body
    tmp_body="$(mktemp)"

    if curl -fsSL --connect-timeout 15 --max-time 45 "$sub_url" -o "$tmp_body"; then
      python3 - "$tmp_body" "$sub_id" "$sub_name" >> "$tmp_out" <<'PY3'
import sys, base64, re
from pathlib import Path

body_path = Path(sys.argv[1])
sub_id = sys.argv[2]
sub_name = sys.argv[3]

raw = body_path.read_text(errors="replace").strip()

def b64decode_padded(data: str):
    data = data.strip()
    data = re.sub(r'\s+', '', data)
    data = data.replace("-", "+").replace("_", "/")
    data += "=" * (-len(data) % 4)
    return base64.b64decode(data).decode("utf-8", errors="replace")

def detect_type(link):
    if link.startswith("ss://"):
        return "shadowsocks"
    if link.startswith("vless://"):
        return "vless"
    if link.startswith("trojan://"):
        return "trojan"
    if link.startswith("vmess://"):
        return "vmess"
    return "unknown"

def extract_links(text):
    supported = ("ss://", "vless://", "trojan://", "vmess://")
    found = []

    for line in text.replace("\r", "\n").split("\n"):
        line = line.strip()
        if not line:
            continue
        if line.startswith(supported):
            found.append(line)

    if found:
        return found

    # Try extracting links from mixed text/YAML-like content
    pattern = r'(ss://[^\s\'"]+|vless://[^\s\'"]+|trojan://[^\s\'"]+|vmess://[^\s\'"]+)'
    return re.findall(pattern, text)

candidates = [raw]

try:
    decoded = b64decode_padded(raw)
    candidates.insert(0, decoded)
except Exception:
    pass

links = []
seen = set()

for c in candidates:
    for link in extract_links(c):
        if link not in seen:
            seen.add(link)
            links.append(link)

count = 0
for link in links:
    typ = detect_type(link)
    if typ == "unknown":
        continue
    count += 1
    item_id = f"{sub_id}-{count:04d}"
    print(f"[{item_id}]")
    print("source=subscription")
    print(f"sub_id={sub_id}")
    print(f"sub_name={sub_name}")
    print(f"type={typ}")
    print(f"link={link}")
    print()

print(f"# Imported {count} links from {sub_name} [{sub_id}]", file=sys.stderr)
PY3
    else
      echo -e "${RED}Failed to download subscription:${NC} $sub_name"
    fi

    rm -f "$tmp_body"
  done

  mv "$tmp_out" "$SUB_OUTBOUNDS_FILE"
  chmod 600 "$SUB_OUTBOUNDS_FILE" 2>/dev/null || true

  echo
  echo -e "${GREEN}Subscriptions updated.${NC}"
  echo

  local total
  total="$(grep -c '^\[' "$SUB_OUTBOUNDS_FILE" 2>/dev/null || true)"
  echo "Imported outbounds: ${total:-0}"
  echo

  pause
}

select_active_outbound() {
  title
  echo -e "${CYAN}Select Active Outbound${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  local select_file
  select_file="$STATE_DIR/selectable-outbounds.tsv"

  python3 - "$RAW_LINKS_FILE" "$SUB_OUTBOUNDS_FILE" "$select_file" <<'PY2'
import sys, re
from pathlib import Path
from urllib.parse import urlparse

raw_file = Path(sys.argv[1])
sub_file = Path(sys.argv[2])
select_file = Path(sys.argv[3])

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
    return masked[:160]

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

items = []

for b in parse_blocks(raw_file):
    if b.get("link") and b.get("type"):
        b["source"] = "single"
        items.append(b)

for b in parse_blocks(sub_file):
    if b.get("link") and b.get("type"):
        b["source"] = "subscription"
        items.append(b)

if not items:
    print("NO_ITEMS")
    select_file.write_text("")
    raise SystemExit

lines = []
for i, b in enumerate(items, 1):
    source = b.get("source", "")
    typ = b.get("type", "unknown")
    item_id = b.get("id", "")
    sub_name = b.get("sub_name", "")
    link = b.get("link", "")

    label = f"{i}. [{source}] [{typ}] [{item_id}]"
    if sub_name:
        label += f" {sub_name}"
    print(label)
    print(f"   {mask_link(link)}")
    print()

    lines.append(
        f"{i}\t{b.get('id','')}\t{b.get('type','')}\t{b.get('source','')}\t{b.get('sub_id','')}\t{b.get('sub_name','')}\t{b.get('link','')}"
    )

select_file.write_text("\n".join(lines) + "\n")
PY2

  if [[ ! -s "$select_file" ]]; then
    echo -e "${YELLOW}No outbound found.${NC}"
    echo "Add a single config or update subscriptions first."
    pause
    return
  fi

  read -r -p "Select number: " selected

  if ! [[ "$selected" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Invalid number.${NC}"
    pause
    return
  fi

  local row
  row="$(awk -F'\t' -v n="$selected" '$1 == n {print; exit}' "$select_file" || true)"

  if [[ -z "$row" ]]; then
    echo -e "${RED}Selected item not found.${NC}"
    pause
    return
  fi

  local n id typ source sub_id sub_name link
  IFS=$'\t' read -r n id typ source sub_id sub_name link <<< "$row"

  {
    echo "id=$id"
    echo "type=$typ"
    echo "source=$source"
    [[ -n "$sub_id" ]] && echo "sub_id=$sub_id"
    [[ -n "$sub_name" ]] && echo "sub_name=$sub_name"
    echo "link=$link"
  } > "$ACTIVE_LINK_FILE"

  chmod 600 "$ACTIVE_LINK_FILE" 2>/dev/null || true

  echo
  echo -e "${GREEN}Active outbound selected.${NC}"
  echo "ID: $id"
  echo "Type: $typ"
  echo "Source: $source"
  echo

  pause
}
'''

text = text[:start] + new_show + text[end:]

# Replace config_links_menu
start = text.index("config_links_menu() {")
end = text.index("\nproxy_mode_menu() {", start)

new_menu = r'''config_links_menu() {
  while true; do
    title
    echo -e "${CYAN}Config Links / Subscriptions${NC}"
    line
    echo
    echo "1. Add single config link"
    echo "2. Add subscription link"
    echo "3. Update subscriptions"
    echo "4. Select active outbound"
    echo "5. Show saved links"
    echo "6. Relay test active link"
    echo "0. Back"
    echo
    read -r -p "Enter your choice [0-6]: " choice

    case "$choice" in
      1) add_single_config_link ;;
      2) add_subscription_link ;;
      3) update_subscriptions ;;
      4) select_active_outbound ;;
      5) show_saved_links ;;
      6) relay_test_active_link ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
  done
}
'''

text = text[:start] + new_menu + text[end:]

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 17 completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add subscription import and active outbound selection' && git push"
