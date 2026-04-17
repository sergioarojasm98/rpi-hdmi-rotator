#!/bin/bash
# rpi-hdmi-rotator — main pipeline runner.
# Runs the GStreamer capture/rotate/display pipeline based on the values
# in rotator.conf. Waits for the capture device to appear before starting.

set -euo pipefail

CONFIG_FILE="${ROTATOR_CONFIG:-/etc/rpi-hdmi-rotator/rotator.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[rotator] Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Apply sensible defaults for any missing values.
: "${DEVICE:=/dev/video0}"
: "${INPUT_FORMAT:=NV12}"
: "${INPUT_WIDTH:=1920}"
: "${INPUT_HEIGHT:=1080}"
: "${FRAMERATE:=30}"
: "${CROP_LEFT:=0}"
: "${CROP_RIGHT:=0}"
: "${CROP_TOP:=0}"
: "${CROP_BOTTOM:=0}"
: "${ROTATION:=none}"
: "${CONNECTOR_ID:=}"
: "${OUTPUT_WIDTH:=1920}"
: "${OUTPUT_HEIGHT:=1080}"
: "${DEVICE_WAIT_SECONDS:=3}"

log() { echo "[rotator] $*"; }

wait_for_device() {
    while [[ ! -e "$DEVICE" ]]; do
        log "Waiting for capture device $DEVICE..."
        sleep "$DEVICE_WAIT_SECONDS"
    done
    log "Capture device $DEVICE ready."
}

build_pipeline() {
    local pipeline=()

    # Source
    pipeline+=( "v4l2src" "device=$DEVICE" "io-mode=mmap" )
    pipeline+=( "!" "video/x-raw,format=$INPUT_FORMAT,width=$INPUT_WIDTH,height=$INPUT_HEIGHT,framerate=$FRAMERATE/1" )

    # Crop (only if non-zero)
    if [[ "$CROP_LEFT" -gt 0 || "$CROP_RIGHT" -gt 0 || "$CROP_TOP" -gt 0 || "$CROP_BOTTOM" -gt 0 ]]; then
        pipeline+=( "!" "videocrop" "left=$CROP_LEFT" "right=$CROP_RIGHT" "top=$CROP_TOP" "bottom=$CROP_BOTTOM" )
    fi

    # Rotation (skip if "none")
    if [[ "$ROTATION" != "none" && -n "$ROTATION" ]]; then
        pipeline+=( "!" "videoflip" "method=$ROTATION" )
    fi

    # Scale to output resolution without preserving aspect (fills display;
    # the stretch compensates for the physical rotation of the monitor).
    pipeline+=( "!" "videoscale" "add-borders=false" )
    pipeline+=( "!" "video/x-raw,width=$OUTPUT_WIDTH,height=$OUTPUT_HEIGHT,pixel-aspect-ratio=1/1" )
    pipeline+=( "!" "videoconvert" )

    # Display via KMS/DRM
    local sink=( "kmssink" "sync=false" )
    [[ -n "$CONNECTOR_ID" ]] && sink+=( "connector-id=$CONNECTOR_ID" )
    pipeline+=( "!" "${sink[@]}" )

    echo "${pipeline[@]}"
}

cleanup() {
    log "Shutting down."
    if [[ -n "${GST_PID:-}" ]]; then
        kill -TERM "$GST_PID" 2>/dev/null || true
    fi
    exit 0
}

trap cleanup SIGTERM SIGINT

wait_for_device

PIPELINE=$(build_pipeline)
log "Starting GStreamer pipeline:"
log "gst-launch-1.0 $PIPELINE"

# shellcheck disable=SC2086
exec gst-launch-1.0 $PIPELINE
