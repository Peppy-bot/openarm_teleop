#!/bin/bash
#
# Copyright 2025 Enactic, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ========= Configuration =========
ARM_SIDE=${1:-right_arm} # Required: left_arm or right_arm
LEADER_CAN_IF=$2         # Optional: leader CAN interface
FOLLOWER_CAN_IF=$3       # Optional: follower CAN interface
ARM_TYPE="v10"           # Fixed for now
TMPDIR="/tmp/openarm_urdf_gen"

# Validate arm side
if [[ "$ARM_SIDE" != "right_arm" && "$ARM_SIDE" != "left_arm" ]]; then
    echo "[ERROR] Invalid arm_side: $ARM_SIDE"
    echo "Usage: $0 <arm_side: right_arm|left_arm> [leader_can_if] [follower_can_if]"
    exit 1
fi

# Set default CAN interfaces if not provided
if [ -z "$LEADER_CAN_IF" ]; then
    if [ "$ARM_SIDE" = "right_arm" ]; then
        LEADER_CAN_IF="can0"
    else
        LEADER_CAN_IF="can1"
    fi
fi

if [ -z "$FOLLOWER_CAN_IF" ]; then
    if [ "$ARM_SIDE" = "right_arm" ]; then
        FOLLOWER_CAN_IF="can2"
    else
        FOLLOWER_CAN_IF="can3"
    fi
fi

# File paths
LEADER_URDF_PATH="$TMPDIR/${ARM_TYPE}_leader.urdf"
FOLLOWER_URDF_PATH="$TMPDIR/${ARM_TYPE}_follower.urdf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WS_DIR="${WS_DIR:-$REPO_DIR/ros2_ws}"
# openarm_description was restructured into a multi-version `assets/` tree
# (urdf/robot/v10.urdf.xacro -> assets/robot/openarm_v1.0/urdf/openarm_v10.urdf.xacro).
# Prefer the new layout and fall back to the legacy flat one so either checkout
# of openarm_description keeps working. ARM_TYPE "v10" maps to openarm_v1.0.
DESC_DIR="$WS_DIR/src/openarm_description"
XACRO_CANDIDATES=(
    "$DESC_DIR/assets/robot/openarm_v1.0/urdf/openarm_${ARM_TYPE}.urdf.xacro"
    "$DESC_DIR/urdf/robot/${ARM_TYPE}.urdf.xacro"
)
XACRO_PATH=""
for _cand in "${XACRO_CANDIDATES[@]}"; do
    [ -f "$_cand" ] && { XACRO_PATH="$_cand"; break; }
done
BIN_PATH="$REPO_DIR/build/unilateral_control"

# Check workspace
if [ ! -d "$WS_DIR" ]; then
    echo "[ERROR] Could not find workspace at: $WS_DIR" >&2
    echo "We assume the default ROS 2 workspace is ~/openarm_ros2_ws." >&2
    echo "If you are using a different workspace, please update WS_DIR in this launch script." >&2
    exit 1
fi

# Check openarm_description package
if [ ! -d "$WS_DIR/src/openarm_description" ]; then
    echo "[ERROR] Could not find package: $WS_DIR/src/openarm_description" >&2
    echo "Please make sure to clone openarm_description into $WS_DIR/src/" >&2
    exit 1
fi

# Check xacro
if [ -z "$XACRO_PATH" ]; then
    echo "[ERROR] Could not find the ${ARM_TYPE} robot xacro in openarm_description." >&2
    echo "        Looked in:" >&2
    for _cand in "${XACRO_CANDIDATES[@]}"; do echo "          - $_cand" >&2; done
    exit 1
fi

# ================================

# Check binary
if [ ! -f "$BIN_PATH" ]; then
    echo "[ERROR] Compiled binary not found at: $BIN_PATH"
    exit 1
fi

# Source ROS 2
# shellcheck source=/dev/null
source "$WS_DIR/install/setup.bash"

# Generate URDFs
echo "[INFO] Generating URDFs using xacro..."
mkdir -p "$TMPDIR"
if ! xacro "$XACRO_PATH" bimanual:=true -o "$LEADER_URDF_PATH"; then
    echo "[ERROR] Failed to generate URDFs."
    exit 1
fi
cp "$LEADER_URDF_PATH" "$FOLLOWER_URDF_PATH"

# Run binary
echo "[INFO] Launching unilateral control..."
"$BIN_PATH" "$LEADER_URDF_PATH" "$FOLLOWER_URDF_PATH" "$ARM_SIDE" "$LEADER_CAN_IF" "$FOLLOWER_CAN_IF"

# Cleanup
echo "[INFO] Cleaning up temporary files..."
rm -rf "$TMPDIR"
