#!/usr/bin/env bash
# Egress firewall for offline forks. Applied at boot from launch_chffrplus.sh.
# Blocks ALL traffic except loopback and established connections, IPv4+IPv6,
# so nothing (openpilot or OS-level) can reach the network even if a radio is up.
#
# To keep a debug interface usable (e.g. SSH over USB gadget), export:
#   OFFLINE_ALLOW_IFACES="usb0"
set -uo pipefail

ALLOW_IFACES=${OFFLINE_ALLOW_IFACES:-}

iface_rules() {
  local dir="$1" iface out=""
  for iface in $ALLOW_IFACES; do
    out+="    ${dir}name \"${iface}\" accept"$'\n'
  done
  printf '%s' "$out"
}

if command -v nft >/dev/null 2>&1; then
  RULES="table inet op_offline
table inet op_offline
delete table inet op_offline

table inet op_offline {
  chain input {
    type filter hook input priority filter; policy drop;
    iifname \"lo\" accept
    ct state established,related accept
$(iface_rules iif)
  }

  chain output {
    type filter hook output priority filter; policy drop;
    oifname \"lo\" accept
    ct state established,related accept
$(iface_rules oif)
  }
}"
  if printf '%s\n' "$RULES" | sudo nft -f -; then
    echo "offline firewall applied (nftables)"
    exit 0
  fi
fi

if command -v iptables >/dev/null 2>&1; then
  sudo iptables -N OP_OFFLINE_OUT 2>/dev/null || true
  sudo iptables -F OP_OFFLINE_OUT
  sudo iptables -A OP_OFFLINE_OUT -o lo -j ACCEPT
  sudo iptables -A OP_OFFLINE_OUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  for iface in $ALLOW_IFACES; do
    sudo iptables -A OP_OFFLINE_OUT -o "$iface" -j ACCEPT
  done
  sudo iptables -A OP_OFFLINE_OUT -j REJECT
  sudo iptables -C OUTPUT -j OP_OFFLINE_OUT 2>/dev/null || sudo iptables -A OUTPUT -j OP_OFFLINE_OUT
  echo "offline firewall applied (iptables fallback, egress only)"
  exit 0
fi

echo "no nftables or iptables available; firewall NOT applied" >&2
exit 1
