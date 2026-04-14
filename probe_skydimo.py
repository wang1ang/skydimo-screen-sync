#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import glob
import os
import select
import struct
import sys
import termios
import time
from dataclasses import dataclass


DEFAULT_BAUD = 115200
DEFAULT_TIMEOUT = 2.5
DEFAULT_LED_COUNT = 114
PRESET_COLORS: dict[str, tuple[int, int, int]] = {
    "off": (0, 0, 0),
    "warm": (10, 5, 0),
    "red": (10, 0, 0),
    "green": (0, 10, 0),
    "blue": (0, 0, 10),
    "white": (5, 5, 5),
}
PRESET_SEQUENCES: dict[str, tuple[str, ...]] = {
    "rgb": ("red", "green", "blue", "warm", "off"),
}
SEGMENT_COLORS: tuple[tuple[str, tuple[int, int, int]], ...] = (
    ("seg1", PRESET_COLORS["red"]),
    ("seg2", PRESET_COLORS["green"]),
    ("seg3", PRESET_COLORS["blue"]),
    ("seg4", PRESET_COLORS["warm"]),
)


class ProbeError(Exception):
    pass


@dataclass
class Handshake:
    port: str
    raw: bytes
    model: str | None
    serial_hex: str | None


def list_candidate_ports() -> list[str]:
    ports = sorted(
        set(glob.glob("/dev/cu.*") + glob.glob("/dev/tty.*") + glob.glob("/dev/ttys*"))
    )
    return [port for port in ports if "Bluetooth-Incoming-Port" not in port]


def configure_port(fd: int, baud: int) -> None:
    attrs = termios.tcgetattr(fd)

    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0

    speed_attr = _baud_to_termios(baud)
    attrs[4] = speed_attr
    attrs[5] = speed_attr

    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0

    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def _baud_to_termios(baud: int) -> int:
    lookup = {
        9600: termios.B9600,
        19200: termios.B19200,
        38400: termios.B38400,
        57600: termios.B57600,
        115200: termios.B115200,
        230400: termios.B230400,
    }
    try:
        return lookup[baud]
    except KeyError as exc:
        raise ProbeError(f"Unsupported baud rate for stdlib probe: {baud}") from exc


def open_port(path: str, baud: int) -> int:
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure_port(fd, baud)
        return fd
    except Exception:
        os.close(fd)
        raise


def pulse_modem_lines(fd: int, delay: float) -> None:
    status = array_get_modem_status(fd)
    low = status & ~(termios.TIOCM_DTR | termios.TIOCM_RTS)
    high = low | termios.TIOCM_DTR | termios.TIOCM_RTS
    array_set_modem_status(fd, low)
    time.sleep(delay)
    array_set_modem_status(fd, high)


def array_get_modem_status(fd: int) -> int:
    buf = struct.pack("I", 0)
    raw = fcntl.ioctl(fd, termios.TIOCMGET, buf)
    return struct.unpack("I", raw)[0]


def array_set_modem_status(fd: int, value: int) -> None:
    buf = struct.pack("I", value)
    fcntl.ioctl(fd, termios.TIOCMSET, buf)


def read_bytes(fd: int, timeout: float) -> bytes:
    chunks: list[bytes] = []
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            break

        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            continue

        if not chunk:
            continue

        chunks.append(chunk)

    return b"".join(chunks)


def parse_handshake(port: str, raw: bytes) -> Handshake:
    payload = raw.strip(b"\x00\r\n\t ")
    model = None
    serial_hex = None

    if b"," in payload:
        prefix, suffix = payload.split(b",", 1)
        try:
            model = prefix.decode("ascii")
        except UnicodeDecodeError:
            model = None
        if suffix:
            serial_hex = suffix.hex().upper()

    return Handshake(port=port, raw=raw, model=model, serial_hex=serial_hex)


def verify_port(
    path: str,
    baud: int,
    timeout: float,
    boot_wait: float,
    modem_pulse: bool,
    pulse_delay: float,
) -> Handshake | None:
    try:
        fd = open_port(path, baud)
    except OSError:
        return None

    try:
        if modem_pulse:
            try:
                pulse_modem_lines(fd, pulse_delay)
            except OSError:
                pass
        if boot_wait > 0:
            time.sleep(boot_wait)
        raw = read_bytes(fd, timeout)
    finally:
        os.close(fd)

    if not raw:
        return None

    return parse_handshake(path, raw)


