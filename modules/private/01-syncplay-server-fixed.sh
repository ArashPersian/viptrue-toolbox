#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=modules/private/01-syncplay-server.sh
source "$BASE_DIR/modules/private/01-syncplay-server.sh"

# Hotfix for v0.4.3: avoid local variable shadowing when returning values
# through printf -v under set -u. The original prompt function used local
# names identical to caller output variable names, so service_name stayed unset
# in install_or_reinstall_syncplay before the Plan was printed.
prompt_install_config() {
  local __port_var="$1"
  local __password_var="$2"
  local __salt_var="$3"
  local __isolate_var="$4"
  local __bind_mode_var="$5"
  local __service_var="$6"
  local __motd_var="$7"
  local cfg_port cfg_service_name cfg_password cfg_salt cfg_isolate cfg_bind_choice cfg_bind_mode cfg_motd default_port default_service

  default_port="$(read_existing_default port "$SYNCPLAY_DEFAULT_PORT")"
  default_service="$(read_existing_default service "$SYNCPLAY_DEFAULT_SERVICE")"

  cfg_port="$(prompt_default "Syncplay server port" "$default_port")"
  if ! valid_port "$cfg_port"; then
    echo -e "${RED}Invalid port.${NC} Use 1-65535."
    return 1
  fi

  cfg_service_name="$(prompt_default "Service name" "$default_service")"
  cfg_service_name="$(normalize_service_name "$cfg_service_name")"
  if ! valid_service_name "$cfg_service_name"; then
    echo -e "${RED}Invalid service name.${NC} Use letters, numbers, dot, underscore, @, or dash."
    return 1
  fi

  cfg_password=""
  if prompt_yes_no "Generate random password? [Y/n]:" "Y"; then
    cfg_password="$(random_secret)"
  else
    read -r -s -p "Private server password, optional: " cfg_password
    echo
  fi
  cfg_salt="$(random_secret)"

  cfg_isolate="no"
  if prompt_yes_no "Isolate rooms? [y/N]:" "N"; then
    cfg_isolate="yes"
  fi

  read -r -p "MOTD text, optional: " cfg_motd

  echo
  echo "Bind mode:"
  echo "1) IPv4/default"
  echo "2) IPv6 only"
  read -r -p "Select bind mode [1-2]: " cfg_bind_choice
  case "${cfg_bind_choice:-1}" in
    1) cfg_bind_mode="ipv4" ;;
    2) cfg_bind_mode="ipv6" ;;
    *)
      echo -e "${RED}Invalid bind mode.${NC}"
      return 1
      ;;
  esac

  printf -v "$__port_var" '%s' "$cfg_port"
  printf -v "$__password_var" '%s' "$cfg_password"
  printf -v "$__salt_var" '%s' "$cfg_salt"
  printf -v "$__isolate_var" '%s' "$cfg_isolate"
  printf -v "$__bind_mode_var" '%s' "$cfg_bind_mode"
  printf -v "$__service_var" '%s' "$cfg_service_name"
  printf -v "$__motd_var" '%s' "$cfg_motd"
}

syncplay_server_menu
