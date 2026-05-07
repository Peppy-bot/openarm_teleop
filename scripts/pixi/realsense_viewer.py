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
from pathlib import Path

import cv2
import numpy as np
import pyrealsense2 as rs
from flask import Flask, Response


@dataclass
class FrameSlot:
    jpeg: bytes | None = None  # color for UVC; horizontal color+depth composite for RealSense


frames: dict[str, FrameSlot] = {}
frames_lock = threading.Lock()
app = Flask(__name__)
# One MJPEG stream per camera keeps us under the browser's per-origin TCP
# connection limit (Chrome/Firefox cap at 6) when 3+ RealSense cams are in use.


def uvc_loop(device: str, width: int, height: int, fps: int) -> None:
    cap = cv2.VideoCapture(device, cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, fps)
    if not cap.isOpened():
        logging.error("UVC %s failed to open", device)
        return
    logging.info("UVC %s streaming at %dx%d@%d", device, width, height, fps)
    encode_params = [int(cv2.IMWRITE_JPEG_QUALITY), 80]
    key = device.lstrip("/")  # frames key + URL path component (Flask won't match leading slashes)
    while True:
        ok, img = cap.read()
        if not ok:
            time.sleep(0.05)
            continue
        ok2, jpg = cv2.imencode(".jpg", img, encode_params)
        if not ok2:
            continue
        with frames_lock:
            frames[key] = FrameSlot(jpeg=jpg.tobytes())


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
        side_by_side = np.hstack((color_img, depth_img))
        ok, jpg = cv2.imencode(".jpg", side_by_side, encode_params)
        if not ok:
            continue
        with frames_lock:
            frames[serial] = FrameSlot(jpeg=jpg.tobytes())


def mjpeg_generator(serial: str):
    while True:
        with frames_lock:
            slot = frames.get(serial)
            payload = slot.jpeg if slot else None
        if payload is None:
            time.sleep(0.05)
            continue
        yield b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload + b"\r\n"
        time.sleep(0.03)


@app.route("/stream/<path:serial>")
def stream(serial: str):
    return Response(
        mjpeg_generator(serial),
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
            f'<img src="/stream/{s}" style="max-width:96vw;border:1px solid #ccc;display:block"/>'
        )
    body = "".join(rows) if rows else "<p>Waiting for first frame...</p>"
    return (
        "<html><head><title>RealSense viewer</title></head>"
        f'<body style="margin:16px;background:#111;color:#eee">{body}</body></html>'
    )


def discover_serials() -> list[str]:
    return [d.get_info(rs.camera_info.serial_number) for d in rs.context().devices]


def discover_uvc() -> list[str]:
    """Return stable /dev/v4l/by-id paths for non-RealSense UVC cameras."""
    base = Path("/dev/v4l/by-id")
    if not base.exists():
        return []
    out = []
    for p in sorted(base.glob("*-video-index0")):
        name = p.name.lower()
        if "intel" in name or "realsense" in name:
            continue
        out.append(str(p))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", action="append", help="RealSense serial; repeat for multiple. Default: all connected.")
    parser.add_argument("--uvc", action="append", default=[], help="UVC device path (e.g. /dev/video12); repeat for multiple.")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--fps", type=int, default=30)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    serials = args.serial or discover_serials()
    uvc_devices = args.uvc or discover_uvc()
    if not serials and not uvc_devices:
        logging.error("No RealSense or UVC cameras detected.")
        return 1
    logging.info("Streaming serials: %s, uvc: %s", serials, uvc_devices)

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

    for d in uvc_devices:
        threading.Thread(
            target=uvc_loop,
            args=(d, args.width, args.height, args.fps),
            daemon=True,
            name=f"uvc-{d}",
        ).start()

    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        logging.info("Shutting down")
    return 0


if __name__ == "__main__":
    sys.exit(main())
