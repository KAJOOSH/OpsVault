#!/usr/bin/env bash
# OpsVault floating-ip
set -euo pipefail

VERSION="2.0.0"
UPDATE_URL="https://raw.githubusercontent.com/KAJOOSH/OpsVault/refs/heads/main/linux/floating-ip/floating-ip.sh"
VERSION_URL="https://raw.githubusercontent.com/KAJOOSH/OpsVault/refs/heads/main/linux/floating-ip/VERSION"
INSTALL_PATH="/usr/local/bin/floating-ip"
CONFIG="/etc/netplan/60-floating-ip.yaml"
STATE_DIR="/etc/floating-ip"
SNAT_CONFIG="$STATE_DIR/snat.tsv"
SERVICE_FILE="/etc/systemd/system/floating-ip-snat.service"
LOCK_FILE="/run/lock/floating-ip.lock"
CHAIN="OPSVAULT_FLOATING_IP"
INTERFACE="${FLOATING_IP_INTERFACE:-eth0}"
WORKDIR=""

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: floating-ip <command>
  install                         Install/upgrade this downloaded script
  update                          Download and install a newer version
  version                         Show this script's version
  add <FLOATING_IP> [--snat]       Add an IP; optionally SNAT the main IP to it
  remove <FLOATING_IP>            Remove an IP and its SNAT mappings
  list                            Show configured floating IPs
  snat add <FLOATING_IP> [SOURCE]  Set/replace SNAT (SOURCE defaults to main IPv4)
  snat remove [SOURCE]            Remove SNAT (SOURCE defaults to main IPv4)
  snat list                       Show saved mappings and active rules
  snat restore                    Reapply saved mappings (also used at boot)

SOURCE accepts IPv4 or CIDR. FLOATING_IP_INTERFACE defaults to eth0.
No command is equivalent to install. Run as root, except help/version.
EOF
}

require_commands() {
    local command
    for command in "$@"; do
        command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
    done
}

validate_ip() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid IPv4: $ip"
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" == 0 || "$octet" != 0* ]] || die "IPv4 octets must not have leading zeros: $ip"
        (( 10#$octet <= 255 )) || die "Invalid IPv4: $ip"
    done
}

validate_interface() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$ ]] || die "Invalid interface: $1"
}

