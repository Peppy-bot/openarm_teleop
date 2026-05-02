#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ ! -f "$REPO_DIR/ros2_ws/install/setup.bash" ]; then
    echo "[build] ros2_ws/install/setup.bash not found — run 'pixi run setup-ws' first." >&2
    exit 1
fi

# Fast path: all binaries exist and no source file is newer.
needs_build=0
for bin in unilateral_control bilateral_control gravity_comp comm_test; do
    [ -f "$REPO_DIR/build/$bin" ] || { needs_build=1; break; }
done
if [ $needs_build -eq 0 ]; then
    newest_src=$(find "$REPO_DIR/CMakeLists.txt" "$REPO_DIR/src" "$REPO_DIR/control" \
        -type f -newer "$REPO_DIR/build/unilateral_control" 2>/dev/null | head -n1)
    if [ -z "$newest_src" ]; then
        echo "[build] up-to-date"
        exit 0
    fi
fi

# pixi activation usually sources this already, but re-source defensively in
# case `pixi run build` was invoked from a partially-warm shell. The colcon
# setup.bash references unset vars, so relax `nounset` while sourcing.
set +u
# shellcheck disable=SC1091
source "$REPO_DIR/ros2_ws/install/setup.bash"
set -u

cd "$REPO_DIR"
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
echo "[build] done. Binaries in $REPO_DIR/build/"
