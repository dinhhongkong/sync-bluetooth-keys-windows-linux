#!/usr/bin/env bash

set -euo pipefail

usage() {
    printf 'Usage: sudo %s [windows-reg-file] [device-mac]\n' "${0##*/}" >&2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

format_mac() {
    local raw=${1^^}
    printf '%s:%s:%s:%s:%s:%s' \
        "${raw:0:2}" "${raw:2:2}" "${raw:4:2}" \
        "${raw:6:2}" "${raw:8:2}" "${raw:10:2}"
}

if [[ $# -gt 2 ]]; then
    usage
    exit 2
fi

reg_file=${1:-keys.txt}
target_device=${2:-}
[[ -f "$reg_file" ]] || die "Registry export not found: $reg_file"
command -v iconv >/dev/null || die "iconv is required"

if [[ -n $target_device ]]; then
    target_device=${target_device//:/}
    target_device=${target_device//-/}
    [[ $target_device =~ ^[[:xdigit:]]{12}$ ]] || \
        die "Invalid device MAC address: ${2}"
    target_device=${target_device^^}
fi

# Registry Editor exports are normally UTF-16LE. iconv's UTF-16 decoder also
# consumes the byte-order mark, so no Bluetooth secret is printed here.
reg_text=$(iconv -f UTF-16 -t UTF-8 -- "$reg_file") || \
    die "Could not decode $reg_file as a Windows Registry export"

current_adapter=''
declare -a adapters=()
declare -a devices=()
declare -a link_keys=()

while IFS= read -r line; do
    if [[ $line =~ \\Keys\\([[:xdigit:]]{12})\] ]]; then
        current_adapter=${BASH_REMATCH[1]^^}
    elif [[ $line =~ ^\"([[:xdigit:]]{12})\"=hex:(.*)$ ]]; then
        candidate_device=${BASH_REMATCH[1]^^}
        candidate_key=${BASH_REMATCH[2]//,/}
        candidate_key=${candidate_key//[[:space:]]/}
        candidate_key=${candidate_key^^}

        if [[ $current_adapter =~ ^[[:xdigit:]]{12}$ ]] && \
           [[ $candidate_key =~ ^[[:xdigit:]]{32}$ ]]; then
            adapters+=("$current_adapter")
            devices+=("$candidate_device")
            link_keys+=("$candidate_key")
        fi
    fi
done <<< "$reg_text"

[[ ${#devices[@]} -gt 0 ]] || \
    die "Could not find a 16-byte classic Bluetooth link key in $reg_file"

selected_index=-1
match_count=0
for index in "${!devices[@]}"; do
    if [[ -z $target_device || ${devices[$index]} == "$target_device" ]]; then
        selected_index=$index
        ((match_count += 1))
    fi
done

if [[ $match_count -eq 0 ]]; then
    die "Device MAC ${2} was not found in $reg_file"
elif [[ $match_count -gt 1 || (-z $target_device && ${#devices[@]} -gt 1) ]]; then
    printf 'Multiple classic Bluetooth keys were found:\n' >&2
    for index in "${!devices[@]}"; do
        printf '  adapter %s, device %s\n' \
            "$(format_mac "${adapters[$index]}")" \
            "$(format_mac "${devices[$index]}")" >&2
    done
    die "Choose one device by passing its MAC as the second argument"
fi

adapter_raw=${adapters[$selected_index]}
device_raw=${devices[$selected_index]}
link_key=${link_keys[$selected_index]}

adapter=$(format_mac "$adapter_raw")
device=$(format_mac "$device_raw")

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    printf 'Detected adapter %s and device %s.\n' "$adapter" "$device"
    die "Run this script as root by repeating the same command with sudo"
fi

info_file="/var/lib/bluetooth/$adapter/$device/info"
[[ -f "$info_file" ]] || die \
    "BlueZ profile does not exist: $info_file
Pair this device once in Ubuntu to create it. Then pair/export again in Windows before rerunning this script."

if ! sed -n '/^\[LinkKey\]$/,/^\[/p' "$info_file" | grep -q '^Key='; then
    die "The existing BlueZ profile has no [LinkKey] Key entry; refusing to guess its key type"
fi

timestamp=$(date +%Y%m%d-%H%M%S)
backup_file="${info_file}.bak-${timestamp}"
temp_file=$(mktemp --tmpdir="$(dirname "$info_file")" .info.sync.XXXXXX)
bluetooth_was_active=false

cleanup() {
    rm -f -- "$temp_file"
    if $bluetooth_was_active; then
        systemctl start bluetooth >/dev/null || true
    fi
}
trap cleanup EXIT

cp --archive -- "$info_file" "$backup_file"
chmod --reference="$info_file" "$temp_file"
chown --reference="$info_file" "$temp_file"

if systemctl is-active --quiet bluetooth; then
    bluetooth_was_active=true
    systemctl stop bluetooth
fi

in_link_key=false
key_replaced=false
while IFS= read -r config_line || [[ -n $config_line ]]; do
    if [[ $config_line == '[LinkKey]' ]]; then
        in_link_key=true
    elif [[ $config_line == \[*\] ]]; then
        in_link_key=false
    fi

    if $in_link_key && [[ $config_line == Key=* ]]; then
        printf 'Key=%s\n' "$link_key"
        key_replaced=true
    else
        printf '%s\n' "$config_line"
    fi
done < "$info_file" > "$temp_file"

$key_replaced || die "Link key disappeared while updating $info_file"
mv -- "$temp_file" "$info_file"

if $bluetooth_was_active; then
    systemctl start bluetooth
    bluetooth_was_active=false
fi
trap - EXIT

printf 'Updated Bluetooth key for %s on adapter %s.\n' "$device" "$adapter"
printf 'Backup: %s\n' "$backup_file"
printf 'Turn the headset on, then try: bluetoothctl connect %s\n' "$device"
