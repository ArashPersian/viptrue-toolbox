#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

if 'LINK_PROXY_TOOLS=' not in text:
    text = text.replace(
        'PROXY_RUN_BIN="/usr/local/bin/viptrue-proxy-run"\n',
        'PROXY_RUN_BIN="/usr/local/bin/viptrue-proxy-run"\n'
        'LINK_PROXY_TOOLS="$BASE_DIR/modules/utility/link_proxy_tools.py"\n'
    )

def replace_bash_function(src, func_name, new_func):
    marker = f"{func_name}()"
    start = src.find(marker)
    if start == -1:
        raise SystemExit(f"Function not found: {func_name}")

    brace_start = src.find("{", start)
    if brace_start == -1:
        raise SystemExit(f"Opening brace not found: {func_name}")

    depth = 0
    i = brace_start
    in_single = False
    in_double = False
    escape = False

    while i < len(src):
        ch = src[i]

        if escape:
            escape = False
            i += 1
            continue

        if ch == "\\":
            escape = True
            i += 1
            continue

        if ch == "'" and not in_double:
            in_single = not in_single
            i += 1
            continue

        if ch == '"' and not in_single:
            in_double = not in_double
            i += 1
            continue

        if not in_single and not in_double:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    while end < len(src) and src[end] in "\n\r":
                        end += 1
                    return src[:start] + new_func.rstrip() + "\n\n" + src[end:]

        i += 1

    raise SystemExit(f"Could not find function end: {func_name}")

new_generate = r'''generate_proxy_config_from_active_link() {
  ensure_dirs

  if [[ ! -f "$ACTIVE_LINK_FILE" ]]; then
    echo -e "${RED}No active config link found.${NC}"
    return 1
  fi

  if [[ ! -f "$LINK_PROXY_TOOLS" ]]; then
    echo -e "${RED}Helper not found:${NC}"
    echo "$LINK_PROXY_TOOLS"
    return 1
  fi

  local link_type link
  link_type="$(get_active_link_type || true)"
  link="$(get_active_link_value || true)"

  link="${link//$'\r'/}"
  link="${link//$'\n'/}"
  link="$(printf '%s' "$link" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

  if [[ -z "${link// /}" ]]; then
    echo -e "${RED}Active link is empty.${NC}"
    echo
    echo "Debug active file:"
    cat -A "$ACTIVE_LINK_FILE" 2>/dev/null || true
    return 1
  fi

  case "$link" in
    ss://*|vless://*|trojan://*|vmess://*) ;;
    *)
      echo -e "${RED}Unsupported active link for Proxy Mode.${NC}"
      echo "Active type: ${link_type:-UNKNOWN}"
      echo
      echo "Detected link:"
      printf '%s\n' "$link" | cut -c1-160
      echo
      echo "Debug active file:"
      cat -A "$ACTIVE_LINK_FILE" 2>/dev/null || true
      echo
      echo "Supported:"
      echo "- ss://"
      echo "- vless://"
      echo "- trojan://"
      echo "- vmess://"
      return 1
      ;;
  esac

  python3 "$LINK_PROXY_TOOLS" generate \
    --link "$link" \
    --out "$PROXY_CONFIG_FILE" \
    --listen-port 19080 \
    --log-level info
}'''

new_select = r'''select_active_outbound() {
  title
  echo -e "${CYAN}Select Active Outbound - Auto Real Delay Sort${NC}"
  line
  echo

  ensure_root || return
  ensure_dirs

  if [[ ! -x "$SING_BOX_BIN" ]]; then
    echo -e "${RED}sing-box is not installed.${NC}"
    echo "Run Install / Update sing-box first."
    pause
    return
  fi

  if [[ ! -f "$LINK_PROXY_TOOLS" ]]; then
    echo -e "${RED}Helper not found:${NC}"
    echo "$LINK_PROXY_TOOLS"
    pause
    return
  fi

  local select_file
  select_file="$STATE_DIR/selectable-outbounds.tsv"

  echo "This will test configs with real HTTP delay through sing-box local proxy,"
  echo "then sort them like v2rayN real delay results."
  echo
  echo "Recommended:"
  echo "- 30 or 50 for fast test"
  echo "- 0 to test ALL configs"
  echo
  read -r -p "How many configs should be tested? [default: 50, 0 = all]: " test_count
  test_count="${test_count:-50}"

  if ! [[ "$test_count" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Invalid number.${NC}"
    pause
    return
  fi

  echo
  python3 "$LINK_PROXY_TOOLS" select \
    --raw "$RAW_LINKS_FILE" \
    --sub "$SUB_OUTBOUNDS_FILE" \
    --out "$select_file" \
    --sing-box "$SING_BOX_BIN" \
    --test-count "$test_count" \
    --timeout 9

  if [[ ! -s "$select_file" ]]; then
    echo -e "${YELLOW}No outbound found.${NC}"
    echo "Add a single config or update subscriptions first."
    pause
    return
  fi

  read -r -p "Select number from sorted list: " selected

  if ! [[ "$selected" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Invalid number.${NC}"
    pause
    return
  fi

  echo
  if ! python3 "$LINK_PROXY_TOOLS" activate \
    --select-file "$select_file" \
    --number "$selected" \
    --active-file "$ACTIVE_LINK_FILE"; then
    echo -e "${RED}Failed to activate selected outbound.${NC}"
    pause
    return
  fi

  echo
  echo -e "${GREEN}Active file saved correctly.${NC}"
  echo
  echo "Now check active file if needed:"
  echo "cat -A $ACTIVE_LINK_FILE"
  echo
  echo "Then start:"
  echo "Proxy Mode > Start Proxy Mode"
  echo

  pause
}'''

