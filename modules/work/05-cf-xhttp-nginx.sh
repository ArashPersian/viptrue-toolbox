#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$BASE_DIR/lib/ui.sh"

DEFAULT_DOMAIN="de1.truecdn.online"
DEFAULT_PUBLIC_PORT="2083"
DEFAULT_XRAY_HOST="127.0.0.1"
DEFAULT_XRAY_PORT="8998"
DEFAULT_PATH="/assets/jquery.min.js/"
DEFAULT_CERT="/etc/ssl/cloudflare/truecdn-origin.pem"
DEFAULT_KEY="/etc/ssl/cloudflare/truecdn-origin.key"

refuse_443() {
  local port="$1"
  if [[ "$port" == "443" ]]; then
    echo -e "${RED}Port 443 is not allowed for this toolbox workflow.${NC}"
    echo -e "${YELLOW}Use Cloudflare HTTPS ports like 2083, 2087, 2053, 2096, or 8443.${NC}"
    pause
    return 1
  fi
  return 0
}

valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

cf_https_port_note() {
  echo -e "${CYAN}Cloudflare proxied HTTPS ports:${NC}"
  echo "  443, 2053, 2083, 2087, 2096, 8443"
  echo
  echo -e "${YELLOW}For this project we avoid 443. Recommended: 2083 or 2087.${NC}"
}

check_port() {
  local port="$1"
  echo
  echo "Checking port $port ..."
  if ss -lntup | grep -q ":${port}\b"; then
    echo -e "${RED}Port $port is already in use:${NC}"
    ss -lntup | grep ":${port}\b" || true
    return 1
  fi
  echo -e "${GREEN}Port $port is free.${NC}"
  return 0
}

install_nginx() {
  echo
  echo "Installing Nginx and required packages ..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl ca-certificates
  systemctl enable nginx
  systemctl start nginx
}


paste_multiline_file() {
  local target="$1"
  local title="$2"

  echo
  echo -e "${CYAN}${title}${NC}"
  echo "Paste the full content below."
  echo "When finished, type this line exactly and press Enter:"
  echo "END_VIPTRUE_CERT"
  echo

  mkdir -p "$(dirname "$target")"
  : > "$target"

  while IFS= read -r line; do
    [[ "$line" == "END_VIPTRUE_CERT" ]] && break
    printf '%s\n' "$line" >> "$target"
  done
}

prepare_cf_cert() {
  local cert="$1"
  local key="$2"

  mkdir -p "$(dirname "$cert")" "$(dirname "$key")"
  chmod 700 "$(dirname "$cert")" 2>/dev/null || true

  echo
  echo -e "${CYAN}Cloudflare Origin Certificate setup${NC}"
  echo "Certificate path:"
  echo "  $cert"
  echo "Private key path:"
  echo "  $key"
  echo
  echo "1. Use existing files if present"
  echo "2. Paste certificate and private key now"
  echo "3. Open nano editors"
  echo
  read -r -p "Choose [1-3, default 1]: " cert_mode
  cert_mode="${cert_mode:-1}"

  case "$cert_mode" in
    2)
      paste_multiline_file "$cert" "Paste Cloudflare Origin Certificate"
      paste_multiline_file "$key" "Paste Cloudflare Origin Private Key"
      ;;
    3)
      nano "$cert"
      nano "$key"
      ;;
    1)
      if [[ ! -s "$cert" || ! -s "$key" ]]; then
        echo
        echo -e "${YELLOW}Certificate or key file is missing.${NC}"
        echo "You can paste them now."
        read -r -p "Paste certificate/key now? [Y/n]: " paste_now
        case "$paste_now" in
          n|N|no|NO)
            nano "$cert"
            nano "$key"
            ;;
          *)
            paste_multiline_file "$cert" "Paste Cloudflare Origin Certificate"
            paste_multiline_file "$key" "Paste Cloudflare Origin Private Key"
            ;;
        esac
      fi
      ;;
    *)
      echo -e "${RED}Invalid choice.${NC}"
      pause
      return 1
      ;;
  esac

  chmod 644 "$cert"
  chmod 600 "$key"

  if ! grep -q "BEGIN CERTIFICATE" "$cert"; then
    echo -e "${RED}Certificate file does not look valid: $cert${NC}"
    echo "It must include:"
    echo "-----BEGIN CERTIFICATE-----"
    pause
    return 1
  fi

  if ! grep -q "BEGIN .*PRIVATE KEY" "$key"; then
    echo -e "${RED}Private key file does not look valid: $key${NC}"
    echo "It must include:"
    echo "-----BEGIN PRIVATE KEY-----"
    echo "or"
    echo "-----BEGIN RSA PRIVATE KEY-----"
    pause
    return 1
  fi

  echo -e "${GREEN}Cloudflare Origin certificate and private key are valid-looking.${NC}"
}

