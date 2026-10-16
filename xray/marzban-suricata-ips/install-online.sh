#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[[ $EUID -eq 0 ]] || { echo 'Run with sudo bash install-online.sh' >&2; exit 1; }
for cmd in curl tar; do command -v "$cmd" >/dev/null || { echo "Install $cmd first." >&2; exit 1; }; done
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
curl --proto '=https' --tlsv1.2 -fSL --retry 3 --connect-timeout 15 --max-time 180 \
    'https://codeload.github.com/KAJOOSH/OpsVault/tar.gz/refs/heads/main' -o "$tmp/repo.tar.gz"
files=(VERSION upgrade.sh project_update.py monitor.py install.sh marzban-ips ips_helpers.py marzban-ips.nft.in marzban-suricata.service
    marzban-ips-filter.service marzban-ips-update.service marzban-ips-update.timer
    marzban-ips-refresh.service marzban-ips-refresh.timer marzban-ips-logrotate.service
    marzban-ips-logrotate.timer marzban-ips.logrotate selftest.rules)
members=()
for file in "${files[@]}"; do members+=("OpsVault-main/xray/marzban-suricata-ips/$file"); done
tar -xzf "$tmp/repo.tar.gz" -C "$tmp" --strip-components=3 --no-same-owner --no-same-permissions -- "${members[@]}"
if [[ -e /etc/marzban-ips/installed ]]; then
    bash "$tmp/install.sh" --upgrade
else
    bash "$tmp/install.sh"
fi
