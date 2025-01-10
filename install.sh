#!/usr/bin/env sh

NEED_UPDATE=1
DEPENDENCIES="sing-box kmod-nft-tproxy"

get_timestamp() {
  format="$1"
  date +"$format"
}

log_message() {
  log_level="$1"
  message="$2"
  timestamp=$(get_timestamp "%d.%m.%Y %H:%M:%S")
  echo "[$timestamp] [$log_level]: $message"
}

is_installed() {
  opkg list-installed | grep -qo "$1"
}

check_updates() {
  if [ "$NEED_UPDATE" -eq "1" ]; then
    log_message "INFO" "Updating package list"
    opkg update >/dev/null
    NEED_UPDATE=0
  fi
}

install_dependencies() {
  for package in $DEPENDENCIES; do
    if ! is_installed "$package"; then
      check_updates
      log_message "INFO" "Installing $package"
      opkg install "$package" >/dev/null
    fi
  done
}

configure_sing_box_service() {
  sing_box_enabled=$(uci -q get sing-box.main.enabled)
  sing_box_user=$(uci -q get sing-box.main.user)

  if [ "$sing_box_enabled" -eq "0" ]; then
    log_message "INFO" "Enabling sing-box service"
    uci -q set sing-box.main.enabled=1
    uci commit sing-box
  fi

  if [ "$sing_box_user" != "root" ]; then
    log_message "INFO" "Setting sing-box user to root"
    uci -q set sing-box.main.user=root
    uci commit sing-box
  fi
}

configure_dhcp() {
  is_noresolv_enabled=$(uci -q get dhcp.@dnsmasq[0].noresolv || echo "0")
  is_filter_aaaa_enabled=$(uci -q get dhcp.@dnsmasq[0].filter_aaaa || echo "0")
  dhcp_server=$(uci -q get dhcp.@dnsmasq[0].server || echo "")

  if [ "$is_noresolv_enabled" -ne "1" ]; then
    log_message "INFO" "Enabling noresolv option in DHCP config"
    uci -q set dhcp.@dnsmasq[0].noresolv=1
    uci commit dhcp
  fi

  if [ "$is_filter_aaaa_enabled" -ne "1" ]; then
    log_message "INFO" "Enabling filter_aaaa option in DHCP config"
    uci -q set dhcp.@dnsmasq[0].filter_aaaa=1
    uci commit dhcp
  fi

  if [ "$dhcp_server" != "127.0.0.1#5353" ]; then
    log_message "INFO" "Setting DHCP server to 127.0.0.1#5353"
    uci -q add_list dhcp.@dnsmasq[0].server="127.0.0.1#5353"
    uci commit dhcp
  fi
}

main() {
  install_dependencies
  configure_sing_box_service
  configure_dhcp
}

main
