#!/usr/bin/env sh

NEED_UPDATE=1
DEPENDENCIES="sing-box kmod-nft-tproxy nano"

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
  dhcp_server_ip="127.0.0.1#5353"

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

  if [ "$dhcp_server" != "$dhcp_server_ip" ]; then
    log_message "INFO" "Setting DHCP server to $dhcp_server_ip"
    uci -q delete dhcp.@dnsmasq[0].server
    uci -q add_list dhcp.@dnsmasq[0].server="$dhcp_server_ip"
    uci commit dhcp
  fi
}

configure_network() {
  if [ -z "$(uci -q get network.@rule[0])" ]; then
    log_message "INFO" "Creating marking rule"
    uci batch <<EOI
add network rule
set network.@rule[0].mark='0x1'
set network.@rule[0].priority='100'
set network.@rule[0].lookup='100'
EOI
    uci commit network
  fi

  if [ -z "$(uci -q get network.@route[0])" ]; then
    log_message "INFO" "Creating route rule"
    uci batch <<EOI
add network route
set network.@route[0].interface='loopback'
set network.@route[0].target='0.0.0.0/0'
set network.@route[0].table='100'
set network.@route[0].type='local'
EOI
    uci commit network
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
  meta nfproto ipv6 return
  ip daddr != $FAKEIP return
  meta l4proto $TPROXY_L4PROTO tproxy to :$TPROXY_PORT meta mark set $TPROXY_MARK accept
}

chain tproxy_output {
  type route hook output priority mangle; policy accept;
  meta nfproto ipv6 return
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
      "udp_fragment": true
    },
    {
      "tag": "dns-in",
      "type": "direct",
      "listen": "127.0.0.1",
      "listen_port": 5353
    }
  ],
  "outbounds": [
    {
      "tag": "direct-out",
      "type": "direct"
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
        "inbound": ["tproxy-in", "dns-in"],
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
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
  restart_service "network"
  restart_service "dnsmasq"
  restart_service "firewall"
  print_post_install_message
}

main
