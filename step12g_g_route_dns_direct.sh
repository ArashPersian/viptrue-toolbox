#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

old_dns = '''    "dns": {
        "servers": [
            {
                "type": "local",
                "tag": "local"
            },
            {
                "type": "udp",
                "tag": "cf",
                "server": "1.1.1.1",
                "detour": "install-out"
            }
        ],
        "final": "cf"
    },'''

new_dns = '''    "dns": {
        "servers": [
            {
                "type": "local",
                "tag": "local"
            }
        ],
        "final": "local"
    },'''

if old_dns not in text:
    raise SystemExit("Expected DNS block not found. File may have changed.")

text = text.replace(old_dns, new_dns)

old_route = '''    "route": {
        "auto_detect_interface": True,
        "default_domain_resolver": {
            "server": "local"
        },
        "rules": [
            {
                "action": "sniff"
            }
        ] + direct_rules,
        "final": "install-out"
    }'''

new_route = '''    "route": {
        "auto_detect_interface": True,
        "default_domain_resolver": {
            "server": "local"
        },
        "rules": [
            {
                "port": 53,
                "outbound": "direct"
            },
            {
                "protocol": "dns",
                "outbound": "direct"
            },
            {
                "action": "sniff"
            }
        ] + direct_rules,
        "final": "install-out"
    }'''

if old_route not in text:
    raise SystemExit("Expected route block not found. File may have changed.")

text = text.replace(old_route, new_route)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12G-G completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Route DNS direct in TUN mode' && git push"
