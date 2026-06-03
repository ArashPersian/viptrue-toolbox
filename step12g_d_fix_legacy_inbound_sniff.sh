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
            "stack": "mixed",
            "sniff": True
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
            "stack": "mixed"
        }'''

if old_inbound not in text:
    raise SystemExit("Old TUN inbound block with sniff not found. File may have changed.")

text = text.replace(old_inbound, new_inbound)

old_route = '''    "route": {
        "auto_detect_interface": True,
        "rules": direct_rules,
        "final": "install-out"
    }'''

new_route = '''    "route": {
        "auto_detect_interface": True,
        "rules": [
            {
                "action": "sniff"
            }
        ] + direct_rules,
        "final": "install-out"
    }'''

if old_route not in text:
    raise SystemExit("Old route block not found. File may have changed.")

text = text.replace(old_route, new_route)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12G-D completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Fix sing-box legacy inbound sniff in TUN mode' && git push"
