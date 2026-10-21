#!/usr/bin/env bash
# Isolated command-level tests: no real networking, root access or systemd needed.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SUITE_ROOT=$(mktemp -d)
trap 'rm -rf -- "$SUITE_ROOT"' EXIT
export TEST_ROOT TEST_MAIN_IP TEST_DOWNLOAD TEST_VERSION_DOWNLOAD
mkdir -p "$SUITE_ROOT/mocks"

cat > "$SUITE_ROOT/mocks/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
directory=false
while (($#)); do
    case "$1" in
        -o|-g|-m) shift 2 ;;
        -d) directory=true; shift ;;
        --) shift ;;
        *) args+=("$1"); shift ;;
    esac
done
if [[ "$directory" == true ]]; then
    mkdir -p -- "${args[@]}"
else
    cp -- "${args[@]}"
    chmod +x -- "${args[@]: -1}"
fi
EOF

cat > "$SUITE_ROOT/mocks/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$SUITE_ROOT/mocks/ip" <<'EOF'
#!/usr/bin/env bash
echo "ip $*" >> "$TEST_ROOT/commands.log"
[[ ! -f "$TEST_ROOT/fail-route" ]] || exit 1
[[ "$*" == "-4 route get 1.1.1.1 oif "* ]] || exit 2
printf '1.1.1.1 via 5.75.198.193 dev %s src %s uid 0\n' "${*: -1}" "$TEST_MAIN_IP"
EOF

cat > "$SUITE_ROOT/mocks/netplan" <<'EOF'
#!/usr/bin/env bash
echo "netplan $*" >> "$TEST_ROOT/commands.log"
if [[ -f "$TEST_ROOT/fail-netplan-$1" ]]; then
    rm -f "$TEST_ROOT/fail-netplan-$1"
    exit 1
fi
EOF

cat > "$SUITE_ROOT/mocks/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$TEST_ROOT/commands.log"
EOF

cat > "$SUITE_ROOT/mocks/iptables" <<'EOF'
#!/usr/bin/env bash
echo "iptables $*" >> "$TEST_ROOT/commands.log"
case "$*" in
    *" -C POSTROUTING "*) [[ -f "$TEST_ROOT/jump" ]] ;;
    *" -I POSTROUTING 1 "*) touch "$TEST_ROOT/jump" ;;
    *" -L OPSVAULT_FLOATING_IP "*) cat "$TEST_ROOT/rules.active" ;;
    *) exit 2 ;;
esac
EOF

cat > "$SUITE_ROOT/mocks/iptables-restore" <<'EOF'
#!/usr/bin/env bash
echo "iptables-restore $*" >> "$TEST_ROOT/commands.log"
[[ "$*" == "--wait 10 --noflush" ]] || exit 2
cat > "$TEST_ROOT/rules.next"
if [[ -f "$TEST_ROOT/fail-restore" ]]; then
    rm -f "$TEST_ROOT/fail-restore"
    exit 1
fi
mv -f "$TEST_ROOT/rules.next" "$TEST_ROOT/rules.active"
EOF