text = replace_bash_function(text, "generate_proxy_config_from_active_link", new_generate)
text = replace_bash_function(text, "select_active_outbound", new_select)

path.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

helper = Path("modules/utility/link_proxy_tools.py")
text = helper.read_text()

if "def cmd_generate(args):" not in text:
    text = text.replace(
        "\ndef main():\n",
        r'''
def cmd_generate(args):
    link = args.link.strip()

    if not link:
        print("Empty link", file=sys.stderr)
        return 1

    try:
        config = make_proxy_config(link, args.listen_port)
    except Exception as e:
        print(f"Failed to generate proxy config: {e}", file=sys.stderr)
        return 1

    config["log"]["level"] = args.log_level

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(config, indent=2), encoding="utf-8")

    outbound = config["outbounds"][0]
    print(f"Proxy config generated for {outbound.get('type')} server: {outbound.get('server')}:{outbound.get('server_port')}")
    return 0


def cmd_activate(args):
    select_file = Path(args.select_file)
    active_file = Path(args.active_file)
    selected = str(args.number)

    if not select_file.exists():
        print("Selection file not found", file=sys.stderr)
        return 1

    row = None
    for line in select_file.read_text(errors="replace").splitlines():
        parts = line.split("\t")
        if parts and parts[0] == selected:
            row = parts
            break

    if row is None:
        print("Selected item not found", file=sys.stderr)
        return 1

    while len(row) < 9:
        row.append("")

    n, item_id, typ, source, sub_id, sub_name, link, delay_ms, test_status = row[:9]

    if not link.startswith(("ss://", "vless://", "trojan://", "vmess://")):
        print("Selected row has invalid link field", file=sys.stderr)
        print(f"link={link}", file=sys.stderr)
        return 1

    active_file.parent.mkdir(parents=True, exist_ok=True)

    lines = [
        f"id={item_id}",
        f"type={typ}",
        f"source={source}",
    ]

    if sub_id:
        lines.append(f"sub_id={sub_id}")

    if sub_name:
        lines.append(f"sub_name={sub_name}")

    if delay_ms:
        lines.append(f"delay_ms={delay_ms}")

    if test_status:
        lines.append(f"test_status={test_status}")

    lines.append(f"link={link}")

    active_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(active_file, 0o600)

    print("Active outbound selected.")
    print(f"ID: {item_id}")
    print(f"Type: {typ}")
    print(f"Source: {source}")
    if delay_ms:
        print(f"Real delay: {delay_ms} ms")
    else:
        print(f"Test status: {test_status or 'N/A'}")

    return 0

''' + "\ndef main():\n"
    )

if 'sub.add_parser("generate")' not in text:
    old = '''    args = parser.parse_args()

    if args.command == "select":
        return cmd_select(args)

    return 1
'''
    new = '''    g = sub.add_parser("generate")
    g.add_argument("--link", required=True)
    g.add_argument("--out", required=True)
    g.add_argument("--listen-port", type=int, default=19080)
    g.add_argument("--log-level", default="info")

    a = sub.add_parser("activate")
    a.add_argument("--select-file", required=True)
    a.add_argument("--number", required=True)
    a.add_argument("--active-file", required=True)

    args = parser.parse_args()

    if args.command == "select":
        return cmd_select(args)

    if args.command == "generate":
        return cmd_generate(args)

    if args.command == "activate":
        return cmd_activate(args)

    return 1
'''
    if old not in text:
        raise SystemExit("Could not patch helper argparse block. Send: tail -n 80 modules/utility/link_proxy_tools.py")
    text = text.replace(old, new)

helper.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
chmod +x modules/utility/link_proxy_tools.py

bash -n modules/utility/02-temp-tunnel.sh
python3 -m py_compile modules/utility/link_proxy_tools.py

echo
echo "✅ Step 18-F completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Force fix proxy active selection and shared parser' && git push"
