#!/usr/bin/env bash
# Run only in an isolated container. All external commands and paths are fixtures.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
box="$(mktemp -d)"
trap 'rm -rf -- "$box"' EXIT
mkdir -p "$box/bin" "$box/etc/marzban-ips" "$box/etc/suricata" "$box/var/lib/marzban-ips/rules" \
    "$box/var/log/marzban-suricata" "$box/run/lock" "$box/proc/net/netfilter" "$box/etc/systemd/system"
export IPS_BOX="$box"
# Relocate a disposable CLI copy; the original stays read-only.
sed -e "s|export PATH=.*|export PATH=$box/bin:/usr/bin:/bin|" \
    -e "s|/etc/|$box/etc/|g" -e "s|/var/|$box/var/|g" -e "s|/opt/|$box/opt/|g" \
    -e "s|/run/lock/|$box/run/lock/|g" -e "s|/proc/net/netfilter/|$box/proc/net/netfilter/|g" \
    -e "s|/usr/local/sbin/marzban-ips|$box/ips|g" "$ROOT/marzban-ips" > "$box/ips"
chmod +x "$box/ips"
cat > "$box/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$IPS_BOX/calls"
case "$1" in
 is-active|is-enabled) [[ -e $IPS_BOX/active ]] ;;
 restart) [[ ! -e $IPS_BOX/restart-fail ]] ;;
 *) exit 0 ;;
esac
STUB
cat > "$box/bin/nft" <<'STUB'
#!/usr/bin/env bash
echo "nft $*" >> "$IPS_BOX/calls"
case "$1" in
 list) [[ -e $IPS_BOX/table ]] ;;
 delete) rm -f "$IPS_BOX/table" ;;
 -f) touch "$IPS_BOX/table" ;;
 *) exit 0 ;;
esac
STUB
cat > "$box/bin/python3" <<'STUB'
#!/usr/bin/env bash
echo "python3 $*" >> "$IPS_BOX/calls"
case "$2" in
 select) printf 'drop tcp any any -> any any (sid:1;)\n' > "$4" ;;
 refresh) echo unchanged ;;
 *) exit 0 ;;
esac
STUB
cat > "$box/bin/suricata-update" <<'STUB'
#!/usr/bin/env bash
echo "suricata-update $*" >> "$IPS_BOX/calls"
[[ ! -e $IPS_BOX/download-fail ]] || exit 1
STUB
cat > "$box/bin/suricata" <<'STUB'
#!/usr/bin/env bash
echo "suricata $*" >> "$IPS_BOX/calls"
[[ ! -e $IPS_BOX/test-fail ]] || exit 1
STUB
cat > "$box/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$box/bin/"*
printf '150\n' > "$box/etc/marzban-ips/queue-number"
printf '150 123 0 2 65535 0 0 0\n' > "$box/proc/net/netfilter/nfnetlink_queue"
touch "$box/etc/suricata/marzban-ips.yaml" "$box/etc/marzban-ips/queue.nft" "$box/active"
echo previous > "$box/var/lib/marzban-ips/rules/suricata.rules"
run() { bash "$box/ips" "$@"; }
run apply
[[ -e $box/table ]] || { echo 'FAIL: ready engine did not attach filter'; exit 1; }
rm "$box/active" "$box/table"
if run apply; then echo 'FAIL: attached without listener'; exit 1; fi
[[ ! -e $box/table ]]
echo 'PASS: filter attaches only with an active listener'
touch "$box/table" "$box/active"
run disable
[[ ! -e $box/table && -e $box/etc/marzban-ips/disabled ]]
grep -q 'systemctl disable --now marzban-ips-filter.service marzban-suricata.service' "$box/calls"
echo 'PASS: emergency disable removes filter and persists disabled state'
run enable
[[ -e $box/table && ! -e $box/etc/marzban-ips/disabled ]]
echo 'PASS: enable restores interception after emergency disable'
touch "$box/download-fail"
if run update; then echo 'FAIL: accepted failed download'; exit 1; fi
[[ $(cat "$box/var/lib/marzban-ips/rules/suricata.rules") == previous ]]
rm "$box/download-fail"
touch "$box/test-fail"
if run update; then echo 'FAIL: accepted invalid rules'; exit 1; fi
[[ $(cat "$box/var/lib/marzban-ips/rules/suricata.rules") == previous ]]
rm "$box/test-fail"
echo 'PASS: failed download and validation leave live rules unchanged'
touch "$box/etc/marzban-ips/disabled"
: > "$box/calls"
run update
if grep -q 'systemctl restart' "$box/calls"; then echo 'FAIL: update restarted disabled IPS'; exit 1; fi
echo 'PASS: update honors a persistent emergency disable'
rm "$box/etc/marzban-ips/disabled"
: > "$box/calls"
run update
if grep -q 'systemctl restart' "$box/calls"; then echo 'FAIL: unchanged rules restarted IPS'; exit 1; fi
echo 'PASS: unchanged selected rules do not restart the engine'
echo previous > "$box/var/lib/marzban-ips/rules/suricata.rules"
touch "$box/restart-fail" "$box/table"
if run update; then echo 'FAIL: accepted failed engine restart'; exit 1; fi
[[ $(cat "$box/var/lib/marzban-ips/rules/suricata.rules") == previous && ! -e $box/table ]]
echo 'PASS: failed engine restart rolls back rules and removes interception'
rm "$box/restart-fail"
touch "$box/etc/marzban-ips/installed"
run uninstall
[[ ! -e $box/etc/marzban-ips/installed && ! -e $box/etc/suricata/marzban-ips.yaml ]]
[[ -e $box/var/lib/marzban-ips/rules/suricata.rules ]]
echo 'PASS: uninstall removes owned configuration and retains rule evidence'
