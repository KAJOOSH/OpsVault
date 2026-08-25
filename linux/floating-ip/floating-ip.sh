#!/usr/bin/env bash

set -euo pipefail

CONFIG="/etc/netplan/60-floating-ip.yaml"
INTERFACE="eth0"

usage() {
    echo
    echo "Usage:"
    echo "  $0 add <IPv4>"
    echo "  $0 remove <IPv4>"
    echo "  $0 list"
    echo
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Run this script as root."
        exit 1
    fi
}

validate_ip() {
    local ip="$1"

    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "ERROR: Invalid IPv4 address: $ip"
        exit 1
    fi

    IFS='.' read -r a b c d <<< "$ip"

    for octet in "$a" "$b" "$c" "$d"; do
        if (( octet < 0 || octet > 255 )); then
            echo "ERROR: Invalid IPv4 address: $ip"
            exit 1
        fi
    done
}

get_ips() {
    [[ -f "$CONFIG" ]] || return 0

    grep -E '^[[:space:]]+- [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32$' "$CONFIG" \
        | sed -E 's/^[[:space:]]+- //; s#/32$##' \
        || true
}

write_config() {
    local temp_file

    temp_file=$(mktemp)

    {
        echo "network:"
        echo "  version: 2"
        echo "  renderer: networkd"
        echo "  ethernets:"
        echo "    $INTERFACE:"
        echo "      addresses:"

        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            echo "        - $ip/32"
        done
    } > "$temp_file"

    chown root:root "$temp_file"
    chmod 600 "$temp_file"

    if [[ -f "$CONFIG" ]]; then
        cp "$CONFIG" "$CONFIG.backup.$(date +%Y%m%d-%H%M%S)"
    fi

    mv "$temp_file" "$CONFIG"
}

apply_config() {
    chmod 600 "$CONFIG"
    chown root:root "$CONFIG"

    echo "Validating Netplan configuration..."
    netplan generate

    echo "Applying network configuration..."
    netplan apply
}

add_ip() {
    local ip="$1"

    validate_ip "$ip"

    mkdir -p /etc/netplan

    mapfile -t ips < <(get_ips)

    for existing in "${ips[@]}"; do
        if [[ "$existing" == "$ip" ]]; then
            echo "IP $ip is already configured."
            return 0
        fi
    done

    ips+=("$ip")

    printf '%s\n' "${ips[@]}" | sort -V > /tmp/floating-ips.txt

    write_config_from_file

    echo "Added $ip/32"
    apply_config
}

remove_ip() {
    local ip="$1"

    validate_ip "$ip"

    if [[ ! -f "$CONFIG" ]]; then
        echo "No Floating IP configuration exists."
        return 0
    fi

    mapfile -t ips < <(get_ips)

    local found=false
    local remaining=()

    for existing in "${ips[@]}"; do
        if [[ "$existing" == "$ip" ]]; then
            found=true
        else
            remaining+=("$existing")
        fi
    done

    if [[ "$found" == false ]]; then
        echo "IP $ip is not configured."
        return 0
    fi

    printf '%s\n' "${remaining[@]}" | sort -V > /tmp/floating-ips.txt

    write_config_from_file

    echo "Removed $ip/32"
    apply_config
}

write_config_from_file() {
    local temp_file

    temp_file=$(mktemp)

    {
        echo "network:"
        echo "  version: 2"
        echo "  renderer: networkd"
        echo "  ethernets:"
        echo "    $INTERFACE:"
        echo "      addresses:"

        if [[ -s /tmp/floating-ips.txt ]]; then
            while IFS= read -r ip; do
                [[ -z "$ip" ]] && continue
                echo "        - $ip/32"
            done < /tmp/floating-ips.txt
        fi
    } > "$temp_file"

    chown root:root "$temp_file"
    chmod 600 "$temp_file"

    if [[ -f "$CONFIG" ]]; then
        cp "$CONFIG" "$CONFIG.backup.$(date +%Y%m%d-%H%M%S)"
    fi

    mv "$temp_file" "$CONFIG"

    rm -f /tmp/floating-ips.txt
}

list_ips() {
    echo "Floating IPs:"
    echo

    local ips
    ips=$(get_ips)

    if [[ -z "$ips" ]]; then
        echo "No Floating IPs configured."
    else
        echo "$ips"
    fi
}

main() {
    require_root

    case "${1:-}" in
        add)
            [[ $# -eq 2 ]] || usage
            add_ip "$2"
            ;;
        remove)
            [[ $# -eq 2 ]] || usage
            remove_ip "$2"
            ;;
        list)
            [[ $# -eq 1 ]] || usage
            list_ips
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"