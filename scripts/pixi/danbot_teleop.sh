#!/bin/bash
# Launch unilateral teleop on both DanBot arms in parallel.
# Ctrl-C (SIGINT) or SIGTERM kills both arms cleanly.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

declare -a PGIDS=()
EXITING=0

cleanup() {
    [ "$EXITING" -eq 1 ] && return
    EXITING=1
    echo
    echo "[danbot-teleop] stopping both arms..."
    # Send SIGINT — the unilateral_control binary handles SIGINT (not SIGTERM)
    # and runs its graceful shutdown path: stop control threads, then
    # disable_all() on both arms before exiting.
    for pgid in "${PGIDS[@]}"; do
        kill -INT -- "-$pgid" 2>/dev/null || true
    done
    # Give each arm a few seconds to disable motors cleanly.
    sleep 3
    # Anything still alive: escalate.
    for pgid in "${PGIDS[@]}"; do
        kill -TERM -- "-$pgid" 2>/dev/null || true
    done
    sleep 1
    for pgid in "${PGIDS[@]}"; do
        kill -KILL -- "-$pgid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# Stable interface names, applied automatically by the udev rule
# /etc/udev/rules.d/80-openarm-can.rules whenever the PEAK adapters appear.
# scripts/pixi/openarm_can_setup.sh is a manual fallback that does the same.
RIGHT_LEADER="right_leader"
RIGHT_FOLLOWER="right_follower"
LEFT_LEADER="left_leader"
LEFT_FOLLOWER="left_follower"

for iface in "$RIGHT_LEADER" "$RIGHT_FOLLOWER" "$LEFT_LEADER" "$LEFT_FOLLOWER"; do
    if ! ip link show "$iface" >/dev/null 2>&1; then
        echo "[danbot-teleop] interface '$iface' not found" >&2
        echo "  The udev rule should bring these up on plug-in. Check: ip -br link show type can" >&2
        echo "  Or run manually: sudo bash $REPO_DIR/scripts/pixi/openarm_can_setup.sh" >&2
        exit 1
    fi
done

# `setsid` puts each launch in its own process group, so on shutdown we can
# signal the whole tree (script + xacro + binary) by PGID.
setsid bash "$REPO_DIR/script/launch_unilateral.sh" right_arm "$RIGHT_LEADER" "$RIGHT_FOLLOWER" &
PGIDS+=($!)

# Stagger by 2 s to avoid the two scripts racing on /tmp/openarm_urdf_gen/.
sleep 2

setsid bash "$REPO_DIR/script/launch_unilateral.sh" left_arm "$LEFT_LEADER" "$LEFT_FOLLOWER" &
PGIDS+=($!)

wait
