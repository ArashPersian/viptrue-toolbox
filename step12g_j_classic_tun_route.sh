#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

old_inbound = '''        {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "viptrue-tun0",
            "address": [
                "172.19.0.1/30"
            ],
            "auto_route": True,
            "auto_redirect": True,
            "strict_route": True,
            "stack": "gvisor",
            "endpoint_independent_nat": True
        }'''

new_inbound = '''        {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "viptrue-tun0",
            "address": [
                "172.19.0.1/30"
            ],
            "auto_route": True,
            "strict_route": True,
            "stack": "gvisor",
            "route_address": [
                "0.0.0.0/1",
                "128.0.0.0/1"
            ]
        }'''

if old_inbound not in text:
    raise SystemExit("Expected TUN inbound block with auto_redirect not found. File may have changed.")

text = text.replace(old_inbound, new_inbound)

# Improve active routing debug: show custom routing tables too.
old_debug = '''echo -e "${YELLOW}Routing while TUN is active:${NC}"
        ip route 2>/dev/null | sed -n '1,80p' || true
        echo
        ip rule 2>/dev/null || true
        echo'''

new_debug = '''echo -e "${YELLOW}Routing while TUN is active:${NC}"
        echo "--- main table ---"
        ip route 2>/dev/null | sed -n '1,120p' || true
        echo
        echo "--- ip rules ---"
        ip rule 2>/dev/null || true
        echo
        echo "--- table 2022 ---"
        ip route show table 2022 2>/dev/null || true
        echo
        echo "--- table 2023 ---"
        ip route show table 2023 2>/dev/null || true
        echo'''

if old_debug not in text:
    raise SystemExit("Expected routing debug block not found. File may have changed.")

text = text.replace(old_debug, new_debug)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12G-J completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Switch TUN mode to classic route mode' && git push"
