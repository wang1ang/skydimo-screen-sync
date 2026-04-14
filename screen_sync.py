#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import select
import sys
import time
from dataclasses import dataclass
import termios

import numpy as np

from probe_skydimo import DEFAULT_BAUD, make_frame, open_port, pulse_modem_lines

import mss


TOP_COUNT = 37
BOTTOM_COUNT = 37
LEFT_COUNT = 20
RIGHT_COUNT = 20

HORIZONTAL_MARGIN_SPACES = 2.0
VERTICAL_MARGIN_SPACES = 1.5
TOTAL_LED_COUNT = RIGHT_COUNT + TOP_COUNT + LEFT_COUNT + BOTTOM_COUNT
SERIAL_BITS_PER_BYTE = 10.0
DEFAULT_WIRE_UTILIZATION = 0.85
DEFAULT_KEEPALIVE_SECONDS = 0.5


@dataclass(frozen=True)
class SampleRect:
    x0: float
    y0: float
    x1: float
    y1: float


@dataclass(frozen=True)
class PixelRect:
    x0: int
    y0: int
    x1: int
    y1: int


class SyncInterrupted(Exception):
    def __init__(self, frames: int):
        super().__init__("screen sync interrupted")
        self.frames = frames


def compute_centers(count: int, margin_spaces: float) -> list[float]:
    if count < 1:
        raise ValueError("count must be positive")
    if count == 1:
        return [0.5]
    step = 1.0 / ((count - 1) + 2.0 * margin_spaces)
    return [margin_spaces * step + i * step for i in range(count)]


def compute_bounds(centers: list[float]) -> list[float]:
    if len(centers) == 1:
        return [0.0, 1.0]

    bounds = [0.0] * (len(centers) + 1)
    first_gap = centers[1] - centers[0]
    last_gap = centers[-1] - centers[-2]
    bounds[0] = max(0.0, centers[0] - first_gap / 2.0)
    bounds[-1] = min(1.0, centers[-1] + last_gap / 2.0)

    for i in range(1, len(centers)):
        bounds[i] = (centers[i - 1] + centers[i]) / 2.0

    return bounds


def edge_layout() -> dict[str, list[SampleRect]]:
    x_centers = compute_centers(TOP_COUNT, HORIZONTAL_MARGIN_SPACES)
    y_centers = compute_centers(LEFT_COUNT, VERTICAL_MARGIN_SPACES)
    x_bounds = compute_bounds(x_centers)
    y_bounds = compute_bounds(y_centers)

    top_band = y_bounds[0]
    bottom_band = y_bounds[-1]
    left_band = x_bounds[0]
    right_band = x_bounds[-1]

    top = [
        SampleRect(x_bounds[i], 0.0, x_bounds[i + 1], top_band)
        for i in range(TOP_COUNT - 1, -1, -1)
    ]
    bottom = [
        SampleRect(x_bounds[i], bottom_band, x_bounds[i + 1], 1.0)
        for i in range(BOTTOM_COUNT)
    ]
    left = [
        SampleRect(0.0, y_bounds[i], left_band, y_bounds[i + 1])
        for i in range(LEFT_COUNT)
    ]
    right = [
        SampleRect(right_band, y_bounds[i], 1.0, y_bounds[i + 1])
        for i in range(RIGHT_COUNT - 1, -1, -1)
    ]

    return {
        "right": right,
        "top": top,
        "left": left,
        "bottom": bottom,
    }


def edge_layout_list() -> list[SampleRect]:
    layout = edge_layout()
    rects: list[SampleRect] = []
    for side in ("right", "top", "left", "bottom"):
        rects.extend(layout[side])
    return rects


def rect_to_pixels(rect: SampleRect, width: int, height: int) -> tuple[int, int, int, int]:
    x0 = max(0, min(width - 1, int(rect.x0 * width)))
    y0 = max(0, min(height - 1, int(rect.y0 * height)))
    x1 = max(x0 + 1, min(width, int(rect.x1 * width)))
    y1 = max(y0 + 1, min(height, int(rect.y1 * height)))
    return x0, y0, x1, y1


def build_pixel_rects(width: int, height: int) -> list[PixelRect]:
    return [
        PixelRect(*rect_to_pixels(rect, width, height))
        for rect in edge_layout_list()
    ]


