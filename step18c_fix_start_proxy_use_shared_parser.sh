#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

helper = Path("modules/utility/link_proxy_tools.py")
text = helper.read_text()

# Add generate command function if missing
if "def cmd_generate(args):" not in text:
    insert_before = "\ndef main():\n"
    generate_func = r'''
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

    # For real service logs, use info.
    config["log"]["level"] = args.log_level

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(config, indent=2), encoding="utf-8")

    outbound = config["outbounds"][0]
    print(f"Proxy config generated for {outbound.get('type')} server: {outbound.get('server')}:{outbound.get('server_port')}")
    return 0

'''
    text = text.replace(insert_before, generate_func + insert_before)

# Add generate parser if missing
if 'sub.add_parser("generate")' not in text:
    old = '''    p = sub.add_parser("select")
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
'''
    new = '''    p = sub.add_parser("select")
    p.add_argument("--raw", required=True)
    p.add_argument("--sub", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--sing-box", required=True)
    p.add_argument("--test-count", type=int, default=50)
    p.add_argument("--timeout", type=int, default=9)

    g = sub.add_parser("generate")
    g.add_argument("--link", required=True)
    g.add_argument("--out", required=True)
    g.add_argument("--listen-port", type=int, default=19080)
    g.add_argument("--log-level", default="info")

    args = parser.parse_args()

    if args.command == "select":
        return cmd_select(args)

    if args.command == "generate":
        return cmd_generate(args)

    return 1
'''
    if old not in text:
        raise SystemExit("Could not patch argparse block in link_proxy_tools.py")
    text = text.replace(old, new)

helper.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path
import re

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

if 'LINK_PROXY_TOOLS=' not in text:
    text = text.replace(
        'PROXY_RUN_BIN="/usr/local/bin/viptrue-proxy-run"\n',
        'PROXY_RUN_BIN="/usr/local/bin/viptrue-proxy-run"\n'
        'LINK_PROXY_TOOLS="$BASE_DIR/modules/utility/link_proxy_tools.py"\n'
    )

new_func = r'''generate_proxy_config_from_active_link() {
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

  if [[ -z "${link// /}" ]]; then
    echo -e "${RED}Active link is empty.${NC}"
    return 1
  fi

  case "$link" in
    ss://*|vless://*|trojan://*|vmess://*) ;;
    *)
      echo -e "${RED}Unsupported active link for Proxy Mode.${NC}"
      echo "Active type: ${link_type:-UNKNOWN}"
      echo "Supported:"
      echo "- ss://"
      echo "- vless://"
      echo "- trojan://"
      echo "- vmess://"
      echo
      echo "Hint: select another outbound from Config Links."
      return 1
      ;;
  esac

  python3 "$LINK_PROXY_TOOLS" generate \
    --link "$link" \
    --out "$PROXY_CONFIG_FILE" \
    --listen-port 19080 \
    --log-level info
}
'''

pattern = r'generate_proxy_config_from_active_link\(\)\s*\{.*?\n\}\n(?=\n[a-zA-Z0-9_]+\(\)\s*\{)'
text, count = re.subn(pattern, new_func + "\n", text, count=1, flags=re.S)

if count == 0:
    raise SystemExit("Could not replace generate_proxy_config_from_active_link function")

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
chmod +x modules/utility/link_proxy_tools.py

bash -n modules/utility/02-temp-tunnel.sh
python3 -m py_compile modules/utility/link_proxy_tools.py

echo
echo "✅ Step 18-C completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Use shared proxy parser for start proxy mode' && git push"