def make_frame(led_count: int, rgb: tuple[int, int, int]) -> bytes:
    if not 0 < led_count < 256:
        raise ProbeError("This probe currently supports led-count in 1...255.")

    r, g, b = rgb
    payload = bytes((r, g, b)) * led_count
    # Based on SkyDimo logs for SK0L32:
    # 41 64 61 00 00 72 + 342 bytes payload
    header = b"Ada" + b"\x00\x00" + bytes((led_count,))
    return header + payload


def make_chase_frame(
    led_count: int,
    index: int,
    rgb: tuple[int, int, int],
    tail: int,
) -> bytes:
    if not 1 <= index <= led_count:
        raise ProbeError(f"LED index out of range: {index}")

    pixels = [(0, 0, 0)] * led_count
    start = max(1, index - max(0, tail))
    for led in range(start, index + 1):
        pixels[led - 1] = rgb

    payload = bytearray()
    for r, g, b in pixels:
        payload.extend((r, g, b))

    header = b"Ada" + b"\x00\x00" + bytes((led_count,))
    return header + bytes(payload)


def make_segment_frame(led_count: int) -> bytes:
    # Based on the official SK0L32 map:
    # 1-20 left, 21-58 top, 59-78 right, 79-114 bottom.
    # This device's physical install is offset at the upper-left and lower-right
    # corners, so we shift one LED at each corner to the adjacent side.
    ranges = (
        (1, 20, PRESET_COLORS["red"]),
        (21, 57, PRESET_COLORS["green"]),
        (58, 77, PRESET_COLORS["blue"]),
        (78, 114, PRESET_COLORS["warm"]),
    )

    pixels = [(0, 0, 0)] * led_count
    for start, stop, rgb in ranges:
        for led in range(start, stop + 1):
            if 1 <= led <= led_count:
                pixels[led - 1] = rgb

    payload = bytearray()
    for r, g, b in pixels:
        payload.extend((r, g, b))

    header = b"Ada" + b"\x00\x00" + bytes((led_count,))
    return header + bytes(payload)


def write_frame(
    path: str,
    baud: int,
    frame: bytes,
    settle: float,
    modem_pulse: bool,
    pulse_delay: float,
    boot_wait: float,
) -> None:
    fd = open_port(path, baud)
    try:
        if modem_pulse:
            try:
                pulse_modem_lines(fd, pulse_delay)
            except OSError:
                pass
        if boot_wait > 0:
            time.sleep(boot_wait)
        os.write(fd, frame)
        termios.tcdrain(fd)
        if settle > 0:
            time.sleep(settle)
    finally:
        os.close(fd)


def stream_frames(
    path: str,
    baud: int,
    frame: bytes,
    duration: float,
    fps: float,
    modem_pulse: bool,
    pulse_delay: float,
    boot_wait: float,
) -> int:
    fd = open_port(path, baud)
    sent = 0
    try:
        if modem_pulse:
            try:
                pulse_modem_lines(fd, pulse_delay)
            except OSError:
                pass
        if boot_wait > 0:
            time.sleep(boot_wait)

        interval = 1.0 / fps if fps > 0 else 0.0
        deadline = time.monotonic() + max(0.0, duration)
        while True:
            now = time.monotonic()
            if duration > 0 and now >= deadline:
                break
            os.write(fd, frame)
            termios.tcdrain(fd)
            sent += 1
            if interval > 0:
                sleep_for = interval - (time.monotonic() - now)
                if sleep_for > 0:
                    time.sleep(sleep_for)
            elif duration <= 0:
                break
        return sent
    finally:
        os.close(fd)


