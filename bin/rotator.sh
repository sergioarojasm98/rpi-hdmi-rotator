#!/bin/bash
# rpi-hdmi-rotator — main pipeline runner.
# Runs the GStreamer capture/rotate/display pipeline based on the values
# in rotator.conf. Waits for the capture device to appear before starting.

set -euo pipefail

VERSION="1.4.0"
if [[ "${1:-}" == "--version" ]]; then
    echo "rpi-hdmi-rotator $VERSION"
    exit 0
fi

CONFIG_FILE="${ROTATOR_CONFIG:-/etc/rpi-hdmi-rotator/rotator.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[rotator] Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Apply sensible defaults for any missing values.
: "${DEVICE:=/dev/video0}"
: "${INPUT_ENCODING:=raw}"
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
: "${DISPLAY_PAR:=1/1}"
: "${DEVICE_WAIT_SECONDS:=3}"

log() { echo "[rotator] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

validate_config() {
    local re='^[0-9]+$'
    for v in INPUT_WIDTH INPUT_HEIGHT OUTPUT_WIDTH OUTPUT_HEIGHT FRAMERATE \
             CROP_LEFT CROP_RIGHT CROP_TOP CROP_BOTTOM DEVICE_WAIT_SECONDS; do
        [[ "${!v}" =~ $re ]] || die "$v must be a positive integer (got '${!v}')"
    done
    [[ -n "$CONNECTOR_ID" && ! "$CONNECTOR_ID" =~ $re ]] && \
        die "CONNECTOR_ID must be empty or a positive integer (got '$CONNECTOR_ID')"
    case "$ROTATION" in
        clockwise|counterclockwise|rotate-180|none) ;;
        *) die "ROTATION must be clockwise|counterclockwise|rotate-180|none (got '$ROTATION')" ;;
    esac
    case "$INPUT_ENCODING" in
        raw|mjpeg) ;;
        *) die "INPUT_ENCODING must be raw or mjpeg (got '$INPUT_ENCODING')" ;;
    esac
}

validate_config

wait_for_device() {
    local attempts=0
    while [[ ! -e "$DEVICE" ]]; do
        attempts=$((attempts + 1))
        # Log every 10th attempt to avoid journal spam when device is absent.
        if [[ $((attempts % 10)) -eq 1 ]]; then
            log "Waiting for capture device $DEVICE (attempt $attempts)..."
        fi
        sleep "$DEVICE_WAIT_SECONDS"
    done
    log "Capture device $DEVICE ready (after $attempts retries)."
}

build_pipeline() {
    local pipeline=()

    # Source
    pipeline+=( "v4l2src" "device=$DEVICE" "io-mode=mmap" )

    if [[ "$INPUT_ENCODING" == "mjpeg" ]]; then
        # USB 2.0 capture sticks (MS2109 etc.) — compressed MJPEG from the card,
        # decoded on CPU. Pi4 has plenty of headroom for 1080p30.
        pipeline+=( "!" "image/jpeg,width=$INPUT_WIDTH,height=$INPUT_HEIGHT,framerate=$FRAMERATE/1" )
        pipeline+=( "!" "jpegdec" )
    else
        # USB 3.0 raw capture (zero-copy, no decode needed).
        pipeline+=( "!" "video/x-raw,format=$INPUT_FORMAT,width=$INPUT_WIDTH,height=$INPUT_HEIGHT,framerate=$FRAMERATE/1" )
    fi

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
    pipeline+=( "!" "video/x-raw,width=$OUTPUT_WIDTH,height=$OUTPUT_HEIGHT,pixel-aspect-ratio=$DISPLAY_PAR" )
    pipeline+=( "!" "videoconvert" )

    # Display via KMS/DRM
    local sink=( "kmssink" "sync=false" )
    [[ -n "$CONNECTOR_ID" ]] && sink+=( "connector-id=$CONNECTOR_ID" )
    pipeline+=( "!" "${sink[@]}" )

    echo "${pipeline[@]}"
}

wait_for_device

PIPELINE=$(build_pipeline)
log "Starting GStreamer pipeline:"
log "gst-launch-1.0 $PIPELINE"

# exec replaces this shell with gst-launch-1.0 so systemd (Type=simple)
# manages the process directly: SIGTERM goes straight to GStreamer, exit
# codes propagate, and there is no orphan wrapper.
# shellcheck disable=SC2086
exec gst-launch-1.0 $PIPELINE
