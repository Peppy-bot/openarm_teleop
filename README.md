# OpenArm Teleop

OpenArm supports 1:1 teleoperation from a leader arm to a follower arm in two control modes. See the [documentation](https://docs.openarm.dev/teleop/) for details.

## Quick start (pixi)

This checkout is wired up with [pixi](https://pixi.sh) so you don't have to install ROS 2 Humble system-wide. Everything (ROS env, vendored deps, build outputs) stays under this directory.

Prereqs: pixi, `linux-aarch64` host (Jetson/Orin). Add more platforms in `pixi.toml` to use it elsewhere.

```bash
pixi install                                    # one-time, fetches ROS 2 Humble (~1–2 GB)
pixi run teleop-unilateral right_arm can0 can2  # auto-runs setup-ws + build first
```

The teleop tasks declare `depends-on = ["build"]` and `build` depends on `setup-ws`, so the prereqs run automatically. Each prereq short-circuits with `up-to-date` when its artifacts exist, so subsequent launches are instant.

### Tasks

| Task | What it does |
| --- | --- |
| `pixi run setup-ws` | Clones `openarm_description` + `openarm_can` into `ros2_ws/src/` and colcon-builds them. |
| `pixi run build` | CMake-builds the teleop binaries into `./build/`. |
| `pixi run teleop-unilateral <arm_side> [leader_can] [follower_can]` | Runs `script/launch_unilateral.sh`. |
| `pixi run teleop-bilateral <arm_side> [leader_can] [follower_can]` | Runs `script/launch_bilateral.sh`. |
| `pixi run teleop-grav-comp <arm_side> [can_if] [arm_type]` | Runs `script/launch_grav_comp.sh`. |

To force a rebuild: `rm -rf build/` (cmake) or `rm -rf ros2_ws/install/` (colcon). To skip the prereq chain when iterating on a launch script: `pixi run --skip-deps teleop-unilateral …`.

### Files added for the pixi setup

- `pixi.toml` — env definition + tasks
- `activate.sh` — sources the colcon overlay on env activation
- `scripts/pixi/setup_ws.sh`, `scripts/pixi/build.sh` — the underlying task scripts

The launch scripts under `script/` derive `WS_DIR` and `BIN_PATH` from `$(dirname "$0")`, so the project is portable — `WS_DIR` is still overridable via env var if you want to point at a different ROS 2 workspace.

## Related links

- 📚 Read the [documentation](https://docs.openarm.dev/teleop/)
- 💬 Join the community on [Discord](https://discord.gg/FsZaZ4z3We)
- 📬 Contact us through <openarm@enactic.ai>

## License

Licensed under the Apache License 2.0. See [LICENSE.txt](LICENSE.txt) for details.

Copyright 2025 Enactic, Inc.

## Code of Conduct

All participation in the OpenArm project is governed by our [Code of Conduct](CODE_OF_CONDUCT.md).