def stream_sequence(
    path: str,
    baud: int,
    led_count: int,
    sequence: tuple[str, ...],
    step_duration: float,
    fps: float,
    modem_pulse: bool,
    pulse_delay: float,
    boot_wait: float,
) -> list[tuple[str, tuple[int, int, int], int]]:
    fd = open_port(path, baud)
    interval = 1.0 / fps if fps > 0 else 0.0
    results: list[tuple[str, tuple[int, int, int], int]] = []

    try:
        if modem_pulse:
            try:
                pulse_modem_lines(fd, pulse_delay)
            except OSError:
                pass
        if boot_wait > 0:
            time.sleep(boot_wait)

        for name in sequence:
            rgb = PRESET_COLORS[name]
            frame = make_frame(led_count, rgb)
            sent = 0
            deadline = time.monotonic() + max(0.0, step_duration)
            while True:
                now = time.monotonic()
                if step_duration > 0 and now >= deadline:
                    break
                os.write(fd, frame)
                termios.tcdrain(fd)
                sent += 1
                if interval > 0:
                    sleep_for = interval - (time.monotonic() - now)
                    if sleep_for > 0:
                        time.sleep(sleep_for)
                elif step_duration <= 0:
                    break
            results.append((name, rgb, sent))

        return results
    finally:
        os.close(fd)


def run_chase(
    path: str,
    baud: int,
    led_count: int,
    rgb: tuple[int, int, int],
    fps: float,
    step_duration: float,
    tail: int,
    loop: bool,
    modem_pulse: bool,
    pulse_delay: float,
    boot_wait: float,
) -> int:
    fd = open_port(path, baud)
    interval = 1.0 / fps if fps > 0 else 0.0
    total_frames = 0

    try:
        if modem_pulse:
            try:
                pulse_modem_lines(fd, pulse_delay)
            except OSError:
                pass
        if boot_wait > 0:
            time.sleep(boot_wait)

        while True:
            for led in range(1, led_count + 1):
                frame = make_chase_frame(led_count, led, rgb, tail)
                deadline = time.monotonic() + max(0.0, step_duration)
                while True:
                    now = time.monotonic()
                    if step_duration > 0 and now >= deadline:
                        break
                    os.write(fd, frame)
                    termios.tcdrain(fd)
                    total_frames += 1
                    if interval > 0:
                        sleep_for = interval - (time.monotonic() - now)
                        if sleep_for > 0:
                            time.sleep(sleep_for)
                    elif step_duration <= 0:
                        break
            if not loop:
                break

        off = make_frame(led_count, (0, 0, 0))
        os.write(fd, off)
        termios.tcdrain(fd)
        return total_frames
    finally:
        os.close(fd)


def parse_rgb(value: str) -> tuple[int, int, int]:
    raw = value.strip().removeprefix("#")
    if len(raw) != 6:
        raise argparse.ArgumentTypeError("RGB must be 6 hex chars, e.g. FF0000")
    try:
        rgb = bytes.fromhex(raw)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("RGB must be valid hex") from exc
    return rgb[0], rgb[1], rgb[2]


