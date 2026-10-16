#!/usr/bin/env bash
# Isolated fixtures only: never run this as a deployment script.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
box="$(mktemp -d)"
trap 'rm -rf -- "$box"' EXIT
export IPS_BOX="$box"
mkdir -p "$box"/{bundle,bin,etc/marzban-ips,etc/suricata,etc/systemd/system,opt/marzban-ips,usr/local/sbin,run/lock,proc/net/netfilter,var/lib/marzban-ips/rules}
for file in "$ROOT"/*; do if [[ -f $file ]]; then cp -- "$file" "$box/bundle/"; fi; done
relocate() {
    sed -e "s|export PATH=.*|export PATH=$box/bin:/usr/bin:/bin|" \
        -e "s|/etc/|$box/etc/|g" -e "s|/var/|$box/var/|g" -e "s|/opt/|$box/opt/|g" \
        -e "s|/run/lock/|$box/run/lock/|g" -e "s|/proc/net/netfilter/|$box/proc/net/netfilter/|g" \
        -e "s|/usr/local/sbin/marzban-ips|$box/usr/local/sbin/marzban-ips|g" "$1" > "$2"
}
relocate "$ROOT/upgrade.sh" "$box/bundle/upgrade.sh"
relocate "$ROOT/marzban-ips" "$box/bundle/marzban-ips"
printf 'ID=ubuntu\nVERSION_ID=22.04\n' > "$box/etc/os-release"
printf '150\n' > "$box/etc/marzban-ips/queue-number"
printf '150 123 0 2 65535 0 0 0\n' > "$box/proc/net/netfilter/nfnetlink_queue"
touch "$box/etc/marzban-ips/installed" "$box/active" "$box/table"
echo 2.0.0 > "$box/etc/marzban-ips/version"
echo original-config > "$box/etc/suricata/marzban-ips.yaml"
echo original-code > "$box/usr/local/sbin/marzban-ips"
echo original-helper > "$box/opt/marzban-ips/ips_helpers.py"
echo original-rules > "$box/var/lib/marzban-ips/rules/suricata.rules"
cat > "$box/bin/python3" <<'STUB'
#!/usr/bin/env bash
case "$1" in
 -c) exit 0 ;;
 -) cp -- "$2" "$4" ;;
 *) case "$2" in
     configure) echo new-config > "$4" ;;
     refresh) echo unchanged ;;
    esac ;;
esac
STUB
cat > "$box/bin/suricata" <<'STUB'
#!/usr/bin/env bash
[[ ! -e $IPS_BOX/validation-fail ]]
STUB
cat > "$box/bin/nft" <<'STUB'
#!/usr/bin/env bash
case "$1" in
 list) [[ -e $IPS_BOX/table ]] ;;
 delete) rm -f -- "$IPS_BOX/table" ;;
 -f) touch "$IPS_BOX/table" ;;
 *) exit 0 ;;
esac
STUB
cat > "$box/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$IPS_BOX/calls"
case "$1" in
 is-active|is-enabled) [[ -e $IPS_BOX/active ]] ;;
 start)
    if [[ $2 == marzban-suricata.service && -e $IPS_BOX/fail-next-start ]]; then
        rm -f -- "$IPS_BOX/fail-next-start"
        exit 1
    fi
    if [[ $2 == marzban-ips-filter.service ]]; then touch "$IPS_BOX/table"; fi
    ;;
 *) exit 0 ;;
esac
STUB
cat > "$box/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$box/bin/"*
run() { bash "$box/bundle/upgrade.sh"; }
touch "$box/validation-fail"
if run; then echo 'FAIL: validation failure accepted'; exit 1; fi
[[ $(cat "$box/etc/marzban-ips/version") == 2.0.0 && $(cat "$box/usr/local/sbin/marzban-ips") == original-code && -e $box/table ]]
rm "$box/validation-fail"
echo 'PASS: candidate rejection leaves old code, version and firewall unchanged'
touch "$box/fail-next-start"
if run; then echo 'FAIL: startup failure accepted'; exit 1; fi
[[ $(cat "$box/etc/marzban-ips/version") == 2.0.0 && $(cat "$box/usr/local/sbin/marzban-ips") == original-code ]]
[[ $(cat "$box/etc/suricata/marzban-ips.yaml") == original-config ]]
[[ $(cat "$box/var/lib/marzban-ips/rules/suricata.rules") == original-rules && -e $box/table ]]
echo 'PASS: failed new engine rolls back code, configuration, rules and interception'
run
[[ $(cat "$box/etc/marzban-ips/version") == 2.1.1 && -e $box/table ]]
[[ -s $box/opt/marzban-ips/monitor.py && -s $box/opt/marzban-ips/project_update.py ]]
echo 'PASS: Ubuntu 22.04 upgrade publishes new version and restores active interception'
touch "$box/etc/marzban-ips/disabled"
rm -f -- "$box/table"
: > "$box/calls"
run
[[ -e $box/etc/marzban-ips/disabled && ! -e $box/table ]]
if grep -Eq '^start marzban-(suricata|ips-filter)\.service' "$box/calls"; then echo 'FAIL: disabled engine started'; exit 1; fi
echo 'PASS: upgrade preserves emergency disabled state'
printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$box/etc/os-release"
run >/dev/null
printf 'ID=ubuntu\nVERSION_ID=26.04\n' > "$box/etc/os-release"
run >/dev/null
printf 'ID=ubuntu\nVERSION_ID=20.04\n' > "$box/etc/os-release"
if run; then echo 'FAIL: accepted Ubuntu older than 22.04'; exit 1; fi
echo 'PASS: version gate accepts 22.04/24.04/26.04 and rejects 20.04'
