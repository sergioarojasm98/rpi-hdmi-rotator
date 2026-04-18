#!/bin/bash
# rpi-hdmi-rotator — uninstaller.
# Reverses install.sh: stops the service, removes files, optionally undoes
# silent-boot tweaks.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo." >&2
    exit 1
fi

SERVICE_NAME="rpi-hdmi-rotator.service"

echo "==> Stopping and removing service"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICE_NAME"
systemctl daemon-reload

echo "==> Removing installed files"
rm -rf /opt/rpi-hdmi-rotator

echo "==> Removing config"
if [[ -d /etc/rpi-hdmi-rotator ]]; then
    echo "    Remove /etc/rpi-hdmi-rotator/rotator.conf? (y/N)"
    read -r answer
    if [[ "$answer" =~ ^[yY] ]]; then
        rm -rf /etc/rpi-hdmi-rotator
        echo "    Config removed."
    else
        echo "    Config preserved at /etc/rpi-hdmi-rotator/"
    fi
fi

echo "==> Restoring getty@tty1"
systemctl unmask getty@tty1.service 2>/dev/null || true
systemctl enable getty@tty1.service 2>/dev/null || true

CMDLINE="/boot/firmware/cmdline.txt"
if [[ -f "$CMDLINE" ]]; then
    echo "==> Cleaning cmdline.txt"
    for flag in "quiet" "logo.nologo" "loglevel=0" "vt.global_cursor_default=0"; do
        sed -i "s/ $flag//g" "$CMDLINE"
    done
    echo "    Removed silent-boot flags from $CMDLINE"
fi

echo
echo "Uninstall complete. Reboot to fully restore console output."
