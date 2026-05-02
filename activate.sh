#!/bin/bash
# Sourced by pixi on env activation. Layered ROS overlay on top of the
# robostack ROS install so that `find_package(OpenArmCAN ...)` and
# `xacro` from openarm_description resolve.
if [ -f "$PIXI_PROJECT_ROOT/ros2_ws/install/setup.bash" ]; then
    # colcon setup.bash references unset vars; relax nounset across the source.
    _had_u=0
    case $- in *u*) _had_u=1; set +u ;; esac
    # shellcheck disable=SC1091
    source "$PIXI_PROJECT_ROOT/ros2_ws/install/setup.bash"
    [ "$_had_u" = "1" ] && set -u
    unset _had_u
fi