def print_handshake(result: Handshake) -> None:
    print(f"port: {result.port}")
    print(f"raw: {result.raw!r}")
    if result.model:
        print(f"model: {result.model}")
    if result.serial_hex:
        print(f"serial_hex: {result.serial_hex}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Probe SkyDimo serial devices without third-party dependencies."
    )
    parser.add_argument("--port", help="Serial port path, e.g. /dev/cu.usbserial-110")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    parser.add_argument(
        "--boot-wait",
        type=float,
        default=0.8,
        help="Wait after opening the serial port before reading, in seconds",
    )
    parser.add_argument(
        "--no-modem-pulse",
        action="store_true",
        help="Do not toggle DTR/RTS when opening the port",
    )
    parser.add_argument(
        "--pulse-delay",
        type=float,
        default=0.15,
        help="How long to hold DTR/RTS low before restoring them",
    )
    parser.add_argument("--scan", action="store_true", help="Scan candidate serial ports")
    parser.add_argument(
        "--handshake-only",
        action="store_true",
        help="Open the port, read the handshake, do not write any frame",
    )
    parser.add_argument(
        "--solid",
        type=parse_rgb,
        metavar="RRGGBB",
        help="Send a solid-color frame, e.g. FF0000",
    )
    parser.add_argument(
        "--preset",
        choices=sorted(PRESET_COLORS),
        help="Send a built-in low-brightness test color",
    )
    parser.add_argument(
        "--sequence",
        choices=sorted(PRESET_SEQUENCES),
        help="Run a built-in multi-step color test sequence",
    )
    parser.add_argument(
        "--chase",
        action="store_true",
        help="Run a moving single-LED position test",
    )
    parser.add_argument(
        "--segments",
        action="store_true",
        help="Light four static contiguous segments in red/green/blue/warm order",
    )
    parser.add_argument("--led-count", type=int, default=DEFAULT_LED_COUNT)
    parser.add_argument(
        "--duration",
        type=float,
        default=0.0,
        help="Stream this many seconds instead of sending a single frame",
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=10.0,
        help="Frame rate used with --duration",
    )
    parser.add_argument(
        "--step-duration",
        type=float,
        default=2.0,
        help="Seconds per color when using --sequence",
    )
    parser.add_argument(
        "--tail",
        type=int,
        default=0,
        help="Number of trailing LEDs to keep lit in chase mode",
    )
    parser.add_argument(
        "--loop",
        action="store_true",
        help="Keep chase mode running until interrupted",
    )
    parser.add_argument(
        "--settle",
        type=float,
        default=0.2,
        help="Keep the port open briefly after writing, in seconds",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.scan:
        found = False
        for port in list_candidate_ports():
            result = verify_port(
                port,
                args.baud,
                args.timeout,
                args.boot_wait,
                not args.no_modem_pulse,
                args.pulse_delay,
            )
            if result is None:
                continue
            found = True
            print("== handshake ==")
            print_handshake(result)
        return 0 if found else 1

    if not args.port:
        parser.error("Either pass --scan or provide --port.")

    if sum(bool(x) for x in (args.solid, args.preset)) > 1:
        parser.error("Use only one of --solid or --preset.")
    if args.sequence and (args.solid or args.preset):
        parser.error("--sequence cannot be combined with --solid or --preset.")
    if args.segments and (args.solid or args.preset or args.sequence or args.chase):
        parser.error("--segments cannot be combined with other display modes.")

    rgb = args.solid
    if args.preset:
        rgb = PRESET_COLORS[args.preset]

    if args.handshake_only or (rgb is None and not args.sequence and not args.chase and not args.segments):
        result = verify_port(
            args.port,
            args.baud,
            args.timeout,
            args.boot_wait,
            not args.no_modem_pulse,
            args.pulse_delay,
        )
        if result is None:
            print("No handshake data received.", file=sys.stderr)
            return 2
        print_handshake(result)

    if args.segments:
        frame = make_segment_frame(args.led_count)
        sent = stream_frames(
            args.port,
            args.baud,
            frame,
            args.duration if args.duration > 0 else 10.0,
            args.fps,
            not args.no_modem_pulse,
            args.pulse_delay,
            args.boot_wait,
        )
        print(
            "segments active: "
            "seg1=red(1-20) seg2=green(21-58) seg3=blue(59-78) seg4=warm(79-114) "
            f"frames={sent}"
        )
    elif args.chase:
        chase_rgb = rgb or PRESET_COLORS["warm"]
        total_frames = run_chase(
            args.port,
            args.baud,
            args.led_count,
            chase_rgb,
            args.fps,
            args.step_duration,
            args.tail,
            args.loop,
            not args.no_modem_pulse,
            args.pulse_delay,
            args.boot_wait,
        )
        print(
            f"chase complete: leds={args.led_count} rgb={chase_rgb} total_frames={total_frames} step_duration={args.step_duration}s fps={args.fps} loop={args.loop}"
        )
    elif args.sequence:
        results = stream_sequence(
            args.port,
            args.baud,
            args.led_count,
            PRESET_SEQUENCES[args.sequence],
            args.step_duration,
            args.fps,
            not args.no_modem_pulse,
            args.pulse_delay,
            args.boot_wait,
        )
        for name, seq_rgb, sent in results:
            print(f"sequence step: {name} rgb={seq_rgb} frames={sent}")
    elif rgb is not None:
        frame = make_frame(args.led_count, rgb)
        if args.duration > 0:
            sent = stream_frames(
                args.port,
                args.baud,
                frame,
                args.duration,
                args.fps,
                not args.no_modem_pulse,
                args.pulse_delay,
                args.boot_wait,
            )
            print(
                f"streamed frames: port={args.port} leds={args.led_count} rgb={rgb} bytes={len(frame)} count={sent} duration={args.duration}s fps={args.fps}"
            )
        else:
            write_frame(
                args.port,
                args.baud,
                frame,
                args.settle,
                not args.no_modem_pulse,
                args.pulse_delay,
                args.boot_wait,
            )
            print(
                f"sent frame: port={args.port} leds={args.led_count} rgb={rgb} bytes={len(frame)}"
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
