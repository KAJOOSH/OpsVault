#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 027
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
error() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || error 'Run with sudo.'
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == ubuntu ]] && dpkg --compare-versions "${VERSION_ID:-0}" ge 22.04 || error 'Ubuntu 22.04 or newer is required.'
[[ -f /etc/marzban-ips/installed ]] || error 'No owned installation found. Run the installer first.'
exec 9>/run/lock/marzban-ips.lock
flock -n 9 || error 'Another operation is running. Retry shortly.'
queue="$(cat /etc/marzban-ips/queue-number)"
[[ $queue =~ ^[1-9][0-9]{0,4}$ ]] && ((queue <= 65535)) || error 'Invalid installed queue number.'
new_version="$(cat "$DIR/VERSION")"
[[ $new_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || error 'Invalid package version.'
python3 -c 'import yaml' || error 'Install python3-yaml first.'
timers=(marzban-ips-update.timer marzban-ips-refresh.timer marzban-ips-logrotate.timer)
units=(marzban-suricata.service marzban-ips-filter.service marzban-ips-update.service
    marzban-ips-update.timer marzban-ips-refresh.service marzban-ips-refresh.timer
    marzban-ips-logrotate.service marzban-ips-logrotate.timer)
for file in VERSION marzban-ips ips_helpers.py monitor.py project_update.py selftest.rules marzban-ips.nft.in marzban-ips.logrotate "${units[@]}"; do
    [[ -s $DIR/$file ]] || error "Incomplete bundle: $file"
done
install -d -m 0750 /var/lib/marzban-ips/backups
backup="$(mktemp -d /var/lib/marzban-ips/backups/upgrade-XXXXXXXX)"
mkdir -p "$backup/stage" "$backup/files"
python3 "$DIR/ips_helpers.py" configure /etc/suricata/marzban-ips.yaml "$backup/stage/config.yaml"
python3 - /var/lib/marzban-ips/rules/suricata.rules "$DIR/selftest.rules" "$backup/stage/suricata.rules" <<'PY'
from pathlib import Path
import re, sys
source, selftest, target = map(Path, sys.argv[1:])
lines = [line for line in source.read_text().splitlines() if not re.search(r'\bsid:\s*9900001\s*;', line)]
target.write_text('\n'.join(lines) + '\n' + selftest.read_text())
PY
suricata -T --simulate-ips --init-errors-fatal -c "$backup/stage/config.yaml" -S "$backup/stage/suricata.rules" -l "$backup/stage"
sed "s/@QUEUE@/$queue/g" "$DIR/marzban-ips.nft.in" > "$backup/stage/queue.nft"
# Check syntax without colliding with the currently installed table.
if nft list table inet marzban_ips >/dev/null 2>&1; then
    { echo 'delete table inet marzban_ips'; cat "$backup/stage/queue.nft"; } > "$backup/stage/check.nft"
else cp "$backup/stage/queue.nft" "$backup/stage/check.nft"; fi
nft -c -f "$backup/stage/check.nft"
files=(/usr/local/sbin/marzban-ips /opt/marzban-ips/ips_helpers.py /opt/marzban-ips/monitor.py
    /opt/marzban-ips/project_update.py /etc/marzban-ips/version /etc/marzban-ips/selftest.rules
    /etc/marzban-ips/queue.nft /etc/marzban-ips/logrotate.conf /etc/suricata/marzban-ips.yaml
    /var/lib/marzban-ips/rules/suricata.rules)
for unit in "${units[@]}"; do files+=("/etc/systemd/system/$unit"); done
for file in "${files[@]}"; do
    if [[ -e $file ]]; then
        mkdir -p "$backup/files$(dirname -- "$file")"
        cp -p -- "$file" "$backup/files$file"
    fi
done
engine_active=0
filter_active=0
systemctl is-active --quiet marzban-suricata.service && engine_active=1
if systemctl is-active --quiet marzban-ips-filter.service || nft list table inet marzban_ips >/dev/null 2>&1; then filter_active=1; fi
active_timers=()
for timer in "${timers[@]}"; do
    if systemctl is-active --quiet "$timer"; then active_timers+=("$timer"); fi
done
changed=0
remove_filter() {
    if nft list table inet marzban_ips >/dev/null 2>&1; then nft delete table inet marzban_ips; fi
}
ready() {
    local attempt
    for ((attempt=0; attempt<100; attempt++)); do
        if systemctl is-active --quiet marzban-suricata.service &&
            awk -v q="$queue" '$1 == q && $2 != 0 {found=1} END {exit !found}' /proc/net/netfilter/nfnetlink_queue 2>/dev/null; then return 0; fi
        sleep 0.2
    done
    return 1
}
rollback() {
    local rc=$?
    if ((changed && rc != 0)); then
        set +e
        echo 'Upgrade failed; restoring the previous package.' >&2
        systemctl stop marzban-ips-filter.service marzban-suricata.service
        remove_filter
        local restore_failed=0
        for file in "${files[@]}"; do
            if [[ -e $backup/files$file ]]; then cp -p -- "$backup/files$file" "$file" || restore_failed=1
            else rm -f -- "$file" || restore_failed=1; fi
        done
        systemctl daemon-reload || restore_failed=1
        if ((engine_active)) && [[ ! -e /etc/marzban-ips/disabled ]]; then
            if systemctl start marzban-suricata.service && ready; then
                if ((filter_active)); then systemctl start marzban-ips-filter.service || restore_failed=1; fi
            else remove_filter; restore_failed=1; fi
        fi
        if ((${#active_timers[@]})); then systemctl start "${active_timers[@]}" || restore_failed=1; fi
        if ((restore_failed)); then
            remove_filter
            echo 'Recovery needs attention; interception removed. Inspect journalctl and the saved backup.' >&2
        fi
    fi
    echo "Package backup: $backup"
    exit "$rc"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
changed=1
systemctl stop "${timers[@]}"
systemctl stop marzban-ips-filter.service
remove_filter
systemctl stop marzban-suricata.service
install -m 0755 "$DIR/marzban-ips" /usr/local/sbin/marzban-ips
for file in ips_helpers.py monitor.py project_update.py; do install -m 0644 "$DIR/$file" "/opt/marzban-ips/$file"; done
install -m 0644 "$DIR/selftest.rules" /etc/marzban-ips/selftest.rules
install -m 0640 "$backup/stage/config.yaml" /etc/suricata/marzban-ips.yaml
install -m 0640 "$backup/stage/suricata.rules" /var/lib/marzban-ips/rules/suricata.rules
install -m 0640 "$backup/stage/queue.nft" /etc/marzban-ips/queue.nft
install -m 0644 "$DIR/marzban-ips.logrotate" /etc/marzban-ips/logrotate.conf
for unit in "${units[@]}"; do
    sed "s/QUEUE_NUMBER/$queue/g" "$DIR/$unit" > "/etc/systemd/system/$unit"
done
systemctl daemon-reload
if ((engine_active)) && [[ ! -e /etc/marzban-ips/disabled ]]; then
    systemctl start marzban-suricata.service
    ready || error 'New engine did not bind NFQUEUE.'
    if ((filter_active)); then systemctl start marzban-ips-filter.service; /usr/local/sbin/marzban-ips apply; fi
fi
if ((${#active_timers[@]})); then systemctl start "${active_timers[@]}"; fi
install -m 0644 "$DIR/VERSION" /etc/marzban-ips/version
changed=0
echo "Marzban IPS upgraded to $new_version. The previous enabled/disabled state was preserved."
