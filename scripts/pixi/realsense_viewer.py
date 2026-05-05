#!/usr/bin/env python3
"""Headless MJPEG viewer for Intel RealSense cameras.

Streams color and colorized-depth frames over HTTP. Open
http://<jetson-host>:8080/ in any browser to see all connected
RealSense cameras side by side.

USB 3 bandwidth note: each camera at 1280x720@30 with both BGR8 color and
Z16 depth needs ~133 MB/s. Three cameras on one hub at that resolution
exceed the ~350 MB/s practical USB 3 ceiling and the kernel will reset
devices mid-stream. Defaults are 640x480@30 which fits all three. Use
1280x720 only with one or two cameras.
"""

from __future__ import annotations

import argparse
import logging
import sys
import threading
import time
from dataclasses import dataclass

import cv2
import numpy as np
import pyrealsense2 as rs
from flask import Flask, Response


@dataclass
class FrameSlot:
    color_jpeg: bytes | None = None
    depth_jpeg: bytes | None = None


frames: dict[str, FrameSlot] = {}
frames_lock = threading.Lock()
app = Flask(__name__)


def camera_loop(serial: str, width: int, height: int, fps: int) -> None:
    pipeline = rs.pipeline()
    config = rs.config()
    config.enable_device(serial)
    config.enable_stream(rs.stream.color, width, height, rs.format.bgr8, fps)
    config.enable_stream(rs.stream.depth, width, height, rs.format.z16, fps)
    colorizer = rs.colorizer()

    attempt = 0
    while True:
        attempt += 1
        try:
            pipeline.start(config)
            logging.info("Camera %s streaming at %dx%d@%d", serial, width, height, fps)
            break
        except Exception as exc:
            logging.error("Camera %s start failed (attempt %d): %s", serial, attempt, exc)
            if attempt >= 5:
                logging.error("Camera %s giving up after 5 attempts", serial)
                return
            time.sleep(2.0)

    encode_params = [int(cv2.IMWRITE_JPEG_QUALITY), 80]
    while True:
        try:
            composite = pipeline.wait_for_frames(timeout_ms=5000)
        except Exception as exc:
            logging.warning("Camera %s wait_for_frames failed: %s", serial, exc)
            time.sleep(0.5)
            continue
        color = composite.get_color_frame()
        depth = composite.get_depth_frame()
        if not color or not depth:
            continue
        color_img = np.asanyarray(color.get_data())
        depth_img = np.asanyarray(colorizer.colorize(depth).get_data())
        ok_c, jpg_c = cv2.imencode(".jpg", color_img, encode_params)
        ok_d, jpg_d = cv2.imencode(".jpg", depth_img, encode_params)
        if not (ok_c and ok_d):
            continue
        with frames_lock:
            frames[serial] = FrameSlot(jpg_c.tobytes(), jpg_d.tobytes())


def mjpeg_generator(serial: str, kind: str):
    while True:
        with frames_lock:
            slot = frames.get(serial)
            payload = slot.color_jpeg if (slot and kind == "color") else (slot.depth_jpeg if slot else None)
        if payload is None:
            time.sleep(0.05)
            continue
        yield b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload + b"\r\n"
        time.sleep(0.03)


@app.route("/<serial>/<kind>")
def stream(serial: str, kind: str):
    if kind not in ("color", "depth"):
        return ("kind must be color or depth", 400)
    return Response(
        mjpeg_generator(serial, kind),
        mimetype="multipart/x-mixed-replace; boundary=frame",
    )


@app.route("/")
def index() -> str:
    with frames_lock:
        serials = sorted(frames.keys())
    rows = []
    for s in serials:
        rows.append(
            f'<h2 style="font-family:sans-serif">{s}</h2>'
            f'<div style="display:flex;gap:8px">'
            f'<img src="/{s}/color" style="max-width:48vw;border:1px solid #ccc"/>'
            f'<img src="/{s}/depth" style="max-width:48vw;border:1px solid #ccc"/>'
            f"</div>"
        )
    body = "".join(rows) if rows else "<p>Waiting for first frame...</p>"
    return (
        "<html><head><title>RealSense viewer</title></head>"
        f'<body style="margin:16px;background:#111;color:#eee">{body}</body></html>'
    )


def discover_serials() -> list[str]:
    return [d.get_info(rs.camera_info.serial_number) for d in rs.context().devices]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", action="append", help="Camera serial; repeat for multiple. Default: all connected.")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--fps", type=int, default=30)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    serials = args.serial or discover_serials()
    if not serials:
        logging.error("No RealSense cameras detected.")
        return 1
    logging.info("Streaming serials: %s", serials)

    # Start Flask first in a daemon thread so the web UI is reachable even
    # if a camera's pipeline.start() hangs or the librealsense backend deadlocks.
    flask_thread = threading.Thread(
        target=lambda: app.run(host="0.0.0.0", port=args.port, threaded=True, use_reloader=False),
        daemon=True,
        name="flask",
    )
    flask_thread.start()
    time.sleep(0.5)
    logging.info("HTTP server bound on 0.0.0.0:%d", args.port)

    for s in serials:
        threading.Thread(
            target=camera_loop,
            args=(s, args.width, args.height, args.fps),
            daemon=True,
            name=f"rs-{s}",
        ).start()

    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        logging.info("Shutting down")
    return 0


if __name__ == "__main__":
    sys.exit(main())