def sample_edge_colors_from_bgra(
    bgra: np.ndarray,
    pixel_rects: list[PixelRect],
    brightness: float,
) -> np.ndarray:
    colors = np.empty((len(pixel_rects), 3), dtype=np.float32)
    for index, rect in enumerate(pixel_rects):
        region = bgra[rect.y0:rect.y1, rect.x0:rect.x1]
        if region.size == 0:
            colors[index] = 0.0
            continue
        mean = region.mean(axis=(0, 1), dtype=np.float32)
        colors[index, 0] = mean[2] * brightness
        colors[index, 1] = mean[1] * brightness
        colors[index, 2] = mean[0] * brightness
    return np.clip(colors, 0.0, 255.0)


def quantize_colors(colors: np.ndarray) -> np.ndarray:
    return np.clip(np.rint(colors), 0.0, 255.0).astype(np.uint8)


def make_color_frame_from_quantized(quantized: np.ndarray) -> bytes:
    payload = np.ascontiguousarray(quantized, dtype=np.uint8).reshape(-1).tobytes()
    return b"Ada" + b"\x00\x00" + bytes((len(quantized),)) + payload


def estimated_max_wire_fps(baud: int, led_count: int) -> float:
    frame_bytes = 6 + led_count * 3
    return baud / (frame_bytes * SERIAL_BITS_PER_BYTE)


def effective_target_fps(requested_fps: float, baud: int, wire_utilization: float) -> float:
    max_wire_fps = estimated_max_wire_fps(baud, TOTAL_LED_COUNT)
    return min(requested_fps, max_wire_fps * max(0.05, min(1.0, wire_utilization)))


def write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    written = 0
    while written < len(view):
        try:
            written += os.write(fd, view[written:])
        except BlockingIOError:
            select.select([], [fd], [])
    termios.tcdrain(fd)


def resolve_monitor(sct: "mss.mss", display: int) -> dict[str, int]:
    monitor_count = len(sct.monitors) - 1
    if monitor_count < 1:
        raise RuntimeError("mss did not report any displays")
    if display < 1 or display > monitor_count:
        raise RuntimeError(
            f"Display index {display} is out of range; mss reports {monitor_count} display(s)"
        )
    return sct.monitors[display]


def capture_screen_array_mss(sct: "mss.mss", monitor: dict[str, int]) -> np.ndarray:
    shot = sct.grab(monitor)
    return np.frombuffer(shot.bgra, dtype=np.uint8).reshape(shot.height, shot.width, 4)


