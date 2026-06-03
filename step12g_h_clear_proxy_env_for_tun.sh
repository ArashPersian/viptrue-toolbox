#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path

path = Path("modules/utility/02-temp-tunnel.sh")
text = path.read_text()

insert_before = '''
show_saved_links() {
'''

helper = r'''
run_without_proxy_env() {
  env \
    -u http_proxy \
    -u https_proxy \
    -u all_proxy \
    -u HTTP_PROXY \
    -u HTTPS_PROXY \
    -u ALL_PROXY \
    "$@"
}

show_proxy_env_warning() {
  local found=0

  for var in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
    if [[ -n "${!var:-}" ]]; then
      if [[ "$found" -eq 0 ]]; then
        echo -e "${YELLOW}Detected proxy environment variables in current shell:${NC}"
        found=1
      fi
      echo "$var=${!var}"
    fi
  done

  if [[ "$found" -eq 1 ]]; then
    echo
    echo -e "${YELLOW}For TUN Mode tests, toolbox will ignore these variables automatically.${NC}"
    echo "You can also clear them manually with:"
    echo "unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
    echo
  fi
}
'''

if "run_without_proxy_env()" not in text:
    text = text.replace(insert_before, helper + insert_before)

# Add warning inside start_tun_mode after Current SSH client IP section
old = '''echo -e "${YELLOW}Current SSH client IP:${NC}"
  get_current_ssh_client_ip || true
  echo

  read -r -p "Start TUN Mode now? [y/N]: " confirm'''

new = '''echo -e "${YELLOW}Current SSH client IP:${NC}"
  get_current_ssh_client_ip || true
  echo

  show_proxy_env_warning

  read -r -p "Start TUN Mode now? [y/N]: " confirm'''

if old in text:
    text = text.replace(old, new)
else:
    print("Warning: TUN start warning insertion point not found.")

# Replace curl test in start_tun_mode
old_curl = '''direct_or_tun_ip="$(curl -4fsS --connect-timeout 5 --max-time 15 https://api.ipify.org 2>/dev/null || true)"'''

new_curl = '''direct_or_tun_ip="$(run_without_proxy_env curl -4fsS --connect-timeout 5 --max-time 15 https://api.ipify.org 2>/dev/null || true)"'''

if old_curl in text:
    text = text.replace(old_curl, new_curl)
else:
    print("Warning: TUN curl test line not found or already replaced.")

# Replace diagnostics curls
text = text.replace(
'''curl -4fsS --connect-timeout 5 --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n '1,8p' || echo "FAILED"''',
'''run_without_proxy_env curl -4fsS --connect-timeout 5 --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n '1,8p' || echo "FAILED"'''
)

text = text.replace(
'''curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "FAILED"''',
'''run_without_proxy_env curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "FAILED"'''
)

# Add proxy env display inside diagnostics
old_diag = '''echo -e "${YELLOW}DNS / resolv.conf:${NC}"
  cat /etc/resolv.conf 2>/dev/null || true
  echo

  echo -e "${YELLOW}Test 1 - direct IP through current routing:${NC}"'''

new_diag = '''echo -e "${YELLOW}DNS / resolv.conf:${NC}"
  cat /etc/resolv.conf 2>/dev/null || true
  echo

  echo -e "${YELLOW}Current shell proxy environment:${NC}"
  env | grep -Ei '^(http_proxy|https_proxy|all_proxy|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY)=' || echo "No proxy env variables found."
  echo

  echo -e "${YELLOW}Test 1 - direct IP through current routing:${NC}"'''

if old_diag in text:
    text = text.replace(old_diag, new_diag)
else:
    print("Warning: diagnostics insertion point not found.")

# Add UnsetEnvironment to systemd service blocks if not present
text = text.replace(
'''LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE''',
'''LimitNOFILE=1048576
UnsetEnvironment=http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE'''
)

text = text.replace(
'''LimitNOFILE=1048576

[Install]''',
'''LimitNOFILE=1048576
UnsetEnvironment=http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

[Install]'''
)

path.write_text(text)
PY

chmod +x modules/utility/02-temp-tunnel.sh
bash -n modules/utility/02-temp-tunnel.sh

echo
echo "✅ Step 12G-H completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Clear proxy environment for TUN tests' && git push"
