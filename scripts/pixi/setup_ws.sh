#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS_DIR="$REPO_DIR/ros2_ws"
SRC_DIR="$WS_DIR/src"

# Fast path: everything's already in place.
if [ -f "$WS_DIR/install/setup.bash" ] \
    && [ -d "$SRC_DIR/openarm_description" ] \
    && [ -d "$SRC_DIR/openarm_can" ]; then
    echo "[setup-ws] up-to-date"
    exit 0
fi

mkdir -p "$SRC_DIR"

clone_if_missing() {
    local url="$1"
    local name="$2"
    if [ -d "$SRC_DIR/$name" ]; then
        echo "[setup-ws] $name already cloned, skipping"
    else
        echo "[setup-ws] cloning $name"
        git clone --depth 1 "$url" "$SRC_DIR/$name"
    fi
}

clone_if_missing https://github.com/enactic/openarm_description.git openarm_description
clone_if_missing https://github.com/enactic/openarm_can.git openarm_can

cd "$WS_DIR"
echo "[setup-ws] colcon build"
colcon build --symlink-install
echo "[setup-ws] done. Source ros2_ws/install/setup.bash (pixi does this on activation)."
