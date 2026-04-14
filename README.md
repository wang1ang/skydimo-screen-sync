# SkyDimo Probe

Minimal probe for a SkyDimo serial light on macOS.

No third-party dependency is required. The script uses Python's `termios` APIs.

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
