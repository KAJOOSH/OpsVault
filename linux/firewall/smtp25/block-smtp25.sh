#!/usr/bin/env bash
set -euo pipefail

# Permanent TCP/25 blocking for Marzban/Xray hosts.
# Covers host-originated traffic, forwarded traffic, Docker, IPv4, and IPv6.

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[1/5] Installing persistent firewall packages..."
apt-get update
apt-get install -y iptables-persistent netfilter-persistent

add_v4_rule() {
  local chain="$1"
  if iptables -nL "$chain" >/dev/null 2>&1; then
    if ! iptables -C "$chain" -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null; then
      iptables -I "$chain" 1 -p tcp --dport 25 -j REJECT --reject-with tcp-reset
    fi
  fi
}

add_v6_rule() {
  local chain="$1"
  if ip6tables -nL "$chain" >/dev/null 2>&1; then
    if ! ip6tables -C "$chain" -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null; then
      ip6tables -I "$chain" 1 -p tcp --dport 25 -j REJECT --reject-with tcp-reset
    fi
  fi
}

echo "[2/5] Applying IPv4 rules..."
add_v4_rule OUTPUT
add_v4_rule FORWARD
add_v4_rule DOCKER-USER

echo "[3/5] Applying IPv6 rules..."
add_v6_rule OUTPUT
add_v6_rule FORWARD
add_v6_rule DOCKER-USER

echo "[4/5] Saving rules..."
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

systemctl enable netfilter-persistent >/dev/null 2>&1 || true

echo "[5/5] Verifying rules..."
echo
echo "IPv4 OUTPUT:"
iptables -L OUTPUT -n -v --line-numbers | grep -E 'dpt:25|Chain OUTPUT' || true

echo
echo "IPv4 FORWARD:"
iptables -L FORWARD -n -v --line-numbers | grep -E 'dpt:25|Chain FORWARD' || true

echo
echo "IPv4 DOCKER-USER:"
iptables -L DOCKER-USER -n -v --line-numbers 2>/dev/null | grep -E 'dpt:25|Chain DOCKER-USER' || true

echo
echo "IPv6 OUTPUT:"
ip6tables -L OUTPUT -n -v --line-numbers | grep -E 'dpt:25|Chain OUTPUT' || true

echo
echo "IPv6 FORWARD:"
ip6tables -L FORWARD -n -v --line-numbers | grep -E 'dpt:25|Chain FORWARD' || true

echo
echo "TCP/25 blocking is active and saved."
