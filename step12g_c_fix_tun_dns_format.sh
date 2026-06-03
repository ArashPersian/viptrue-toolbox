#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

old = '''    "dns": {
        "servers": [
            {
                "tag": "cf",
                "address": "1.1.1.1",
                "detour": "install-out"
            },
            {
                "tag": "local",
                "address": "local"
            }
        ],
        "final": "cf"
    },'''

new = '''    "dns": {
        "servers": [
            {
                "type": "udp",
                "tag": "cf",
                "server": "1.1.1.1",
                "detour": "install-out"
            },
            {
                "type": "local",
                "tag": "local"
            }
        ],
        "final": "cf"
    },'''

if old not in text:
    raise SystemExit("Old legacy DNS block not found. File may have changed.")

text = text.replace(old, new)
path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12G-C completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Fix sing-box TUN DNS server format' && git push"
