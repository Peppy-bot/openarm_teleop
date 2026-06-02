#!/bin/bash
# Renames the four PEAK PCAN-USB Pro FD channels to stable names based on
# their USB port path + controller channel, then brings them up in CAN-FD mode.
#
# Driver: this rig (Raspberry Pi, 6.8.x-raspi kernel) uses the IN-KERNEL
# `peak_usb` SocketCAN driver, NOT PEAK's proprietary `pcan` chardev driver.
# pcan is not built for this kernel and would fight peak_usb for the adapters.
# peak_usb auto-loads on USB enumeration and exposes each CAN channel as a
# canN netdev, so there is NO modprobe step on the critical path.
#
# Stable naming: PEAK ships these adapters with identical default serialno, so
# the only stable per-adapter key is the USB port path. Within an adapter, the
# peak_usb channel index is exposed as /sys/class/net/<if>/dev_id (0 or 1).
#
# Adjust MAPPING below if the adapters get re-cabled to different ports.
set -uo pipefail

# USB-port:channel(dev_id)  →  desired interface name
#
# Channel→side direction is VERIFIED EMPIRICALLY with `./build/comm_test <iface>`
# (whichever physical arm responds is that interface). The two adapters may use
# opposite channel→side conventions, so re-verify BOTH sides after any
# re-cabling. On this Pi the two Pro FD adapters enumerate as USB ports
# 2-1.2 and 2-1.3 (was 1-4.1 / 1-4.2 on the old Jetson rig).
declare -A MAPPING=(
    ["2-1.2:0"]="right_leader"
    ["2-1.2:1"]="left_leader"
    ["2-1.3:0"]="left_follower"
    ["2-1.3:1"]="right_follower"
)
# NOTE: Linux interface names must be <= 15 chars (IFNAMSIZ-1).
# right_follower (14) is the longest currently. Stay under 15 if you edit.

BITRATE="${BITRATE:-1000000}"
DBITRATE="${DBITRATE:-5000000}"

# peak_usb is in-kernel and normally auto-loaded by udev when the adapters are
# plugged in. Load it ourselves only if it somehow isn't present yet.
if ! lsmod | grep -q '^peak_usb'; then
    echo "[openarm-can-setup] loading peak_usb"
    modprobe peak_usb || {
        echo "[openarm-can-setup] modprobe peak_usb failed" >&2
        exit 1
    }
fi

declare -a stable_names=()
declare -a unmapped=()
found=0

# Walk every netdev backed by the peak_usb driver and key it by USB port path
# + channel index (dev_id). This survives renames, so the script is idempotent.
for ifpath in /sys/class/net/*; do
    [ -e "$ifpath/device/driver" ] || continue
    drv=$(basename "$(readlink -f "$ifpath/device/driver")")
    [ "$drv" = "peak_usb" ] || continue
    found=1

    cur=$(basename "$ifpath")
    devlink=$(readlink -f "$ifpath/device")
    # .../usb2/2-1/2-1.2/2-1.2:1.0  →  2-1.2
    port=$(basename "$(dirname "$devlink")")
    chan=$(cat "$ifpath/dev_id" 2>/dev/null)
    # dev_id is reported as hex (e.g. 0x1); normalize to decimal.
    chan=$((chan))

    key="${port}:${chan}"
    target="${MAPPING[$key]:-}"

    if [ -z "$target" ]; then
        unmapped+=("$cur (USB $port channel $chan)")
        continue
    fi

    if [ "$cur" = "$target" ]; then
        echo "[openarm-can-setup] $cur already named correctly"
    else
        echo "[openarm-can-setup] renaming $cur → $target  (USB $port channel $chan)"
        ip link set "$cur" down 2>/dev/null || true
        if ! ip link set "$cur" name "$target"; then
            echo "[openarm-can-setup]  rename failed (target may already exist); leaving as $cur" >&2
            target="$cur"
        fi
    fi

    stable_names+=("$target")
done

if [ "$found" -eq 0 ]; then
    echo "[openarm-can-setup] no peak_usb CAN interfaces found — is the adapter plugged in?" >&2
    echo "  Check: lsusb | grep -i peak; ip -br link show type can" >&2
    exit 1
fi

if [ "${#unmapped[@]}" -gt 0 ]; then
    echo "[openarm-can-setup] WARNING: unmapped peak_usb channels (left as-is):" >&2
    printf '  - %s\n' "${unmapped[@]}" >&2
fi

# Configure each renamed interface in CAN-FD mode (down → set params → up).
rc=0
for name in "${stable_names[@]}"; do
    ip link set "$name" down 2>/dev/null || true
    if ip link set "$name" type can bitrate "$BITRATE" dbitrate "$DBITRATE" fd on \
        && ip link set "$name" up; then
        echo "[openarm-can-setup] $name up (CAN-FD ${BITRATE}/${DBITRATE})"
    else
        echo "[openarm-can-setup] $name configure failed" >&2
        rc=1
    fi
done

exit $rc
