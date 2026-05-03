# OpenArm Teleop

OpenArm supports 1:1 teleoperation from a leader arm to a follower arm in two control modes. See the [documentation](https://docs.openarm.dev/teleop/) for details.

## Quick start

```bash
pixi install            # one-time, fetches ROS 2 Humble (~1–2 GB)
pixi run danbot-teleop  # both arms, correct CAN mapping, Ctrl-C stops both
```

That's it. The task auto-runs `setup-ws` (clones + colcon-builds `openarm_description` and `openarm_can`) and `build` (CMake-builds the teleop binaries) on first invocation; subsequent runs short-circuit with `up-to-date` and launch instantly.

Prereqs: [pixi](https://pixi.sh), `linux-aarch64` host (Jetson/Orin). Add more platforms in `pixi.toml` to use it elsewhere.

## DanBot — what this rig is

This checkout drives **DanBot** — our local OpenArm rig, hosted on a Jetson AGX Orin with two PEAK PCAN-USB Pro FD adapters (4 CAN-FD channels: `can4..can7`).

CAN mapping (used by `pixi run danbot-teleop`):

| Arm   | Leader | Follower |
| ----- | ------ | -------- |
| right | `can4` | `can6`   |
| left  | `can5` | `can7`   |

Leaders share PCAN adapter #1 (`can4`/`can5`), followers share PCAN adapter #2 (`can6`/`can7`). The Jetson's on-SoC mttcan ports (`can0..can3`) are **not** wired to the arms on this rig — don't use them.

To drive a single arm (e.g. when one side is unplugged):

```bash
pixi run teleop-unilateral right_arm can4 can6
pixi run teleop-unilateral left_arm  can5 can7
```

### One-time setup on a fresh boot

The Jetson L4T kernel doesn't ship the PEAK driver, so `pcan` is built from source (already done — see `/tmp/peak-linux-driver-9.0/` or rebuild from <https://www.peak-system.com/quick/PCAN-Linux-Driver>). To make it survive reboots:

```bash
echo pcan | sudo tee /etc/modules-load.d/pcan.conf
```

And to auto-configure all four PEAK CAN-FD buses on boot, install a oneshot systemd unit that runs `openarm-can-configure-socketcan canN -fd` for `N=4..7`.

If you ever see `tx N rx 0` / ERROR-PASSIVE / BUS-OFF on the PEAK buses again, the most likely culprit is a stray teleop process holding the socket open after a previous run — `pkill -9 -f unilateral_control` (and the other binaries) clears it.

## All pixi tasks

| Task | What it does |
| --- | --- |
| `pixi run danbot-teleop` | Bimanual unilateral teleop with the DanBot CAN mapping baked in. Ctrl-C stops both arms cleanly. |
| `pixi run teleop-unilateral <arm_side> [leader_can] [follower_can]` | Single-arm unilateral teleop. |
| `pixi run teleop-bilateral <arm_side> [leader_can] [follower_can]` | Single-arm bilateral teleop (force-feedback to leader). |
| `pixi run teleop-grav-comp <arm_side> [can_if] [arm_type]` | Gravity compensation only (no follower). |
| `pixi run setup-ws` | Clones `openarm_description` + `openarm_can` into `ros2_ws/src/` and colcon-builds them. |
| `pixi run build` | CMake-builds the teleop binaries into `./build/`. |

To force a rebuild: `rm -rf build/` (cmake) or `rm -rf ros2_ws/install/` (colcon). To skip the prereq chain when iterating on a launch script: `pixi run --skip-deps teleop-unilateral …`.

### Project layout

- `pixi.toml` — env definition + tasks (channels: `robostack-staging`, `conda-forge`)
- `activate.sh` — sources the colcon overlay on env activation
- `scripts/pixi/setup_ws.sh`, `scripts/pixi/build.sh`, `scripts/pixi/danbot_teleop.sh` — the underlying task scripts
- `script/launch_*.sh` — the upstream launch scripts (`WS_DIR`/`BIN_PATH` rewritten as script-relative paths so the repo is portable; `WS_DIR` is still overridable via env var)
- `ros2_ws/` — vendored ROS 2 workspace (gitignored; populated by `setup-ws`)

## Related links

- 📚 Read the [documentation](https://docs.openarm.dev/teleop/)
- 💬 Join the community on [Discord](https://discord.gg/FsZaZ4z3We)
- 📬 Contact us through <openarm@enactic.ai>

## License

Licensed under the Apache License 2.0. See [LICENSE.txt](LICENSE.txt) for details.

Copyright 2025 Enactic, Inc.

## Code of Conduct

All participation in the OpenArm project is governed by our [Code of Conduct](CODE_OF_CONDUCT.md).