normalize_source() {
    local source="$1" address prefix a b c d number mask
    address="${source%%/*}"
    prefix=32
    [[ "$source" != */* ]] || prefix="${source#*/}"
    validate_ip "$address"
    [[ "$prefix" =~ ^(0|[1-9]|[12][0-9]|3[0-2])$ ]] || die "Invalid CIDR: $source"
    IFS='.' read -r a b c d <<< "$address"
    number=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    number=$(( number & mask ))
    printf '%d.%d.%d.%d/%d\n' "$(( (number >> 24) & 255 ))" \
        "$(( (number >> 16) & 255 ))" "$(( (number >> 8) & 255 ))" "$(( number & 255 ))" "$prefix"
}

get_ips() {
    [[ -f "$CONFIG" ]] || return 0
    sed -nE 's/^[[:space:]]+- ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\/32$/\1/p' "$CONFIG"
}

has_ip() { get_ips | grep -Fxq -- "$1"; }

detect_main_ip() {
    local route source
    require_commands ip
    # Route lookup does not send packets. Detect before adding the floating IP.
    route=$(ip -4 route get 1.1.1.1 oif "$INTERFACE") || die "Cannot find the IPv4 route on $INTERFACE."
    source=$(awk '{for (i=1; i<NF; i++) if ($i == "src") {print $(i+1); exit}}' <<< "$route")
    [[ -n "$source" ]] || die "Route has no source IPv4. Supply SOURCE explicitly."
    validate_ip "$source"
    has_ip "$source" && die "Route selects a floating IP ($source). Supply the main IPv4 explicitly."
    echo "Detected main IPv4: $source ($INTERFACE)" >&2
    printf '%s\n' "$source"
}

atomic_copy() {
    local source="$1" target="$2" mode="$3" staged
    staged=$(mktemp "${target}.tmp.XXXXXX") || return 1
    if ! install -o root -g root -m "$mode" -- "$source" "$staged" || ! mv -f -- "$staged" "$target"; then
        rm -f -- "$staged"
        return 1
    fi
}

update_netplan() {
    local addresses="$1" ip had_config=false
    require_commands netplan
    mkdir -p "$(dirname "$CONFIG")" || return 1
    if [[ -f "$CONFIG" ]]; then
        had_config=true
        cp -p -- "$CONFIG" "$WORKDIR/netplan.previous" || return 1
        cp -p -- "$CONFIG" "$CONFIG.backup.$(date +%Y%m%d-%H%M%S).$$" || return 1
    fi
    {
        printf 'network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    %s:\n' "$INTERFACE"
        if [[ -s "$addresses" ]]; then
            echo '      addresses:'
            while IFS= read -r ip; do
                [[ -z "$ip" ]] || printf '        - %s/32\n' "$ip"
            done < "$addresses"
        else
            echo '      addresses: []'
        fi
    } > "$WORKDIR/netplan.next" || return 1
    atomic_copy "$WORKDIR/netplan.next" "$CONFIG" 600 || return 1
    if netplan generate && netplan apply; then
        return 0
    fi
    echo "Netplan failed; restoring the previous configuration." >&2
    if [[ "$had_config" == true ]]; then
        atomic_copy "$WORKDIR/netplan.previous" "$CONFIG" 600 || return 1
    else
        rm -f -- "$CONFIG" || return 1
    fi
    if ! netplan generate || ! netplan apply; then
        echo "ERROR: Netplan rollback also failed; inspect the network configuration." >&2
    fi
    return 1
}

add_ip() {
    local ip="$1"
    validate_ip "$ip"
    if has_ip "$ip"; then
        echo "IP $ip is already configured."
        return 0
    fi
    { get_ips; echo "$ip"; } | sort -Vu > "$WORKDIR/addresses"
    update_netplan "$WORKDIR/addresses"
    echo "Added $ip/32 on $INTERFACE."
}

require_snat_commands() { require_commands iptables iptables-restore; }

require_snat_setup() {
    require_snat_commands
    require_commands systemctl
    [[ -x "$INSTALL_PATH" ]] || die "Run 'install' first so the boot service can use $INSTALL_PATH."
    grep -Fxq '# OpsVault floating-ip' "$INSTALL_PATH" || die "Upgrade the installed script first."
}

prepare_snat_service() {
    require_snat_setup
    install -d -m 700 -o root -g root "$STATE_DIR"
    cat > "$WORKDIR/snat.service" <<EOF
[Unit]
Description=Restore OpsVault floating IP SNAT mappings
Wants=network-online.target
After=network-online.target netfilter-persistent.service ufw.service docker.service

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH snat restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    atomic_copy "$WORKDIR/snat.service" "$SERVICE_FILE" 644
    systemctl daemon-reload
    systemctl enable floating-ip-snat.service
}

apply_snat() {
    local config="$1" source target interface extra normalized
    require_snat_commands
    (
        printf '*nat\n:%s - [0:0]\n-F %s\n' "$CHAIN" "$CHAIN"
        while read -r source target interface extra; do
            [[ -n "$source" ]] || continue
            [[ -z "$extra" && -n "$target" && -n "$interface" ]] || die "Malformed SNAT configuration."
            normalized=$(normalize_source "$source") || return 1
            [[ "$normalized" == "$source" ]] || die "Noncanonical SNAT source: $source"
            validate_ip "$target"
            validate_interface "$interface"
            has_ip "$target" || die "SNAT target $target is not a configured floating IP."
            printf -- '-A %s -s %s -o %s -m conntrack --ctstate NEW -j SNAT --to-source %s\n' \
                "$CHAIN" "$source" "$interface" "$target"
        done < "$config"
        echo COMMIT
    ) > "$WORKDIR/snat.rules" || return 1
    # Only our chain is replaced. Other NAT/filter chains and policies are preserved.
    iptables-restore --wait 10 --noflush < "$WORKDIR/snat.rules" || return 1
    if ! iptables -w 10 -t nat -C POSTROUTING -m comment --comment opsvault-floating-ip -j "$CHAIN" 2>/dev/null; then
        iptables -w 10 -t nat -I POSTROUTING 1 -m comment --comment opsvault-floating-ip -j "$CHAIN" || return 1
    fi
}

commit_snat() {
    local next="$1" had_config=false
    : > "$WORKDIR/snat.previous"
    if [[ -f "$SNAT_CONFIG" ]]; then
        had_config=true
        cp -- "$SNAT_CONFIG" "$WORKDIR/snat.previous" || return 1
    fi
    atomic_copy "$next" "$SNAT_CONFIG" 600 || return 1
    if apply_snat "$SNAT_CONFIG"; then
        return 0
    fi
    echo "SNAT failed; restoring previous mappings." >&2
    atomic_copy "$WORKDIR/snat.previous" "$SNAT_CONFIG" 600 || return 1
    if ! apply_snat "$SNAT_CONFIG"; then
        echo "ERROR: SNAT rollback failed; run 'floating-ip snat restore' after fixing iptables." >&2
    fi
    [[ "$had_config" == true ]] || rm -f -- "$SNAT_CONFIG"
    return 1
}

snat_add() {
    local target="$1" source="$2"
    validate_ip "$target"
    has_ip "$target" || die "Add floating IP $target first."
    source=$(normalize_source "$source")
    [[ "$source" != "$target/32" ]] || die "SNAT source and target must differ."
    prepare_snat_service
    : > "$WORKDIR/snat.next"
    if [[ -f "$SNAT_CONFIG" ]]; then
        awk -v source="$source" -v interface="$INTERFACE" \
            '!($1 == source && $3 == interface)' "$SNAT_CONFIG" > "$WORKDIR/snat.next"
    fi
    printf '%s\t%s\t%s\n' "$source" "$target" "$INTERFACE" >> "$WORKDIR/snat.next"
    # More-specific CIDRs take priority over broader mappings.
    sort -t / -k2,2nr -s "$WORKDIR/snat.next" > "$WORKDIR/snat.sorted"
    commit_snat "$WORKDIR/snat.sorted"
    echo "SNAT: $source -> $target via $INTERFACE (saved for reboot)."
}

snat_remove() {
    local source
    source=$(normalize_source "$1")
    if [[ ! -f "$SNAT_CONFIG" ]] || ! awk -v s="$source" -v i="$INTERFACE" \
        '$1 == s && $3 == i {found=1} END {exit !found}' "$SNAT_CONFIG"; then
        echo "No SNAT mapping for $source on $INTERFACE."
        return 0
    fi
    awk -v s="$source" -v i="$INTERFACE" '!($1 == s && $3 == i)' "$SNAT_CONFIG" > "$WORKDIR/snat.next"
    commit_snat "$WORKDIR/snat.next"
    echo "Removed SNAT for $source on $INTERFACE."
}

remove_ip() {
    local ip="$1" removed_snat=false
    validate_ip "$ip"
    if has_ip "$ip"; then
        require_commands netplan
    fi
    # Remove dependent SNAT rules before removing the address.
    if [[ -f "$SNAT_CONFIG" ]] && awk -v ip="$ip" '$2 == ip {found=1} END {exit !found}' "$SNAT_CONFIG"; then
        cp -- "$SNAT_CONFIG" "$WORKDIR/snat.before-remove"
        awk -v ip="$ip" '$2 != ip' "$SNAT_CONFIG" > "$WORKDIR/snat.next"
        commit_snat "$WORKDIR/snat.next"
        removed_snat=true
    fi
    if ! has_ip "$ip"; then
        echo "IP $ip is not configured."
        return 0
    fi
    get_ips | awk -v ip="$ip" '$0 != ip' > "$WORKDIR/addresses"
    if update_netplan "$WORKDIR/addresses"; then
        echo "Removed $ip/32 and its SNAT mappings."
    else
        if [[ "$removed_snat" == true ]]; then
            commit_snat "$WORKDIR/snat.before-remove" || echo "ERROR: Could not restore SNAT mappings." >&2
        fi
        return 1
    fi
}

file_version() { sed -nE 's/^VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$1"; }

version_is_newer() {
    local next="$1" current="$2"
    [[ "$next" != "$current" && "$(printf '%s\n%s\n' "$current" "$next" | sort -V | tail -n 1)" == "$next" ]]
}

install_script() {
    local candidate="$1" next current=""
    [[ -s "$candidate" ]] || die "Downloaded script is empty."
    grep -Fxq '# OpsVault floating-ip' "$candidate" || die "Downloaded file is not an OpsVault floating-ip script."
    bash -n "$candidate" || die "Downloaded script has invalid Bash syntax."
    next=$(file_version "$candidate")
    [[ "$next" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Downloaded script has an invalid version."
    if [[ -f "$INSTALL_PATH" ]]; then
        current=$(file_version "$INSTALL_PATH")
        if [[ -n "$current" ]]; then
            if ! version_is_newer "$next" "$current"; then
                echo "Installed version $current is current or newer (download: $next)."
                return 0
            fi
        fi
        atomic_copy "$INSTALL_PATH" "$INSTALL_PATH.backup" 755
    fi
    mkdir -p "$(dirname "$INSTALL_PATH")"
    atomic_copy "$candidate" "$INSTALL_PATH" 755
    echo "Installed floating-ip $next (previous: ${current:-legacy/uninstalled})."
    echo "Netplan addresses and SNAT mappings are preserved."
}

download_file() {
    require_commands curl
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
        --connect-timeout 10 --max-time 120 --retry 2 "$1" -o "$2"
}

download_update() {
    local next current=""
    download_file "$VERSION_URL" "$WORKDIR/VERSION"
    next=$(sed 's/\r$//' "$WORKDIR/VERSION")
    [[ "$next" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "The remote VERSION file is invalid."
    if [[ -f "$INSTALL_PATH" ]]; then
        current=$(file_version "$INSTALL_PATH")
        if [[ -n "$current" ]] && ! version_is_newer "$next" "$current"; then
            echo "Installed version $current is current or newer (available: $next)."
            return 0
        fi
    fi
    download_file "$UPDATE_URL" "$WORKDIR/download.sh"
    [[ "$(file_version "$WORKDIR/download.sh")" == "$next" ]] || die "The downloaded script does not match VERSION; retry after the release is complete."
    install_script "$WORKDIR/download.sh"
}

main() {
    local command="${1:-install}" source
    case "$command" in
        version|--version) [[ $# -eq 1 ]] || { usage; exit 1; }; echo "$VERSION"; return ;;
        help|--help|-h) usage; return ;;
    esac
    [[ $EUID -eq 0 ]] || die "Run this script as root."
    umask 077
    validate_interface "$INTERFACE"
    require_commands flock
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9> "$LOCK_FILE"
    flock -x 9
    WORKDIR=$(mktemp -d /tmp/floating-ip.XXXXXXXX)
    trap 'rm -rf -- "$WORKDIR"' EXIT
    case "$command" in
        install)
            [[ $# -le 1 ]] || die "install takes no arguments."
            if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
                install_script "${BASH_SOURCE[0]}"
            else
                download_update
            fi
            ;;
        update)
            [[ $# -eq 1 ]] || die "update takes no arguments."
            download_update
            ;;
        add)
            [[ $# -eq 2 || ( $# -eq 3 && "$3" == --snat ) ]] || { usage; exit 1; }
            validate_ip "$2"
            if [[ $# -eq 3 ]]; then
                require_commands netplan
                require_snat_commands
                source=$(detect_main_ip)
                [[ "$source" != "$2" ]] || die "Floating IP must differ from the main IPv4."
                require_snat_setup
            fi
            add_ip "$2"
            [[ $# -ne 3 ]] || snat_add "$2" "$source"
            ;;
        remove) [[ $# -eq 2 ]] || { usage; exit 1; }; remove_ip "$2" ;;
        list) [[ $# -eq 1 ]] || { usage; exit 1; }; echo 'Floating IPs:'; get_ips ;;
        snat)
            case "${2:-}" in
                add)
                    [[ $# -eq 3 || $# -eq 4 ]] || { usage; exit 1; }
                    source="${4:-}"
                    [[ -n "$source" ]] || source=$(detect_main_ip)
                    snat_add "$3" "$source"
                    ;;
                remove)
                    [[ $# -eq 2 || $# -eq 3 ]] || { usage; exit 1; }
                    source="${3:-}"
                    [[ -n "$source" ]] || source=$(detect_main_ip)
                    snat_remove "$source"
                    ;;
                list)
                    [[ $# -eq 2 ]] || { usage; exit 1; }
                    echo 'Saved SNAT mappings (SOURCE -> FLOATING_IP via INTERFACE):'
                    if [[ -s "$SNAT_CONFIG" ]]; then
                        awk '{printf "%s -> %s via %s\n", $1, $2, $3}' "$SNAT_CONFIG"
                        require_snat_commands
                        iptables -w 10 -t nat -L "$CHAIN" -n -v
                    else
                        echo 'No saved SNAT mappings.'
                    fi
                    ;;
                restore)
                    [[ $# -eq 2 ]] || { usage; exit 1; }
                    [[ ! -f "$SNAT_CONFIG" ]] || apply_snat "$SNAT_CONFIG"
                    ;;
                *) usage; exit 1 ;;
            esac
            ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
