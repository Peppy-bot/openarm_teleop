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
    for pgid in "${PGIDS[@]}"; do
        kill -TERM -- "-$pgid" 2>/dev/null || true
    done
    # Give each arm a moment to shut down its motors gracefully.
    sleep 1
    for pgid in "${PGIDS[@]}"; do
        kill -KILL -- "-$pgid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# `setsid` puts each launch in its own process group, so on shutdown we can
# signal the whole tree (script + xacro + binary) by PGID.
setsid bash "$REPO_DIR/script/launch_unilateral.sh" right_arm can4 can6 &
PGIDS+=($!)

# Stagger by 2 s to avoid the two scripts racing on /tmp/openarm_urdf_gen/.
sleep 2

setsid bash "$REPO_DIR/script/launch_unilateral.sh" left_arm can5 can7 &
PGIDS+=($!)

wait
