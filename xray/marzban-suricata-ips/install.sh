#!/usr/bin/env bash
# Local installer; install-online.sh downloads a complete snapshot.
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 027
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ${1:-} == --upgrade ]]; then
    exec bash "$DIR/upgrade.sh"
fi
[[ $# -eq 0 ]] || { echo 'Usage: install.sh [--upgrade]' >&2; exit 2; }
QUEUE="${QUEUE:-150}"
error() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || error 'Run: sudo bash install.sh'
[[ -r /etc/os-release ]] || error 'Missing /etc/os-release'
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == ubuntu ]] && dpkg --compare-versions "${VERSION_ID:-0}" ge 22.04 || error 'Supported OS: Ubuntu 22.04 or newer with systemd.'
[[ -d /run/systemd/system ]] || error 'systemd is required.'
[[ $QUEUE =~ ^[1-9][0-9]{0,4}$ ]] && ((QUEUE <= 65535)) || error 'QUEUE must be 1..65535 (no leading zero).'
for cmd in docker ip flock; do command -v "$cmd" >/dev/null || error "Missing command: $cmd"; done
exec 9>/run/lock/marzban-ips.lock
flock -n 9 || error 'Another installation or management operation is running.'
for file in VERSION upgrade.sh project_update.py monitor.py marzban-ips ips_helpers.py marzban-ips.nft.in marzban-suricata.service \
    marzban-ips-filter.service marzban-ips-update.service marzban-ips-update.timer \
    marzban-ips-refresh.service marzban-ips-refresh.timer marzban-ips-logrotate.service \
    marzban-ips-logrotate.timer marzban-ips.logrotate selftest.rules; do
    [[ -r $DIR/$file ]] || error "Missing $file. Download the complete folder or use install-online.sh."
done
package_version="$(cat "$DIR/VERSION")"
[[ $package_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || error 'Invalid package version.'
[[ ! -e /etc/suricata/marzban-ips.yaml && ! -e /etc/marzban-ips/installed ]] || error 'Already/partly installed. Use marzban-ips status or uninstall before reinstalling.'
[[ ! -e /usr/local/sbin/marzban-ips && ! -e /opt/marzban-ips/ips_helpers.py ]] || error 'Existing installation files found; inspect them before installing.'
shopt -s nullglob
for file in /etc/systemd/system/marzban-ips-* /etc/systemd/system/marzban-suricata.service; do
    [[ ! -e $file ]] || error "Existing unit: $file"
done
if systemctl is-active --quiet suricata.service || pgrep -x suricata >/dev/null; then
    error 'An existing Suricata instance is running. This installer does not replace it.'
fi
if command -v nft >/dev/null && nft list table inet marzban_ips >/dev/null 2>&1; then
    error 'Existing inet marzban_ips table; refusing to overwrite it.'
fi
node_list="$(docker ps --format '{{.ID}} {{.Image}} {{.Names}}')" || error 'Cannot query Docker.'
mapfile -t nodes < <(awk 'tolower($0) ~ /marzban-node/ {print $1}' <<< "$node_list")
((${#nodes[@]})) || error 'No running marzban-node container found.'
for node in "${nodes[@]}"; do
    [[ $(docker inspect -f '{{.HostConfig.NetworkMode}}' "$node") == host ]] || error "Container $node requires network_mode: host."
done
owned=0
masked=0
finished=0
cleanup() {
    local rc=$?
    if ((masked)); then systemctl unmask --runtime suricata.service >/dev/null 2>&1 || true; fi
    if ((owned && !finished)); then
        systemctl disable --now marzban-ips-filter.service marzban-ips-update.timer \
            marzban-ips-refresh.timer marzban-ips-logrotate.timer marzban-suricata.service >/dev/null 2>&1 || true
        if nft list table inet marzban_ips >/dev/null 2>&1; then nft delete table inet marzban_ips || true; fi
        echo 'Installation failed; interception removed. Logs/configuration retained.' >&2
        echo 'Inspect the error, then run: sudo marzban-ips uninstall ; reinstall afterwards.' >&2
    fi
    exit "$rc"
}
trap cleanup EXIT
echo 'Installing distribution packages...'
if [[ $(systemctl is-enabled suricata.service 2>/dev/null || true) != masked* ]]; then
    systemctl mask --runtime suricata.service
    masked=1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends suricata suricata-update nftables python3-yaml curl ca-certificates logrotate
systemctl disable --now suricata.service
if ((masked)); then systemctl unmask --runtime suricata.service; masked=0; fi
build_info="$(suricata --build-info)"
grep -Eqi 'NFQueue support:[[:space:]]+yes' <<< "$build_info" || error 'Suricata was built without NFQueue support.'
[[ -r /proc/net/netfilter/nfnetlink_queue ]] || modprobe nfnetlink_queue
if awk -v q="$QUEUE" '$1 == q {found=1} END {exit !found}' /proc/net/netfilter/nfnetlink_queue; then
    error "NFQUEUE $QUEUE is already in use."
fi
[[ -r /etc/suricata/suricata.yaml ]] || error 'Missing base Suricata YAML.'
install -d -m 0750 /etc/marzban-ips /opt/marzban-ips /var/lib/marzban-ips/rules /var/lib/marzban-ips/update /var/log/marzban-suricata
install -m 0755 "$DIR/marzban-ips" /usr/local/sbin/marzban-ips
owned=1
printf '%s\n' 'OpsVault marzban-ips v2' > /etc/marzban-ips/installed
install -m 0644 "$DIR/ips_helpers.py" /opt/marzban-ips/ips_helpers.py
install -m 0644 "$DIR/project_update.py" /opt/marzban-ips/project_update.py
install -m 0644 "$DIR/monitor.py" /opt/marzban-ips/monitor.py
install -m 0644 "$DIR/VERSION" /etc/marzban-ips/version
install -m 0644 "$DIR/selftest.rules" /etc/marzban-ips/selftest.rules
python3 /opt/marzban-ips/ips_helpers.py configure /etc/suricata/suricata.yaml /etc/suricata/marzban-ips.yaml
printf '{}\n' > /etc/marzban-ips/update.yaml
: > /etc/marzban-ips/empty.conf
sed "s/@QUEUE@/$QUEUE/g" "$DIR/marzban-ips.nft.in" > /etc/marzban-ips/queue.nft
printf '%s\n' "$QUEUE" > /etc/marzban-ips/queue-number
nft -c -f /etc/marzban-ips/queue.nft
sed "s/QUEUE_NUMBER/$QUEUE/g" "$DIR/marzban-suricata.service" > /etc/systemd/system/marzban-suricata.service
for file in "$DIR"/marzban-ips-*.service "$DIR"/marzban-ips-*.timer; do
    install -m 0644 "$file" "/etc/systemd/system/$(basename -- "$file")"
done
install -m 0644 "$DIR/marzban-ips.logrotate" /etc/marzban-ips/logrotate.conf
systemctl daemon-reload
flock -u 9
/usr/local/sbin/marzban-ips update
/usr/local/sbin/marzban-ips enable
systemctl enable --now marzban-ips-update.timer marzban-ips-refresh.timer marzban-ips-logrotate.timer
finished=1
echo 'Installed. Recovery: sudo marzban-ips disable'
/usr/local/sbin/marzban-ips status
