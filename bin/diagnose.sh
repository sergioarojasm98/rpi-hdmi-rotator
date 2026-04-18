#!/bin/bash
# rpi-hdmi-rotator — diagnostics.
# Reports on hardware, software, config, and service state.

set -uo pipefail

VERSION="1.0.0"
if [[ "${1:-}" == "--version" ]]; then
    echo "rpi-hdmi-rotator diagnose $VERSION"
    exit 0
fi

CONFIG_FILE="${ROTATOR_CONFIG:-/etc/rpi-hdmi-rotator/rotator.conf}"

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
header(){ printf "\n\033[1m=== %s ===\033[0m\n" "$*"; }

[[ $EUID -ne 0 ]] && yellow "Tip: run with sudo for complete results"
echo

header "System"
uname -a
grep -E "PRETTY_NAME|VERSION_CODENAME" /etc/os-release 2>/dev/null

header "Config file"
if [[ -f "$CONFIG_FILE" ]]; then
    green "OK: $CONFIG_FILE present"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    echo "  DEVICE=${DEVICE:-}"
    echo "  INPUT=${INPUT_FORMAT:-}/${INPUT_WIDTH:-}x${INPUT_HEIGHT:-}@${FRAMERATE:-}"
    echo "  CROP=L${CROP_LEFT:-0} R${CROP_RIGHT:-0} T${CROP_TOP:-0} B${CROP_BOTTOM:-0}"
    echo "  ROTATION=${ROTATION:-}"
    echo "  OUTPUT=${OUTPUT_WIDTH:-}x${OUTPUT_HEIGHT:-}"
    echo "  CONNECTOR_ID=${CONNECTOR_ID:-}"
else
    red "MISSING: $CONFIG_FILE (copy from rotator.conf.example)"
fi

header "Capture device"
if [[ -e "${DEVICE:-/dev/video0}" ]]; then
    green "OK: ${DEVICE:-/dev/video0} exists"
    if command -v v4l2-ctl >/dev/null 2>&1; then
        v4l2-ctl -d "${DEVICE:-/dev/video0}" --list-formats-ext 2>/dev/null | head -30
    else
        yellow "v4l2-ctl not installed — install v4l-utils for format details"
    fi
else
    red "MISSING: ${DEVICE:-/dev/video0}"
fi

header "USB devices"
lsusb | grep -iE "elgato|cam link|game capture|capture" || yellow "No known capture devices found"

header "DRM connectors"
found_hdmi=0
for c in /sys/class/drm/card*-HDMI*; do
    [[ -d "$c" ]] && { echo "  $(basename "$c"): $(cat "$c/status")"; found_hdmi=1; }
done
[[ $found_hdmi -eq 0 ]] && yellow "No HDMI connectors found"

header "GStreamer plugins"
for p in v4l2src videocrop videoflip videoscale videoconvert kmssink; do
    if gst-inspect-1.0 "$p" >/dev/null 2>&1; then
        green "OK: $p"
    else
        red "MISSING: $p"
    fi
done

header "Service state"
if systemctl list-unit-files rpi-hdmi-rotator.service >/dev/null 2>&1; then
    systemctl --no-pager status rpi-hdmi-rotator.service 2>&1 | head -15
else
    yellow "Service not installed"
fi

header "Recent logs"
if systemctl list-unit-files rpi-hdmi-rotator.service >/dev/null 2>&1; then
    journalctl -u rpi-hdmi-rotator.service -n 20 --no-pager 2>/dev/null || yellow "No journal entries"
else
    yellow "(service not installed)"
fi
