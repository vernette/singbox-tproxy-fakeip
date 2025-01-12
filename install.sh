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
    uci -q delete dhcp.@dnsmasq[0].server
    uci -q add_list dhcp.@dnsmasq[0].server="127.0.0.1#5353"
    uci commit dhcp
  fi
}

check_network_rule_exists() {
  type="$1"
  shift

  uci show network | grep -q "@${type}\[" || true

  found=0
  i=0
  while true; do
    if ! uci -q get "network.@${type}[${i}]" >/dev/null 2>&1; then
      break
    fi

    allmatch=1

    for param in "$@"; do
      key=$(echo "$param" | cut -d= -f1)
      value=$(echo "$param" | cut -d= -f2)
      current=$(uci -q get "network.@${type}[${i}].${key}")

      if [ "$current" != "$value" ]; then
        allmatch=0
        break
      fi
    done

    if [ "$allmatch" = "1" ]; then
      found=1
      break
    fi

    i=$((i + 1))
  done

  return $((1 - found))
}

add_network_section() {
  type="$1"
  shift

  if ! uci add network "$type" >/dev/null 2>&1; then
    log_message "ERROR" "Failed to add new ${type} section"
    return 1
  fi

  for param in "$@"; do
    key=$(echo "$param" | cut -d= -f1)
    value=$(echo "$param" | cut -d= -f2)
    if ! uci set "network.@${type}[-1].${key}=${value}" >/dev/null 2>&1; then
      log_message "ERROR" "Failed to set ${key}=${value} for ${type}"
      return 1
    fi
  done

  return 0
}

configure_network() {
  changes=0

  log_message "INFO" "Checking for existing network rule"
  if check_network_rule_exists "rule" "mark=0x1" "priority=100" "lookup=100"; then
    log_message "INFO" "Network rule already exists"
  else
    log_message "INFO" "Adding new network rule with mark 0x1"
    if add_network_section "rule" "mark=0x1" "priority=100" "lookup=100"; then
      changes=1
      log_message "INFO" "Network rule added successfully"
    fi
  fi

  log_message "INFO" "Checking for existing network route"
  if check_network_rule_exists "route" "interface=loopback" "target=0.0.0.0/0" "table=100" "type=local"; then
    log_message "INFO" "Network route already exists"
  else
    log_message "INFO" "Adding new network route for loopback interface"
    if add_network_section "route" "interface=loopback" "target=0.0.0.0/0" "table=100" "type=local"; then
      changes=1
      log_message "INFO" "Network route added successfully"
    fi
  fi

  if [ "$changes" = "1" ]; then
    log_message "INFO" "Committing changes to network configuration"
    if ! uci commit network >/dev/null 2>&1; then
      log_message "ERROR" "Failed to commit changes"
      return 1
    fi
    log_message "INFO" "Changes to network configuration committed successfully"
  else
    log_message "INFO" "No changes needed for network configuration"
  fi
}

configure_nftables() {
  config_path="/etc/nftables.d/30-tproxy-fakeip.nft"
  if [ ! -f "$config_path" ]; then
    log_message "INFO" "Creating nftables config"
    cat <<'EOF' >"$config_path"
define TPROXY_MARK = 0x1
define TPROXY_L4PROTO = { tcp, udp }
define TPROXY_PORT = 4444
define FAKEIP = { 198.18.0.0/15 }

chain tproxy_prerouting {
  type filter hook prerouting priority mangle; policy accept;
  ip daddr != $FAKEIP return
  meta l4proto $TPROXY_L4PROTO tproxy to :$TPROXY_PORT meta mark set $TPROXY_MARK accept
}

chain tproxy_output {
  type route hook output priority mangle; policy accept;
  ip daddr != $FAKEIP return
  meta l4proto $TPROXY_L4PROTO meta mark set $TPROXY_MARK
}
EOF
  fi
}

restart_service() {
  service="$1"
  log_message "INFO" "Restarting $service service"
  service "$service" restart
}

configure_sing_box() {
  config_path="/etc/sing-box/config.json"
  if ! grep -q "fakeip" "$config_path"; then
    log_message "INFO" "Configuring sing-box"
    cat <<'EOF' >"$config_path"
{
  "log": {
    "level": "info"
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "store_fakeip": true,
      "path": "/etc/sing-box/cache.db"
    }
  },
  "dns": {
    "strategy": "ipv4_only",
    "fakeip": {
      "enabled": true,
      "inet4_range": "198.18.0.0/15"
    },
    "servers": [
      {
        "tag": "cloudflare-doh-server",
        "address": "https://1.1.1.1/dns-query",
        "detour": "direct-out"
      },
      {
        "tag": "fakeip-server",
        "address": "fakeip"
      }
    ],
    "rules": [
      {
        "domain_suffix": ["ifconfig.me"],
        "server": "fakeip-server"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "tproxy-in",
      "type": "tproxy",
      "listen": "::",
      "listen_port": 4444,
      "tcp_fast_open": true,
      "udp_fragment": true,
      "sniff": true
    },
    {
      "tag": "dns-in",
      "type": "direct",
      "listen": "127.0.0.1",
      "listen_port": 5353,
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "tag": "direct-out",
      "type": "direct"
    },
    {
      "tag": "dns-out",
      "type": "dns"
    },
    {
      "tag": "vless-out",
      "type": "vless",
      "server": "$SERVER",
      "server_port": 443,
      "uuid": "$UUID",
      "flow": "$FLOW",
      "tls": {
        "enabled": true,
        "server_name": "$FAKE_SERVER",
        "utls": {
          "enabled": true,
          "fingerprint": "$FINGERPRINT"
        },
        "reality": {
          "enabled": true,
          "public_key": "$PUBLIC_KEY",
          "short_id": "$SHORT_ID"
        }
      }
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "inbound": ["tproxy-in"],
        "domain_suffix": ["ifconfig.me"],
        "outbound": "vless-out"
      }
    ],
    "auto_detect_interface": true
  }
}
EOF
  fi
}

print_post_install_message() {
  printf "\nInstallation completed successfully.\n\n!!! Now you need to make changes to sing-box config (nano /etc/sing-box/config.json) and restart sing-box service with this command: service sing-box restart !!!\n\n"
}

main() {
  install_dependencies
  configure_sing_box_service
  configure_dhcp
  configure_network
  configure_nftables
  configure_sing_box
  restart_service "dnsmasq"
  restart_service "firewall"
  print_post_install_message
}

main
