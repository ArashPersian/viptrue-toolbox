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
            "strict_route": True,
            "stack": "mixed"
        }'''

new_inbound = '''        {
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

if old_inbound not in text:
    raise SystemExit("Expected TUN inbound block not found. File may have changed.")

text = text.replace(old_inbound, new_inbound)

old_test = '''echo -e "${YELLOW}Testing normal curl through TUN:${NC}"
        local direct_or_tun_ip
        direct_or_tun_ip="$(run_without_proxy_env curl -4fsS --connect-timeout 5 --max-time 15 https://api.ipify.org 2>/dev/null || true)"
        echo "${direct_or_tun_ip:-FAILED}"
        echo'''

new_test = '''echo -e "${YELLOW}Routing while TUN is active:${NC}"
        ip route 2>/dev/null | sed -n '1,80p' || true
        echo
        ip rule 2>/dev/null || true
        echo

        echo -e "${YELLOW}Testing normal curl through TUN:${NC}"
        local direct_or_tun_ip
        direct_or_tun_ip="$(run_without_proxy_env curl -4fsS --connect-timeout 8 --max-time 25 https://api.ipify.org 2>/dev/null || true)"
        echo "${direct_or_tun_ip:-FAILED}"
        echo'''

if old_test not in text:
    raise SystemExit("Expected TUN curl test block not found. File may have changed.")

text = text.replace(old_test, new_test)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12G-I completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Improve TUN mode with gvisor auto redirect' && git push"