def sync_loop(
    port: str,
    baud: int,
    fps: float,
    idle_fps: float,
    brightness: float,
    duration: float,
    display: int,
    wire_utilization: float,
    stats_interval: float,
    modem_pulse: bool,
    pulse_delay: float,
    boot_wait: float,
) -> int:
    fd = open_port(port, baud)
    effective_fps = effective_target_fps(fps, baud, wire_utilization)
    interval = 1.0 / effective_fps if effective_fps > 0 else 0.0
    idle_interval = 1.0 / idle_fps if 0.0 < idle_fps < effective_fps else interval
    frames = 0
    sent_frames = 0
    skipped_frames = 0
    stats_started = time.monotonic()
    stats_last = stats_started
    stats_frames = 0
    stats_sent = 0
    stats_skipped = 0
    stats_capture = 0.0
    stats_write = 0.0

    sct = mss.mss()
    monitor = resolve_monitor(sct, display)
    pixel_rects = build_pixel_rects(monitor["width"], monitor["height"])
    last_quantized: np.ndarray | None = None
    last_sent_at = 0.0

    try:
        if modem_pulse:
            try:
                pulse_modem_lines(fd, pulse_delay)
            except OSError:
                pass
        if boot_wait > 0:
            time.sleep(boot_wait)

        deadline = time.monotonic() + duration if duration > 0 else None
        while True:
            start = time.monotonic()
            if deadline is not None and start >= deadline:
                break

            try:
                capture_started = time.monotonic()
                bgra = capture_screen_array_mss(sct, monitor)
                colors = sample_edge_colors_from_bgra(bgra, pixel_rects, brightness)
                capture_elapsed = time.monotonic() - capture_started
                quantized = quantize_colors(colors)
                changed = last_quantized is None or not np.array_equal(quantized, last_quantized)
                keepalive_due = (
                    last_quantized is not None
                    and not changed
                    and (time.monotonic() - last_sent_at) >= DEFAULT_KEEPALIVE_SECONDS
                )
                write_elapsed = 0.0
                if changed or keepalive_due:
                    frame = make_color_frame_from_quantized(quantized)
                    write_started = time.monotonic()
                    write_all(fd, frame)
                    write_elapsed = time.monotonic() - write_started
                    last_quantized = quantized.copy()
                    last_sent_at = time.monotonic()
                    sent_frames += 1
                    stats_sent += 1
                else:
                    skipped_frames += 1
                    stats_skipped += 1
                frames += 1
                stats_frames += 1
                stats_capture += capture_elapsed
                stats_write += write_elapsed

                if stats_interval > 0:
                    now = time.monotonic()
                    window = now - stats_last
                    if window >= stats_interval:
                            print(
                                f"stats: fps={stats_frames / window:.2f} "
                                f"sent_fps={stats_sent / window:.2f} "
                                f"skipped={stats_skipped} "
                                f"capture_ms={(stats_capture / max(1, stats_frames)) * 1000:.1f} "
                                f"write_ms={(stats_write / max(1, stats_frames)) * 1000:.1f} "
                                f"elapsed={now - stats_started:.1f}s",
                                file=sys.stderr,
                                flush=True,
                        )
                            stats_last = now
                            stats_frames = 0
                            stats_sent = 0
                            stats_skipped = 0
                            stats_capture = 0.0
                            stats_write = 0.0

                current_interval = interval if changed else idle_interval
                if current_interval > 0:
                    sleep_for = current_interval - (time.monotonic() - start)
                    if sleep_for > 0:
                        time.sleep(sleep_for)
            except KeyboardInterrupt as exc:
                raise SyncInterrupted(frames) from exc

        return sent_frames
    finally:
        sct.close()
        off = make_frame(TOTAL_LED_COUNT, (0, 0, 0))
        try:
            write_all(fd, off)
        except OSError:
            pass
        os.close(fd)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Minimal SkyDimo screen sync using edge-only grid averaging."
    )
    parser.add_argument("--port", required=True, help="Serial port path, e.g. /dev/cu.usbserial-110")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    parser.add_argument("--fps", type=float, default=40.0)
    parser.add_argument(
        "--idle-fps",
        type=float,
        default=0.0,
        help="Polling FPS when sampled colors do not change; 0 disables idle throttling.",
    )
    parser.add_argument(
        "--brightness",
        type=float,
        default=0.10,
        help="Brightness scale applied to sampled RGB values",
    )
    parser.add_argument(
        "--display",
        type=int,
        default=1,
        help="Display index for mss capture. Use 1 for the first physical display.",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=0.0,
        help="Seconds to run; 0 means run until interrupted",
    )
    parser.add_argument(
        "--wire-utilization",
        type=float,
        default=DEFAULT_WIRE_UTILIZATION,
        help="Fraction of serial link capacity to target for low-latency output",
    )
    parser.add_argument(
        "--stats-interval",
        type=float,
        default=0.0,
        help="Emit rolling performance stats every N seconds; 0 disables it.",
    )
    parser.add_argument(
        "--modem-pulse",
        action="store_true",
        help="Toggle DTR/RTS when opening the port",
    )
    parser.add_argument("--pulse-delay", type=float, default=0.15)
    parser.add_argument("--boot-wait", type=float, default=0.0)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    start = time.monotonic()
    frames = 0
    interrupted = False
    try:
        frames = sync_loop(
            port=args.port,
            baud=args.baud,
            fps=args.fps,
            idle_fps=args.idle_fps,
            brightness=args.brightness,
            duration=args.duration,
            display=args.display,
            wire_utilization=args.wire_utilization,
            stats_interval=args.stats_interval,
            modem_pulse=args.modem_pulse,
            pulse_delay=args.pulse_delay,
            boot_wait=args.boot_wait,
        )
    except SyncInterrupted as exc:
        interrupted = True
        frames = exc.frames
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    elapsed = max(0.001, time.monotonic() - start)
    actual_fps = frames / elapsed
    paced_fps = effective_target_fps(args.fps, args.baud, args.wire_utilization)
    print(
        f"screen sync {'interrupted' if interrupted else 'complete'}: frames={frames} "
        f"target_fps={args.fps} paced_fps={paced_fps:.2f} actual_fps={actual_fps:.2f} "
        f"brightness={args.brightness} "
        f"elapsed={elapsed:.2f}s backend=mss display={args.display} "
        f"idle_fps={args.idle_fps} write_policy=drain"
    )
    return 130 if interrupted else 0


if __name__ == "__main__":
    raise SystemExit(main())
