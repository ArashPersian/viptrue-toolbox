#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

func = r'''write_proxy_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF2
[Unit]
Description=VIPTrue Temporary Proxy for Installations
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${TUNNEL_DIR}
ExecStart=${SING_BOX_BIN} run -c ${PROXY_CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
UnsetEnvironment=http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
}
'''

if "write_proxy_systemd_service()" not in text:
    marker = "write_proxy_helpers() {"
    if marker not in text:
        raise SystemExit("Could not find write_proxy_helpers() marker.")
    text = text.replace(marker, func + "\n" + marker)
else:
    print("write_proxy_systemd_service() already exists.")

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh
python3 -m py_compile modules/utility/link_proxy_tools.py

echo
echo "✅ Step 18-H completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Restore proxy systemd service writer' && git push"