cat > "$SUITE_ROOT/mocks/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "curl $*" >> "$TEST_ROOT/commands.log"
output=""
url=""
while (($#)); do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[[ -n "$output" ]] || exit 2
if [[ -f "$TEST_ROOT/fail-download" ]]; then
    echo partial > "$output"
    exit 22
fi
if [[ "$url" == */VERSION ]]; then
    cp -- "$TEST_VERSION_DOWNLOAD" "$output"
else
    cp -- "$TEST_DOWNLOAD" "$output"
fi
EOF

chmod +x "$SUITE_ROOT"/mocks/*
export PATH="$SUITE_ROOT/mocks:$PATH"

reset_case() {
    TEST_ROOT=$(mktemp -d "$SUITE_ROOT/case.XXXXXXXX")
    TEST_MAIN_IP=5.75.198.197
    TEST_DOWNLOAD="$TEST_ROOT/download.sh"
    TEST_VERSION_DOWNLOAD="$TEST_ROOT/remote.VERSION"
    cp "$SCRIPT_DIR/VERSION" "$TEST_VERSION_DOWNLOAD"
    unset FLOATING_IP_INTERFACE
    mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/netplan" "$TEST_ROOT/systemd"
    : > "$TEST_ROOT/commands.log"
    # Only this private copy bypasses root and uses sandboxed system paths.
    sed \
        -e 's|INSTALL_PATH="/usr/local/bin/floating-ip"|INSTALL_PATH="$TEST_ROOT/bin/floating-ip"|' \
        -e 's|CONFIG="/etc/netplan/60-floating-ip.yaml"|CONFIG="$TEST_ROOT/netplan/60-floating-ip.yaml"|' \
        -e 's|STATE_DIR="/etc/floating-ip"|STATE_DIR="$TEST_ROOT/state"|' \
        -e 's|SERVICE_FILE="/etc/systemd/system/floating-ip-snat.service"|SERVICE_FILE="$TEST_ROOT/systemd/floating-ip-snat.service"|' \
        -e 's|LOCK_FILE="/run/lock/floating-ip.lock"|LOCK_FILE="$TEST_ROOT/floating-ip.lock"|' \
        -e 's|\[\[ $EUID -eq 0 \]\]|[[ 0 -eq 0 ]]|' \
        -e 's|mktemp -d /tmp/floating-ip.XXXXXXXX|mktemp -d "$TEST_ROOT/work.XXXXXXXX"|' \
        "$SCRIPT_DIR/floating-ip.sh" > "$TEST_ROOT/entry.sh"
    chmod +x "$TEST_ROOT/entry.sh"
}

run() { bash "$TEST_ROOT/entry.sh" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$1 is missing: $2"; }
absent() { if grep -Fq -- "$2" "$1"; then fail "$1 unexpectedly contains: $2"; fi; }
expect_failure() {
    if "$@" > "$TEST_ROOT/failure.out" 2>&1; then fail "Expected failure: $*"; fi
}
pass() { printf 'PASS: %s\n' "$1"; }

[[ $(cat "$SCRIPT_DIR/VERSION") == $(sed -nE 's/^VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$SCRIPT_DIR/floating-ip.sh") ]] || fail 'release VERSION and script disagree'

reset_case
run > /dev/null
contains "$TEST_ROOT/bin/floating-ip" 'VERSION="2.0.0"'
run add 167.233.190.39 --snat > /dev/null
contains "$TEST_ROOT/state/snat.tsv" $'5.75.198.197/32\t167.233.190.39\teth0'
contains "$TEST_ROOT/rules.active" '-s 5.75.198.197/32 -o eth0 -m conntrack --ctstate NEW -j SNAT --to-source 167.233.190.39'
contains "$TEST_ROOT/systemd/floating-ip-snat.service" "ExecStart=$TEST_ROOT/bin/floating-ip snat restore"
contains "$TEST_ROOT/commands.log" 'systemctl enable floating-ip-snat.service'
contains "$TEST_ROOT/commands.log" 'ip -4 route get 1.1.1.1 oif eth0'
pass 'automatic main IPv4, combined add and persistent service'

cp "$TEST_ROOT/rules.active" "$TEST_ROOT/rules.expected"
run add 167.233.190.39 --snat > /dev/null
[[ $(wc -l < "$TEST_ROOT/state/snat.tsv") -eq 1 ]] || fail 'duplicate mapping'
[[ $(grep -c -- '-I POSTROUTING' "$TEST_ROOT/commands.log") -eq 1 ]] || fail 'duplicate jump'
cmp "$TEST_ROOT/rules.expected" "$TEST_ROOT/rules.active"
run snat list > "$TEST_ROOT/list.out"
contains "$TEST_ROOT/list.out" '5.75.198.197/32 -> 167.233.190.39 via eth0'
pass 'repeated add is idempotent and list includes mappings'

run add 167.233.190.40 > /dev/null
run snat add 167.233.190.40 > /dev/null
[[ $(wc -l < "$TEST_ROOT/state/snat.tsv") -eq 1 ]] || fail 'mapping was not replaced'
contains "$TEST_ROOT/state/snat.tsv" $'5.75.198.197/32\t167.233.190.40'
absent "$TEST_ROOT/state/snat.tsv" '167.233.190.39'
pass 'changing the floating IP replaces the existing source mapping'

run snat add 167.233.190.39 10.8.0.99/24 > /dev/null
run snat add 167.233.190.40 10.8.0.8 > /dev/null
contains "$TEST_ROOT/state/snat.tsv" $'10.8.0.0/24\t167.233.190.39'
[[ $(head -n 2 "$TEST_ROOT/state/snat.tsv" | grep -c '/32') -eq 2 ]] || fail 'CIDR priority'
pass 'VPN CIDRs are canonicalized and narrower prefixes take priority'

cp "$TEST_ROOT/rules.active" "$TEST_ROOT/rules.expected"
rm "$TEST_ROOT/rules.active" "$TEST_ROOT/jump"
bash "$TEST_ROOT/bin/floating-ip" snat restore
cmp "$TEST_ROOT/rules.expected" "$TEST_ROOT/rules.active"
[[ -f "$TEST_ROOT/jump" ]] || fail 'jump was not restored'
pass 'boot restore recreates the saved rules and jump'

cp "$TEST_ROOT/state/snat.tsv" "$TEST_ROOT/snat.valid"
cp "$TEST_ROOT/rules.active" "$TEST_ROOT/rules.expected"
printf 'invalid\t167.233.190.39\teth0\n' > "$TEST_ROOT/state/snat.tsv"
expect_failure run snat restore
cmp "$TEST_ROOT/rules.expected" "$TEST_ROOT/rules.active"
cp "$TEST_ROOT/snat.valid" "$TEST_ROOT/state/snat.tsv"
pass 'invalid saved state is rejected before touching active rules'

cp "$TEST_ROOT/state/snat.tsv" "$TEST_ROOT/snat.expected"
cp "$TEST_ROOT/rules.active" "$TEST_ROOT/rules.expected"
touch "$TEST_ROOT/fail-restore"
expect_failure run snat add 167.233.190.39
cmp "$TEST_ROOT/snat.expected" "$TEST_ROOT/state/snat.tsv"
cmp "$TEST_ROOT/rules.expected" "$TEST_ROOT/rules.active"
pass 'iptables failure restores the previous persisted and active mappings'

cp "$TEST_ROOT/netplan/60-floating-ip.yaml" "$TEST_ROOT/netplan.expected"
touch "$TEST_ROOT/fail-netplan-apply"
expect_failure run remove 167.233.190.40
cmp "$TEST_ROOT/netplan.expected" "$TEST_ROOT/netplan/60-floating-ip.yaml"
cmp "$TEST_ROOT/snat.expected" "$TEST_ROOT/state/snat.tsv"
cmp "$TEST_ROOT/rules.expected" "$TEST_ROOT/rules.active"
pass 'failed address removal rolls back Netplan and dependent SNAT mappings'

run snat remove > /dev/null
absent "$TEST_ROOT/state/snat.tsv" '5.75.198.197/32'
contains "$TEST_ROOT/netplan/60-floating-ip.yaml" '167.233.190.40/32'
run remove 167.233.190.39 > /dev/null
absent "$TEST_ROOT/state/snat.tsv" '167.233.190.39'
run remove 167.233.190.40 > /dev/null
contains "$TEST_ROOT/netplan/60-floating-ip.yaml" 'addresses: []'
[[ ! -s "$TEST_ROOT/state/snat.tsv" ]] || fail 'dependent mappings remain'
absent "$TEST_ROOT/rules.active" '-j SNAT'
pass 'automatic source removal, dependent cleanup and last address removal'

reset_case
run install > /dev/null
touch "$TEST_ROOT/fail-netplan-generate"
expect_failure run add 167.233.190.39
[[ ! -f "$TEST_ROOT/netplan/60-floating-ip.yaml" ]] || fail 'failed initial Netplan config remains'
pass 'failed first address addition restores the absence of a configuration'

expect_failure run add 999.1.2.3
expect_failure run add 001.2.3.4
run add 167.233.190.39 > /dev/null
expect_failure run snat add 167.233.190.39 '1.2.3.4/99'
expect_failure run snat add 167.233.190.39 '1.2.3.4;echo injected'
touch "$TEST_ROOT/fail-route"
expect_failure run snat add 167.233.190.39
rm "$TEST_ROOT/fail-route"
TEST_MAIN_IP=167.233.190.39
expect_failure run snat add 167.233.190.39
[[ ! -f "$TEST_ROOT/state/snat.tsv" ]] || fail 'invalid input changed SNAT state'
pass 'invalid addresses, CIDRs, route failures and floating source are rejected'

reset_case
run install > /dev/null
export FLOATING_IP_INTERFACE=ens3
run add 167.233.190.39 --snat > /dev/null
contains "$TEST_ROOT/netplan/60-floating-ip.yaml" 'ens3:'
contains "$TEST_ROOT/state/snat.tsv" $'5.75.198.197/32\t167.233.190.39\tens3'
unset FLOATING_IP_INTERFACE
bash "$TEST_ROOT/bin/floating-ip" snat restore
contains "$TEST_ROOT/rules.active" '-o ens3'
pass 'alternative interface is saved and survives environment-free restore'

reset_case
printf '#!/usr/bin/env bash\necho legacy\n' > "$TEST_ROOT/bin/floating-ip"
cp "$TEST_ROOT/bin/floating-ip" "$TEST_ROOT/legacy.expected"
run install > /dev/null
cmp "$TEST_ROOT/legacy.expected" "$TEST_ROOT/bin/floating-ip.backup"
run add 167.233.190.39 --snat > /dev/null
cp "$TEST_ROOT/netplan/60-floating-ip.yaml" "$TEST_ROOT/netplan.expected"
cp "$TEST_ROOT/state/snat.tsv" "$TEST_ROOT/snat.expected"
cp "$TEST_ROOT/bin/floating-ip" "$TEST_ROOT/installed.expected"
sed 's/^VERSION="2.0.0"$/VERSION="2.0.1"/' "$TEST_ROOT/entry.sh" > "$TEST_DOWNLOAD"
echo 2.0.1 > "$TEST_VERSION_DOWNLOAD"
run update > /dev/null
contains "$TEST_ROOT/bin/floating-ip" 'VERSION="2.0.1"'
[[ $(bash "$TEST_ROOT/bin/floating-ip" version) == 2.0.1 ]] || fail 'version command'
cmp "$TEST_ROOT/installed.expected" "$TEST_ROOT/bin/floating-ip.backup"
cmp "$TEST_ROOT/netplan.expected" "$TEST_ROOT/netplan/60-floating-ip.yaml"
cmp "$TEST_ROOT/snat.expected" "$TEST_ROOT/state/snat.tsv"
pass 'legacy migration and newer upgrade preserve addresses and SNAT'

cp "$TEST_ROOT/bin/floating-ip" "$TEST_ROOT/installed.expected"
cp "$TEST_ROOT/bin/floating-ip.backup" "$TEST_ROOT/backup.expected"
: > "$TEST_ROOT/commands.log"
run update > /dev/null
contains "$TEST_ROOT/commands.log" '/floating-ip/VERSION'
absent "$TEST_ROOT/commands.log" '/floating-ip/floating-ip.sh'
cmp "$TEST_ROOT/backup.expected" "$TEST_ROOT/bin/floating-ip.backup"
cp "$TEST_ROOT/entry.sh" "$TEST_DOWNLOAD"
echo 2.0.0 > "$TEST_VERSION_DOWNLOAD"
run update > /dev/null
absent "$TEST_ROOT/commands.log" '/floating-ip/floating-ip.sh'
cmp "$TEST_ROOT/installed.expected" "$TEST_ROOT/bin/floating-ip"
cmp "$TEST_ROOT/backup.expected" "$TEST_ROOT/bin/floating-ip.backup"
pass 'same version and downgrades only fetch VERSION and preserve the backup'

for invalid_version in '' '<html>error</html>' '2.1.0;echo unsafe' $'2.1.0\n2.2.0'; do
    printf '%s\n' "$invalid_version" > "$TEST_VERSION_DOWNLOAD"
    expect_failure run update
done
cmp "$TEST_ROOT/installed.expected" "$TEST_ROOT/bin/floating-ip"
absent "$TEST_ROOT/commands.log" '/floating-ip/floating-ip.sh'
pass 'invalid VERSION manifests are rejected before downloading the script'

echo 2.1.0 > "$TEST_VERSION_DOWNLOAD"
touch "$TEST_ROOT/fail-download"
expect_failure run update
rm "$TEST_ROOT/fail-download"
: > "$TEST_DOWNLOAD"
expect_failure run update
echo '<html>error</html>' > "$TEST_DOWNLOAD"
expect_failure run update
sed 's/^VERSION="2.0.0"$/VERSION="2.1.0"/' "$TEST_ROOT/entry.sh" > "$TEST_DOWNLOAD"
echo 'if' >> "$TEST_DOWNLOAD"
expect_failure run update
cmp "$TEST_ROOT/installed.expected" "$TEST_ROOT/bin/floating-ip"
cmp "$TEST_ROOT/backup.expected" "$TEST_ROOT/bin/floating-ip.backup"
pass 'partial, empty, invalid and syntactically broken downloads leave install intact'

sed 's/^VERSION="2.0.0"$/VERSION="2.1.0"/' "$TEST_ROOT/entry.sh" > "$TEST_DOWNLOAD"
echo 2.2.0 > "$TEST_VERSION_DOWNLOAD"
expect_failure run update
cmp "$TEST_ROOT/installed.expected" "$TEST_ROOT/bin/floating-ip"
cmp "$TEST_ROOT/backup.expected" "$TEST_ROOT/bin/floating-ip.backup"
pass 'script and VERSION mismatch preserves the installed version and backup'

printf '2.1.0\r\n' > "$TEST_VERSION_DOWNLOAD"
cat "$TEST_ROOT/entry.sh" | bash -s -- install > /dev/null
contains "$TEST_ROOT/bin/floating-ip" 'VERSION="2.1.0"'
pass 'rerunning the download through stdin installs a newer version'

echo 'All isolated floating-ip scenarios passed.'