write_nginx_conf() {
  local domain="$1"
  local public_port="$2"
  local xray_host="$3"
  local xray_port="$4"
  local path="$5"
  local cert="$6"
  local key="$7"

  local safe_name
  safe_name="$(echo "$domain" | tr -cd 'A-Za-z0-9_.-' | tr '.' '-')"
  local conf="/etc/nginx/sites-available/viptrue-cf-xhttp-${safe_name}.conf"

  # Ensure path starts and ends with /
  [[ "$path" == /* ]] || path="/$path"
  [[ "$path" == */ ]] || path="$path/"

  cat > "$conf" <<EOF_CONF
server {
    listen ${public_port} ssl http2;
    server_name ${domain};

    ssl_certificate ${cert};
    ssl_certificate_key ${key};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    client_max_body_size 0;

    # XHTTP reverse proxy path
    location ${path} {
        proxy_pass http://${xray_host}:${xray_port};

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_buffering off;
        proxy_request_buffering off;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Simple health page for normal browser checks
    location / {
        add_header Content-Type text/plain;
        return 200 "TrueCDN edge node is running.\\n";
    }
}
EOF_CONF

  ln -sf "$conf" "/etc/nginx/sites-enabled/$(basename "$conf")"

  echo
  echo "Created:"
  echo "  $conf"
}

reload_nginx() {
  echo
  nginx -t
  systemctl reload nginx
  echo -e "${GREEN}Nginx reloaded successfully.${NC}"
}

print_summary() {
  local domain="$1"
  local public_port="$2"
  local xray_host="$3"
  local xray_port="$4"
  local path="$5"

  echo
  line
  echo -e "${GREEN}Cloudflare XHTTP Nginx setup completed.${NC}"
  line
  echo
  echo "Origin / Nginx:"
  echo "  ${domain}:${public_port}"
  echo
  echo "Internal Xray/PasarGuard XHTTP:"
  echo "  ${xray_host}:${xray_port}"
  echo
  echo "XHTTP path:"
  echo "  ${path}"
  echo
  echo "PasarGuard Host settings:"
  echo "  Address: CLEAN_CLOUDFLARE_IP or ${domain}"
  echo "  Port: ${public_port}"
  echo "  Security: tls"
  echo "  SNI: ${domain}"
  echo "  Host: ${domain}"
  echo "  Path: ${path}"
  echo "  ALPN: h3,h2"
  echo "  Fingerprint: chrome"
  echo
  echo "Quick tests:"
  echo "  curl -k https://127.0.0.1:${public_port}/ -H 'Host: ${domain}'"
  echo "  curl -k -I https://127.0.0.1:${public_port}${path} -H 'Host: ${domain}'"
  echo "  curl -I https://${domain}:${public_port}/"
  echo
  pause
}

setup_cf_xhttp_nginx() {
  title
  echo -e "${CYAN}Cloudflare XHTTP Nginx Setup${NC}"
  line
  echo
  cf_https_port_note

  read -r -p "Domain / server_name [${DEFAULT_DOMAIN}]: " domain
  domain="${domain:-$DEFAULT_DOMAIN}"

  read -r -p "Public Cloudflare HTTPS port [${DEFAULT_PUBLIC_PORT}]: " public_port
  public_port="${public_port:-$DEFAULT_PUBLIC_PORT}"

  if ! valid_port "$public_port"; then
    echo -e "${RED}Invalid port.${NC}"
    pause
    return
  fi

  refuse_443 "$public_port" || return

  read -r -p "Internal Xray/PasarGuard host [${DEFAULT_XRAY_HOST}]: " xray_host
  xray_host="${xray_host:-$DEFAULT_XRAY_HOST}"

  read -r -p "Internal Xray/PasarGuard XHTTP port [${DEFAULT_XRAY_PORT}]: " xray_port
  xray_port="${xray_port:-$DEFAULT_XRAY_PORT}"

  if ! valid_port "$xray_port"; then
    echo -e "${RED}Invalid internal Xray port.${NC}"
    pause
    return
  fi

  read -r -p "XHTTP path [${DEFAULT_PATH}]: " path
  path="${path:-$DEFAULT_PATH}"

  read -r -p "Cloudflare Origin certificate path [${DEFAULT_CERT}]: " cert
  cert="${cert:-$DEFAULT_CERT}"

  read -r -p "Cloudflare Origin private key path [${DEFAULT_KEY}]: " key
  key="${key:-$DEFAULT_KEY}"

  echo
  line
  echo "Plan:"
  echo "  Domain:        $domain"
  echo "  Public port:   $public_port"
  echo "  Internal Xray: $xray_host:$xray_port"
  echo "  Path:          $path"
  echo "  Cert:          $cert"
  echo "  Key:           $key"
  line
  echo

  read -r -p "Continue? [y/N]: " ok
  case "$ok" in
    y|Y|yes|YES) ;;
    *) return ;;
  esac

  install_nginx

  if ! check_port "$public_port"; then
    echo
    echo -e "${YELLOW}Port $public_port is already used. If it is Nginx from an older config, this may be fine.${NC}"
    read -r -p "Continue anyway and let Nginx config decide? [y/N]: " cont
    case "$cont" in
      y|Y|yes|YES) ;;
      *) pause; return ;;
    esac
  fi

  prepare_cf_cert "$cert" "$key"
  write_nginx_conf "$domain" "$public_port" "$xray_host" "$xray_port" "$path" "$cert" "$key"
  reload_nginx

  echo
  echo "Listening ports:"
  ss -lntup | grep -E ":${public_port}\b|:${xray_port}\b" || true

  print_summary "$domain" "$public_port" "$xray_host" "$xray_port" "$path"
}


