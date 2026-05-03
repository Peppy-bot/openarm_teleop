#!/bin/bash
# Renames the four PEAK PCAN-USB Pro FD channels to stable names based on
# their USB port path + controller channel, then brings them up in CAN-FD mode.
#
# Why: `pcan` and `mttcan` race for the canN namespace at boot, so the kernel
# numbering of PEAK channels (can0..can3 vs can4..can7) is not stable across
# reboots. PEAK ships these adapters with identical default `serialno`, so the
# only stable per-adapter key is the USB port path on the Jetson carrier.
#
# Adjust MAPPING below if the adapters get re-cabled to different ports.
set -uo pipefail

# USB-port:channel  →  desired interface name
declare -A MAPPING=(
    ["1-4.1:0"]="right_leader"
    ["1-4.1:1"]="left_leader"
    ["1-4.2:0"]="right_follower"
    ["1-4.2:1"]="left_follower"
)
# NOTE: Linux interface names must be <= 15 chars (IFNAMSIZ-1).
# right_follower (14) is the longest currently. Stay under 15 if you edit.

CONFIGURE_TOOL="${CONFIGURE_TOOL:-/usr/local/bin/openarm-can-configure-socketcan}"

declare -a stable_names=()
declare -a unmapped=()

for d in /sys/class/pcan/pcanusbfd*/; do
    [ -d "$d" ] || continue

    cur=$(cat "$d/ndev" 2>/dev/null)
    ctrlr=$(cat "$d/ctrlr_number" 2>/dev/null)
    devlink=$(readlink -f "$d/device" 2>/dev/null)
    [ -n "$cur" ] && [ -n "$ctrlr" ] && [ -n "$devlink" ] || continue

    # .../usb1/1-4/1-4.1/1-4.1:1.0  →  1-4.1
    port=$(basename "$(dirname "$devlink")")

    key="${port}:${ctrlr}"
    target="${MAPPING[$key]:-}"

    if [ -z "$target" ]; then
        unmapped+=("$cur (USB $port channel $ctrlr)")
        continue
    fi

    if [ "$cur" = "$target" ]; then
        echo "[openarm-can-setup] $cur already named correctly"
    else
        echo "[openarm-can-setup] renaming $cur → $target  (USB $port channel $ctrlr)"
        ip link set "$cur" down 2>/dev/null || true
        if ! ip link set "$cur" name "$target"; then
            echo "[openarm-can-setup]  rename failed (target may already exist); leaving as $cur" >&2
            target="$cur"
        fi
    fi

    stable_names+=("$target")
done

if [ "${#stable_names[@]}" -eq 0 ]; then
    echo "[openarm-can-setup] no PEAK PCAN interfaces found — is the pcan module loaded?" >&2
    exit 1
fi

if [ "${#unmapped[@]}" -gt 0 ]; then
    echo "[openarm-can-setup] WARNING: unmapped PCAN channels (left as-is):" >&2
    printf '  - %s\n' "${unmapped[@]}" >&2
fi

# Configure each renamed interface in CAN-FD mode.
rc=0
for name in "${stable_names[@]}"; do
    if ! "$CONFIGURE_TOOL" "$name" -fd; then
        echo "[openarm-can-setup] $name configure failed" >&2
        rc=1
    fi
done

exit $rc
