#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS_DIR="$REPO_DIR/ros2_ws"
SRC_DIR="$WS_DIR/src"

# Pinned upstream refs for reproducibility — these repos are otherwise a moving
# target via an unpinned `--depth 1` clone.
#
# openarm_description is pinned to the last v1.0 release (1.0.4). The teleop
# binaries hardcode the KDL chain endpoints root="openarm_body_link0" and
# leaf="openarm_{left,right}_hand" (control/openarm_*_control.cpp). The v2.0
# restructure (description commit d82e87d, "Feature/v2.0 li #52") reorganized the
# tree into assets/robot/... and renamed that leaf link, so any newer commit makes
# getChain() fail -> empty Dynamics chain -> segfault at control start. Stay on the
# v1.0 line until the binaries are ported to the v2.0 link names.
#
# openarm_can is pinned to the commit in use when motor comms were last
# known-good (arm + gripper enable correctly).
#
# To bump: change the ref below, delete the existing ros2_ws/src/<repo> checkout
# (clones are skipped when the dir already exists) plus ros2_ws/install and
# ros2_ws/build, then re-run `pixi run setup-ws`.
OPENARM_DESCRIPTION_REF="1.0.4"                             # v1.0 release; commit 5db5232 (2026-02-06)
OPENARM_CAN_REF="4063506136c60f62dbd159c0ce150094426279d7"  # main @ 2026-05-19

# Fast path: everything's already in place.
if [ -f "$WS_DIR/install/setup.bash" ] \
    && [ -d "$SRC_DIR/openarm_description" ] \
    && [ -d "$SRC_DIR/openarm_can" ]; then
    echo "[setup-ws] up-to-date"
    exit 0
fi

mkdir -p "$SRC_DIR"

# Clone a repo pinned to an exact ref (tag or commit SHA). Tries a shallow
# single-ref fetch (GitHub serves a tag or reachable SHA this way); falls back to
# a full clone + checkout if the server refuses the ref fetch.
clone_pinned() {
    local url="$1"
    local name="$2"
    local ref="$3"
    local dest="$SRC_DIR/$name"
    if [ -d "$dest" ]; then
        echo "[setup-ws] $name already cloned, skipping"
        return
    fi
    echo "[setup-ws] cloning $name @ $ref"
    git init -q "$dest"
    git -C "$dest" remote add origin "$url"
    if git -C "$dest" fetch -q --depth 1 origin "$ref"; then
        git -C "$dest" checkout -q FETCH_HEAD
    else
        echo "[setup-ws] shallow fetch of $ref failed; falling back to full clone" >&2
        rm -rf "$dest"
        git clone -q "$url" "$dest"
        git -C "$dest" checkout -q "$ref"
    fi
}

clone_pinned https://github.com/enactic/openarm_description.git openarm_description "$OPENARM_DESCRIPTION_REF"
clone_pinned https://github.com/enactic/openarm_can.git openarm_can "$OPENARM_CAN_REF"

cd "$WS_DIR"
echo "[setup-ws] colcon build"
colcon build --symlink-install
echo "[setup-ws] done. Source ros2_ws/install/setup.bash (pixi does this on activation)."
