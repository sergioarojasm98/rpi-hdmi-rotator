#!/bin/bash
# rpi-hdmi-rotator — installer.
# Installs dependencies, files, and the systemd service.
# Usage: sudo ./install.sh [--silent-boot] [--non-interactive]
#   --silent-boot      Also apply quiet-boot tweaks (disable getty, quiet cmdline).
#   --non-interactive  Skip the interactive setup wizard at the end.

set -euo pipefail

SILENT_BOOT=0
NON_INTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
        --silent-boot) SILENT_BOOT=1 ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        -h|--help)
            sed -n '1,10p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo." >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/rpi-hdmi-rotator"
CONFIG_DIR="/etc/rpi-hdmi-rotator"
SERVICE_NAME="rpi-hdmi-rotator.service"

echo "==> Installing APT dependencies"
apt-get update -qq
apt-get install -y --no-install-recommends \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    v4l-utils \
    libdrm-tests

echo "==> Copying files to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/bin"
install -m 0755 "$REPO_DIR/bin/rotator.sh"  "$INSTALL_DIR/bin/rotator.sh"
install -m 0755 "$REPO_DIR/bin/diagnose.sh" "$INSTALL_DIR/bin/diagnose.sh"
install -m 0755 "$REPO_DIR/bin/setup.sh"    "$INSTALL_DIR/bin/setup.sh"

echo "==> Setting up config at $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/rotator.conf" ]]; then
    install -m 0644 "$REPO_DIR/config/rotator.conf.example" "$CONFIG_DIR/rotator.conf"
    echo "    New config installed — review $CONFIG_DIR/rotator.conf"
else
    echo "    Existing config preserved at $CONFIG_DIR/rotator.conf"
fi

echo "==> Installing systemd service"
install -m 0644 "$REPO_DIR/systemd/$SERVICE_NAME" "/etc/systemd/system/$SERVICE_NAME"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"

echo "==> Enabling higher USB current limit"
# Pi4 defaults to 600mA shared across all USB ports. USB capture cards
# (especially MS2109-based cheap sticks) can exceed this and disconnect
# every 10-15 seconds. Raises the per-port limit to 1.2A.
CONFIG_TXT="/boot/firmware/config.txt"
if [[ -f "$CONFIG_TXT" ]]; then
    if ! grep -q "^usb_max_current_enable=1" "$CONFIG_TXT"; then
        echo "usb_max_current_enable=1" >> "$CONFIG_TXT"
        echo "    Added usb_max_current_enable=1 — reboot required for this to take effect"
        NEEDS_REBOOT=1
    else
        echo "    Already enabled"
    fi
fi

if [[ $SILENT_BOOT -eq 1 ]]; then
    echo "==> Applying silent-boot tweaks"

    # Disable the login prompt on tty1 so it doesn't flash before the pipeline
    # takes over the display.
    systemctl disable getty@tty1.service 2>/dev/null || true
    systemctl mask    getty@tty1.service 2>/dev/null || true

    # Quiet the kernel at boot.
    CMDLINE="/boot/firmware/cmdline.txt"
    if [[ -f "$CMDLINE" ]]; then
        cp -n "$CMDLINE" "${CMDLINE}.bak" 2>/dev/null || true
        for flag in "quiet" "logo.nologo" "loglevel=0" "vt.global_cursor_default=0"; do
            grep -qw "$flag" "$CMDLINE" || sed -i "1 s|\$| $flag|" "$CMDLINE"
        done
        echo "    Updated $CMDLINE (backup saved)"
    else
        echo "    WARNING: $CMDLINE not found — skipping cmdline tweaks"
    fi
fi

echo
echo "Install complete."
if [[ "${NEEDS_REBOOT:-0}" -eq 1 ]]; then
    echo "⚠ Reboot required to enable higher USB current limit."
fi
echo

# Auto-launch the wizard if we have a TTY and the user didn't opt out.
if [[ -t 0 && $NON_INTERACTIVE -eq 0 ]]; then
    echo "==> Launching interactive setup wizard"
    "$INSTALL_DIR/bin/setup.sh"
else
    echo "Next steps:"
    echo "  1. Run setup:  sudo /opt/rpi-hdmi-rotator/bin/setup.sh"
    echo "  2. Diagnose:   /opt/rpi-hdmi-rotator/bin/diagnose.sh"
    echo "  3. Start:      sudo systemctl start $SERVICE_NAME"
    echo "  4. Reboot if silent-boot was applied or cmdline.txt changed"
fi