create_speed_test_files() {
  title
  echo -e "${CYAN}Create Nginx Speed Test Files${NC}"
  line
  echo

  local root="/var/www/viptrue-speed"
  mkdir -p "$root/speed"

  echo "Creating test files:"
  echo "  $root/speed/1mb.bin"
  echo "  $root/speed/10mb.bin"
  echo "  $root/speed/50mb.bin"
  echo

  dd if=/dev/zero of="$root/speed/1mb.bin" bs=1M count=1 status=none
  dd if=/dev/zero of="$root/speed/10mb.bin" bs=1M count=10 status=none
  dd if=/dev/zero of="$root/speed/50mb.bin" bs=1M count=50 status=none

  chown -R www-data:www-data "$root" 2>/dev/null || true
  chmod -R 755 "$root"

  echo -e "${GREEN}Speed test files created.${NC}"
  echo
  echo "Recommended speed path:"
  echo "  /speed/10mb.bin"
  echo
  pause
}

show_status() {
  title
  echo -e "${CYAN}Cloudflare XHTTP Nginx Status${NC}"
  line
  echo
  echo "Nginx:"
  systemctl is-active nginx 2>/dev/null || true
  echo
  echo "Listening relevant ports:"
  ss -lntup | grep -E ':2083\b|:2087\b|:2053\b|:2096\b|:8443\b|:8998\b' || true
  echo
  echo "Enabled VIPTrue XHTTP Nginx configs:"
  ls -l /etc/nginx/sites-enabled/*viptrue-cf-xhttp* 2>/dev/null || echo "No viptrue-cf-xhttp configs found."
  echo
  pause
}

test_endpoint() {
  title
  echo -e "${CYAN}Test Cloudflare XHTTP Nginx Endpoint${NC}"
  line
  echo

  read -r -p "Domain [${DEFAULT_DOMAIN}]: " domain
  domain="${domain:-$DEFAULT_DOMAIN}"

  read -r -p "Public port [${DEFAULT_PUBLIC_PORT}]: " public_port
  public_port="${public_port:-$DEFAULT_PUBLIC_PORT}"

  read -r -p "Path [${DEFAULT_PATH}]: " path
  path="${path:-$DEFAULT_PATH}"

  [[ "$path" == /* ]] || path="/$path"
  [[ "$path" == */ ]] || path="$path/"

  echo
  echo "Local health test:"
  curl -k "https://127.0.0.1:${public_port}/" -H "Host: ${domain}" || true

  echo
  echo
  echo "Local XHTTP path HTTP headers:"
  curl -k -I "https://127.0.0.1:${public_port}${path}" -H "Host: ${domain}" || true

  echo
  echo
  echo "Public Cloudflare/Domain health test:"
  curl -I --connect-timeout 10 "https://${domain}:${public_port}/" || true

  echo
  pause
}

remove_config() {
  title
  echo -e "${CYAN}Remove Cloudflare XHTTP Nginx Config${NC}"
  line
  echo

  ls -1 /etc/nginx/sites-available/*viptrue-cf-xhttp* 2>/dev/null || {
    echo "No viptrue-cf-xhttp configs found."
    pause
    return
  }

  echo
  read -r -p "Domain/config keyword to remove, example de1.truecdn.online or de1-truecdn-online: " kw
  [[ -n "$kw" ]] || return

  safe_kw="$(echo "$kw" | tr '.' '-')"

  rm -f /etc/nginx/sites-enabled/*"$kw"* /etc/nginx/sites-enabled/*"$safe_kw"* 2>/dev/null || true
  rm -f /etc/nginx/sites-available/*"$kw"* /etc/nginx/sites-available/*"$safe_kw"* 2>/dev/null || true

  nginx -t
  systemctl reload nginx
  echo -e "${GREEN}Removed matching config and reloaded Nginx.${NC}"
  pause
}

while true; do
  title
  echo -e "${CYAN}Cloudflare XHTTP Nginx Setup${NC}"
  line
  echo "1. Install / configure Nginx for XHTTP behind Cloudflare"
  echo "2. Status"
  echo "3. Test endpoint"
  echo "4. Remove Nginx config"
  echo "0. Back"
  echo
  read -r -p "Enter your choice [0-4]: " choice

  case "$choice" in
    1) setup_cf_xhttp_nginx ;;
    2) show_status ;;
    3) test_endpoint ;;
    4) remove_config ;;
    0) break ;;
    *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
  esac
done
