# rpi-hdmi-rotator

Headless HDMI video rotator for Raspberry Pi 4. Captures USB video from any
UVC-compatible HDMI capture card, rotates the signal in software, and
displays it fullscreen on a physically-rotated monitor via KMS/DRM.

## Why

iPhones (and most USB-C → HDMI adapters) cannot force the output orientation
when mirroring. If you shoot vertical video and want a large external
viewfinder in portrait, the HDMI signal arrives in landscape and looks wrong
on a rotated monitor. This tool intercepts the capture, crops the source
letterboxing, rotates, and stretches the signal so the physical rotation of
the monitor produces a correctly-oriented fullscreen image.

## How it works

```mermaid
flowchart LR
    iPhone[iPhone /<br/>HDMI source] --> Adapter[USB-C to<br/>HDMI adapter]
    Adapter --> Capture[HDMI Capture<br/>Card USB]
    Capture --> Pi4
    subgraph Pi4["Raspberry Pi 4"]
        Source[v4l2src<br/>raw or MJPEG] --> Crop[videocrop<br/>remove letterbox]
        Crop --> Flip[videoflip<br/>90°]
        Flip --> Scale[videoscale<br/>stretch to 1920x1080]
        Scale --> Sink[kmssink<br/>HDMI0 / connector 33]
    end
    Pi4 --> Monitor[Physically-rotated<br/>portrait monitor]
```

The key insight: a landscape signal stretched to the monitor's native
resolution looks portrait and fullscreen when the monitor is physically
rotated 90°, because the stretch in signal space is undone by the physical
rotation in viewing space.

## Stack

| Layer | Tool |
|-------|------|
| OS | Raspberry Pi OS Lite 64-bit (Bookworm or Trixie) |
| Capture | v4l2src (UVC) |
| Processing | videocrop + videoflip + videoscale + videoconvert |
| Display | kmssink (DRM/KMS, no X11, no Wayland) |
| Service | systemd |

## Hardware

### Requirements

- Raspberry Pi 4 Model B (4GB recommended)
- Any UVC-compatible HDMI capture card (USB)
- 1920x1080 monitor, physically rotated 90°
- iPhone 15 Pro Max or later via USB-C → HDMI adapter

### Tested capture cards

Any HDMI-to-USB capture card that presents as a standard UVC device should
work. The setup wizard auto-detects encoding (raw or MJPEG) and resolution.

| Card | Bus | Encoding | Price | Notes |
|------|-----|----------|-------|-------|
| Elgato Cam Link 4K | USB 3.0 | Raw NV12 | ~$130 | Zero-copy, lowest latency, best quality |
| Generic MS2109 (no loop) | USB 2.0 | MJPEG | ~$10-15 | Budget option, good enough for viewfinder |
| Generic MS2109 (with loop) | USB 2.0 | MJPEG | ~$20-30 | Budget + HDMI passthrough |

**Note:** avoid connecting two USB 2.0 sticks simultaneously — the Pi4's
USB ports may not deliver enough power for both.

## Install

```bash
git clone https://github.com/sergioarojasm98/rpi-hdmi-rotator.git
cd rpi-hdmi-rotator
sudo ./install.sh
```

For a silent boot (no login prompt, no kernel messages):

```bash
sudo ./install.sh --silent-boot
```

The installer runs an interactive setup wizard at the end that:

1. Detects your USB capture device automatically
2. Detects the active HDMI connector automatically
3. Calibrates the rotation direction by showing a test pattern and asking
   which direction looks correct
4. Asks about your source (iPhone 15 Pro Max+, full-frame, or custom)
   and sets letterbox crop values accordingly
5. Writes `/etc/rpi-hdmi-rotator/rotator.conf`
6. Runs the live pipeline for 10 seconds so you can confirm it looks right
7. Starts the service

To skip the wizard and configure manually, use `--non-interactive`.

Re-run the wizard any time:

```bash
sudo /opt/rpi-hdmi-rotator/bin/setup.sh
```

## Configuration

The recommended way to configure is the setup wizard
(`sudo /opt/rpi-hdmi-rotator/bin/setup.sh`). It auto-detects your capture
card and picks the best encoding automatically.

Manual editing of `/etc/rpi-hdmi-rotator/rotator.conf` is also supported.
Key parameters:

| Parameter | Purpose |
|-----------|---------|
| `DEVICE` | V4L2 capture device (default `/dev/video0`) |
| `INPUT_WIDTH`/`HEIGHT`/`FRAMERATE` | Format negotiated with the capture |
| `CROP_LEFT`/`RIGHT`/`TOP`/`BOTTOM` | Remove source letterboxing |
| `ROTATION` | `clockwise`, `counterclockwise`, `rotate-180`, `none` |
| `CONNECTOR_ID` | DRM connector for the HDMI output |
| `INPUT_ENCODING` | `raw` (USB 3.0 cards) or `mjpeg` (USB 2.0 sticks) |
| `INPUT_FORMAT` | Pixel format for raw mode (`NV12`, `YUY2`) |
| `OUTPUT_WIDTH`/`HEIGHT` | Signal resolution sent to the monitor |
| `DEVICE_WAIT_SECONDS` | Retry interval when capture device is missing |

Find your connector ID with:

```bash
sudo modetest -M vc4 -c
```

## Troubleshooting

Run the diagnostics helper:

```bash
/opt/rpi-hdmi-rotator/bin/diagnose.sh
```

Live logs:

```bash
journalctl -u rpi-hdmi-rotator -f
```

Test the pipeline manually:

```bash
sudo /opt/rpi-hdmi-rotator/bin/rotator.sh
```

## Limitations

- Source is assumed to letterbox portrait content. For full-frame sources
  set all `CROP_*` to `0`.
- Resolutions above 1080p30 have not been tested (bandwidth and CPU
  headroom are fine on Pi4 for 1080p60 NV12 but not validated end-to-end).
- Only single-source single-monitor setups are supported.

## Uninstall

```bash
cd rpi-hdmi-rotator
sudo ./uninstall.sh
sudo reboot
```

## License

MIT
