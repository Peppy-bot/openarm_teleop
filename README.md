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

This checkout drives **DanBot** — our local OpenArm rig, hosted on a Jetson AGX Orin with two PEAK PCAN-USB Pro FD adapters (4 CAN-FD channels).

The four channels are renamed at boot to **stable, role-based names** (driven by `scripts/pixi/openarm_can_setup.sh`, see "Boot-time setup" below):

| Arm   | Leader         | Follower         |
| ----- | -------------- | ---------------- |
| right | `right_leader` | `right_follower` |
| left  | `left_leader`  | `left_follower`  |

(No `can_` prefix because Linux interface names are capped at 15 characters — `can_right_follower` doesn't fit. `ip link show` already labels them `link/can`, so the prefix is redundant.)

Leaders are on PCAN adapter #1 (Jetson USB port `1-4.1`), followers on PCAN adapter #2 (port `1-4.2`). The Jetson's on-SoC mttcan ports are **not** wired to the arms — don't use them.

```bash
pixi run danbot-teleop                                            # both arms
pixi run teleop-unilateral right_arm right_leader right_follower  # right only
pixi run teleop-unilateral left_arm  left_leader  left_follower   # left only
```

### Boot-time setup

Build the PEAK driver once: download from <https://www.peak-system.com/quick/PCAN-Linux-Driver>, then `make netdev && sudo make install`. The Jetson L4T kernel disables `CONFIG_CAN_PEAK_USB`, so this out-of-tree build is required.

After that, install the systemd unit below. **Do NOT add `pcan` to `/etc/modules-load.d/` and do NOT add a boot-time udev rule for it.** The PEAK driver has a known kernel bug — `pcan_usb_plugin → canfd_set_bus_off → pcan_usbfd_send_ucan_cmd → usb_bulk_msg → wait_for_completion_timeout` invokes a sleeping function from atomic context (kernel emits `BUG: scheduling while atomic`). The wait completes eventually, but on slow USB enumeration it can stall for tens of seconds. If pcan loads early in boot, that stall happens on the critical path and can hang the boot indefinitely. The fix is to defer pcan loading until **after** `multi-user.target` so the stall (if any) sits in the background while the system is already up.

```bash
# Make sure no early-loader is in place
sudo rm -f /etc/modules-load.d/pcan.conf
sudo rm -f /etc/udev/rules.d/70-pcan-modprobe.rules
sudo udevadm control --reload-rules

# Install the unit. After= multi-user.target keeps the modprobe stall off the
# critical boot path; the script does the modprobe + rename + bring-up itself.
sudo tee /etc/systemd/system/openarm-can.service >/dev/null <<EOF
[Unit]
Description=Load pcan + rename and configure DanBot CAN interfaces
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=120
ExecStart=/bin/bash $(pwd)/scripts/pixi/openarm_can_setup.sh

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now openarm-can.service
```

What `openarm_can_setup.sh` does, in order:
1. `modprobe pcan` if it isn't already loaded (this is where the 5–30 s stall lives, off the boot critical path).
2. Polls `/sys/class/pcan/pcanusbfd*/` for up to 30 s while USB enumeration settles.
3. Reads each channel's `device` symlink and `ctrlr_number`, maps `(USB port, channel) → role` from the table at the top of the script, and renames each `canN` via `ip link set canN name <role>` to the stable name (`right_leader`, `left_leader`, `right_follower`, `left_follower`).
4. Brings each renamed interface up in CAN-FD mode via `openarm-can-configure-socketcan`.

To re-run manually (after replugging adapters or editing the mapping):
```bash
sudo bash scripts/pixi/openarm_can_setup.sh
```

### Trade-off

CAN comes up a few seconds *after* the login prompt, instead of being available the moment the kernel finishes booting. If you run `pixi run danbot-teleop` in the brief window between login and the service finishing, you'll get `interface 'right_leader' not found` — wait a moment and re-run, or `systemctl status openarm-can.service` to watch its progress.

### Troubleshooting

- **`pixi run danbot-teleop` says `interface 'right_leader' not found`** → the rename didn't run yet (or failed). `systemctl status openarm-can.service` shows progress; `sudo bash scripts/pixi/openarm_can_setup.sh` runs it manually.
- **Boot is stuck on a kernel call trace mentioning `pcan_init_module` and `__schedule_bug`** → pcan is being loaded too early. Confirm `/etc/modules-load.d/pcan.conf` is *gone* and `/etc/udev/rules.d/70-pcan-modprobe.rules` is *gone*. Check `lsmod | grep pcan` immediately after the login prompt — it should be empty until `openarm-can.service` runs and modprobes it.
- **Diagnosis tool returns NG on every motor** → motors aren't electrically alive. Most likely an e-stop re-latched after a power cycle (they reset on boot and need to be physically released again). Confirm joint status LEDs are lit on every motor and all four e-stops are popped up, then `~/openarm_can/build/openarm-can-diagnosis right_leader -fd` to re-test.
- **`tx N rx 0` / ERROR-PASSIVE / BUS-OFF on a bus that was previously fine** → most often a stray teleop process holding the socket open from a previous run: `pkill -9 -f unilateral_control` (and the other binaries) clears it. Then re-cycle the bus: `sudo ip link set <name> down && sudo openarm-can-configure-socketcan <name> -fd`.

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
