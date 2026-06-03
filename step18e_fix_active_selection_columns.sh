#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

old = '''  link="${link//$'\\r'/}"
  link="${link//$'\\n'/}"

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
'''

new = '''  # Normalize active link.
  # Some subscription parsers or terminal copy/paste can leave hidden spaces/CR.
  link="${link//$'\\r'/}"
  link="${link//$'\\n'/}"
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
      echo "Detected link prefix:"
      printf '%s\\n' "$link" | cut -c1-80
      echo
      echo "Debug active file:"
      cat -A "$ACTIVE_LINK_FILE" 2>/dev/null || true
      echo
      echo "Supported:"
      echo "- ss://"
      echo "- vless://"
      echo "- trojan://"
      echo "- vmess://"
      echo
      echo "Hint: go to Config Links and select the outbound again."
      return 1
      ;;
  esac
'''

if old not in text:
    raise SystemExit("Target normalize block not found. Step 18-C may not be applied correctly.")

text = text.replace(old, new)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh
python3 -m py_compile modules/utility/link_proxy_tools.py

echo
echo "✅ Step 18-D completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Fix active link normalization for proxy mode' && git push"
