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
#
# The two PEAK adapters on this rig happen to have OPPOSITE channel→side
# wiring conventions: on the leader adapter (1-4.1) channel 0 is the right
# arm, but on the follower adapter (1-4.2) channel 0 is the left arm.
# Verified empirically with `./build/comm_test <iface>` — whichever physical
# arm lights up is the correct mapping. If you re-cable, re-verify both sides.
declare -A MAPPING=(
    ["1-4.1:0"]="right_leader"
    ["1-4.1:1"]="left_leader"
    ["1-4.2:0"]="left_follower"
    ["1-4.2:1"]="right_follower"
)
# NOTE: Linux interface names must be <= 15 chars (IFNAMSIZ-1).
# right_follower (14) is the longest currently. Stay under 15 if you edit.

CONFIGURE_TOOL="${CONFIGURE_TOOL:-/usr/local/bin/openarm-can-configure-socketcan}"

# Load pcan ourselves if it's not already loaded. We deliberately do this here
# (and NOT via /etc/modules-load.d/ or a boot-time udev rule) because pcan's
# init code has a known kernel bug: it calls usb_bulk_msg from atomic context
# during pcan_usb_plugin → canfd_set_bus_off, producing
# "BUG: scheduling while atomic" and stalling for tens of seconds when USB
# enumeration is slow. Doing the modprobe AFTER multi-user.target (where our
# systemd unit fires) keeps the stall out of the critical boot path.
if lsmod | grep -q '^pcan '; then
    # If we're running from openarm-can.service at fresh boot, pcan should NOT
    # already be loaded — the deferral relies on `blacklist pcan` in
    # /etc/modprobe.d/ to suppress udev's modalias-driven autoload. If it's
    # loaded anyway, the deferral is bypassed and the buggy probe is back on
    # the boot-critical path. Harmless when this script is run manually after
    # boot, so we warn rather than fail.
    # Avoid `grep -q` here: it closes the pipe early, modprobe -c gets SIGPIPE
    # (exit 141), and pipefail then propagates it as a "no match".
    if ! modprobe -c 2>/dev/null | grep -Fx 'blacklist pcan' >/dev/null; then
        echo "[openarm-can-setup] WARNING: pcan already loaded AND no 'blacklist pcan' in modprobe config." >&2
        echo "[openarm-can-setup]   At boot this means udev autoloaded pcan via USB modalias, which" >&2
        echo "[openarm-can-setup]   defeats the post-multi-user.target deferral. See README boot-time setup." >&2
    fi
else
    echo "[openarm-can-setup] modprobing pcan (this can take 5-30s due to driver bug)"
    modprobe pcan || {
        echo "[openarm-can-setup] modprobe pcan failed" >&2
        exit 1
    }
fi

# Wait up to N seconds for the pcan module to register sysfs entries
# (USB enumeration may still be settling).
WAIT_SECS="${WAIT_SECS:-30}"
for i in $(seq 1 "$WAIT_SECS"); do
    if compgen -G "/sys/class/pcan/pcanusbfd*" >/dev/null; then
        break
    fi
    if [ "$i" -eq "$WAIT_SECS" ]; then
        echo "[openarm-can-setup] timed out waiting for /sys/class/pcan/pcanusbfd* (${WAIT_SECS}s)" >&2
        echo "  Check: lsmod | grep pcan; lsusb | grep -i peak" >&2
        exit 1
    fi
    sleep 1
done

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
