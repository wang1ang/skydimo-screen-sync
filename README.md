# SkyDimo Probe

Minimal Python tools for a SkyDimo serial light on macOS.

`probe_skydimo.py` uses only the Python standard library.
`screen_sync.py` requires `mss` for screen capture:

```bash
python3 -m pip install --user mss
```

Examples:

```bash
python3 probe_skydimo.py --scan
python3 probe_skydimo.py --port /dev/cu.usbserial-110 --handshake-only
python3 probe_skydimo.py --port /dev/cu.usbserial-110 --sequence rgb --step-duration 2 --fps 6 --boot-wait 0 --no-modem-pulse
python3 probe_skydimo.py --port /dev/cu.usbserial-110 --preset warm --duration 5 --fps 6
python3 probe_skydimo.py --port /dev/cu.usbserial-110 --preset red --duration 5 --fps 6
python3 probe_skydimo.py --port /dev/cu.usbserial-110 --preset green --duration 5 --fps 6
python3 probe_skydimo.py --port /dev/cu.usbserial-110 --preset blue --duration 5 --fps 6
python3 probe_skydimo.py --port /dev/cu.usbserial-110 --preset off --duration 2 --fps 6
python3 probe_skydimo.py --port /dev/cu.usbserial-110 --led-count 114 --solid FF0000
python3 probe_skydimo.py --port /dev/cu.usbserial-110 --led-count 114 --solid 000000
python3 screen_sync.py --port /dev/cu.usbserial-110
python3 screen_sync.py --port /dev/cu.usbserial-110 --stats-interval 2
python3 screen_sync.py --port /dev/cu.usbserial-110 --display 2
```

Current assumptions from the official app logs:

- device model: `SK0L32`
- serial port: `/dev/cu.usbserial-110`
- LED count: `114`
- baud rate: `115200`
- frame format: `41 64 61 00 00 <led_count> + RGB payload`

Current physical mapping confirmed on this setup:

- right: `1-20`
- top: `21-57`
- left: `58-77`
- bottom: `78-114`

Sampling model used by `screen_sync.py`:

- top and bottom: `37` bins each
- left and right: `20` bins each
- horizontal dead space: `2` LED spacings on both sides
- vertical dead space: `1.5` LED spacings on both sides

Current `screen_sync.py` defaults:

- backend: `mss`
- fps: `40`
- idle-fps: `0` (disabled)
- brightness: `0.10`
- display: `1`
- wire-utilization: `0.85`

Notes:

- `display=1` means the first physical display reported by `mss`
- this controller works reliably at `115200` baud
- the current best-performing path is full-display capture plus full-frame serial updates
