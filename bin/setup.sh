#!/bin/bash
# rpi-hdmi-rotator — interactive setup wizard.
# Detects capture device and DRM connector, calibrates rotation, and writes
# /etc/rpi-hdmi-rotator/rotator.conf based on user choices.

set -euo pipefail

VERSION="1.4.2"
if [[ "${1:-}" == "--version" ]]; then
    echo "rpi-hdmi-rotator setup $VERSION"
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo." >&2
    exit 1
fi

CONFIG_DIR="/etc/rpi-hdmi-rotator"
CONFIG_FILE="$CONFIG_DIR/rotator.conf"
SERVICE_NAME="rpi-hdmi-rotator.service"

green()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
header() { printf "\n\033[1m=== %s ===\033[0m\n" "$*"; }

# Populated by the wizard steps.
DEVICE=""
INPUT_ENCODING=""
INPUT_FORMAT=""
INPUT_WIDTH=""
INPUT_HEIGHT=""
FRAMERATE=""
CONNECTOR_ID=""
ROTATION=""
CROP_LEFT=0
CROP_RIGHT=0
CROP_TOP=0
CROP_BOTTOM=0

GSTPID=""

cleanup_gst() {
    if [[ -n "$GSTPID" ]] && kill -0 "$GSTPID" 2>/dev/null; then
        kill "$GSTPID" 2>/dev/null || true
        wait "$GSTPID" 2>/dev/null || true
    fi
    GSTPID=""
}
trap cleanup_gst EXIT

# Launch GStreamer in the background; aborts the wizard if it dies within 2s.
launch_gst_bg() {
    local cmd=("$@")
    "${cmd[@]}" >/tmp/rotator-setup.log 2>&1 &
    GSTPID=$!
    sleep 2
    if ! kill -0 "$GSTPID" 2>/dev/null; then
        red "GStreamer pipeline failed to start. Check /tmp/rotator-setup.log:"
        tail -5 /tmp/rotator-setup.log >&2
        GSTPID=""
        return 1
    fi
    return 0
}

stop_service_if_running() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        yellow "Stopping $SERVICE_NAME for calibration (will offer to restart at the end)..."
        systemctl stop "$SERVICE_NAME"
        SERVICE_WAS_RUNNING=1
    else
        SERVICE_WAS_RUNNING=0
    fi
}

# -----------------------------------------------------------------------------
# Step 1: Capture device detection
# -----------------------------------------------------------------------------
detect_capture_device() {
    header "Step 1: Capture device"

    if ! command -v v4l2-ctl >/dev/null 2>&1; then
        yellow "v4l2-ctl not installed — install v4l-utils or enter device manually."
        read -rp "Device path (e.g., /dev/video0): " DEVICE
        [[ -e "$DEVICE" ]] || { red "Device $DEVICE does not exist."; exit 1; }
        return
    fi

    local candidates=()
    local names=()
    for node in /dev/video*; do
        [[ -c "$node" ]] || continue
        local info
        info=$(v4l2-ctl -d "$node" --info 2>/dev/null || true)
        # Must be UVC (USB capture). Pi built-in drivers use pispbe/rpi-hevc-dec.
        echo "$info" | grep -q "Driver name *: uvcvideo" || continue
        # Must expose an actual Video Capture interface — list-formats returns
        # nothing for metadata-only nodes that also report "Video Capture"
        # under driver Capabilities.
        v4l2-ctl -d "$node" --list-formats 2>/dev/null | grep -q "^\s*\[" || continue
        local card
        card=$(echo "$info" | awk -F': ' '/Card type/ {print $2; exit}')
        candidates+=("$node")
        names+=("${card:-unknown}")
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        red "No USB capture device detected. Plug in your HDMI capture card and re-run."
        exit 1
    fi

    if [[ ${#candidates[@]} -eq 1 ]]; then
        DEVICE="${candidates[0]}"
        green "Auto-selected: $DEVICE (${names[0]})"
        return
    fi

    echo "Multiple capture devices found:"
    local i
    for i in "${!candidates[@]}"; do
        printf "  %d) %s — %s\n" $((i + 1)) "${candidates[i]}" "${names[i]}"
    done
    local choice
    while true; do
        read -rp "Pick [1-${#candidates[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )); then
            DEVICE="${candidates[$((choice - 1))]}"
            green "Selected: $DEVICE (${names[$((choice - 1))]})"
            return
        fi
        red "Invalid choice."
    done
}

# -----------------------------------------------------------------------------
# Step 1b: Input format auto-detection
# -----------------------------------------------------------------------------

# Check whether the given device supports a specific (v4l2 fourcc, width,
# height, framerate) tuple. Returns 0 if supported.
# Uses mawk-compatible awk (no GNU-only match() capture groups).
has_format() {
    local dev="$1" fourcc="$2" w="$3" h="$4" fps="$5"
    local formats fps_tag
    formats=$(v4l2-ctl -d "$dev" --list-formats-ext 2>/dev/null || true)
    # v4l2-ctl always prints fps as "(N.NNN fps)" with 3 decimals.
    fps_tag="($(printf '%.3f' "$fps") fps)"
    echo "$formats" | awk -v f="'$fourcc'" -v s=" ${w}x${h}" -v tag="$fps_tag" '
        index($0, ": " f) { in_fmt = 1; in_size = 0; next }
        /^\s*\[[0-9]+\]:/ { in_fmt = 0; next }
        in_fmt && /Size: Discrete / { in_size = (index($0, s) > 0); next }
        in_fmt && in_size && index($0, tag) { found = 1; exit }
        END { exit !found }
    '
}

detect_input_format() {
    header "Step 1b: Input format"

    # Preference order from best (zero-copy, low latency) to acceptable
    # (compressed, decoder on CPU). Format is "fourcc:encoding:width:height:fps".
    local preferences=(
        "NV12:raw:NV12:1920:1080:30"       # USB 3.0 cards (raw, zero-copy)
        "YUYV:raw:YUY2:1920:1080:30"       # raw fallback
        "MJPG:mjpeg::1920:1080:30"         # MS2109 cheap sticks (USB 2.0)
        "MJPG:mjpeg::1920:1080:25"         # MS2109 low-fps fallback
        "MJPG:mjpeg::1280:720:30"          # bandwidth-limited fallback
    )

    local pref
    for pref in "${preferences[@]}"; do
        IFS=':' read -r fourcc encoding gst_format w h fps <<< "$pref"
        if has_format "$DEVICE" "$fourcc" "$w" "$h" "$fps"; then
            INPUT_ENCODING="$encoding"
            INPUT_FORMAT="$gst_format"
            INPUT_WIDTH="$w"
            INPUT_HEIGHT="$h"
            FRAMERATE="$fps"
            if [[ "$encoding" == "mjpeg" ]]; then
                green "Auto-selected: MJPEG ${w}x${h}@${fps} (USB 2.0 capture, CPU decode)"
            else
                green "Auto-selected: $fourcc ${w}x${h}@${fps} (USB 3.0 raw, zero-copy)"
            fi
            return
        fi
    done

    red "Could not find a supported format for $DEVICE."
    red "Expected one of: NV12 1080p30, YUYV 1080p30, MJPG 1080p30/25, MJPG 720p30."
    yellow "Run: v4l2-ctl -d $DEVICE --list-formats-ext"
    exit 1
}

# -----------------------------------------------------------------------------
# Step 2: DRM connector detection
# -----------------------------------------------------------------------------
detect_connector() {
    header "Step 2: HDMI connector"

    # Find physically connected HDMI connector names from sysfs.
    local connected_names=()
    for c in /sys/class/drm/card*-HDMI*; do
        [[ -d "$c" ]] || continue
        if [[ "$(cat "$c/status" 2>/dev/null)" == "connected" ]]; then
            local name
            name=$(basename "$c" | sed 's/.*-\(HDMI-[A-Z]-[0-9]*\)$/\1/')
            connected_names+=("$name")
        fi
    done

    if [[ ${#connected_names[@]} -eq 0 ]]; then
        red "No HDMI monitor detected. Check the cable and re-run."
        exit 1
    fi

    if ! command -v modetest >/dev/null 2>&1; then
        yellow "modetest not installed (libdrm-tests). Enter connector ID manually."
        yellow "Connected: ${connected_names[*]}"
        read -rp "Connector ID (numeric): " CONNECTOR_ID
        [[ "$CONNECTOR_ID" =~ ^[0-9]+$ ]] || { red "Invalid connector ID."; exit 1; }
        return
    fi

    # Parse modetest output to map name -> numeric ID.
    local modetest_out
    modetest_out=$(modetest -M vc4 -c 2>/dev/null || true)

    local connected_ids=()
    local connected_labels=()
    for name in "${connected_names[@]}"; do
        local id
        id=$(echo "$modetest_out" | awk -v n="$name" '$3 == "connected" && $4 == n {print $1; exit}')
        if [[ -n "$id" ]]; then
            connected_ids+=("$id")
            connected_labels+=("$name (connector $id)")
        fi
    done

    if [[ ${#connected_ids[@]} -eq 0 ]]; then
        red "Could not resolve connector IDs via modetest. Manual input required."
        read -rp "Connector ID (numeric): " CONNECTOR_ID
        [[ "$CONNECTOR_ID" =~ ^[0-9]+$ ]] || { red "Invalid connector ID."; exit 1; }
        return
    fi

    if [[ ${#connected_ids[@]} -eq 1 ]]; then
        CONNECTOR_ID="${connected_ids[0]}"
        green "Auto-selected: ${connected_labels[0]}"
        return
    fi

    echo "Multiple HDMI outputs connected:"
    local i
    for i in "${!connected_ids[@]}"; do
        printf "  %d) %s\n" $((i + 1)) "${connected_labels[i]}"
    done
    local choice
    while true; do
        read -rp "Pick [1-${#connected_ids[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#connected_ids[@]} )); then
            CONNECTOR_ID="${connected_ids[$((choice - 1))]}"
            green "Selected: ${connected_labels[$((choice - 1))]}"
            return
        fi
        red "Invalid choice."
    done
}

# -----------------------------------------------------------------------------
# Step 2b: Display PAR correction (for monitors with inaccurate EDID)
# -----------------------------------------------------------------------------
#
# Some monitors report wrong physical dimensions in EDID, causing kmssink to
# apply aspect-ratio correction and render to a smaller CRTC region (e.g.
# 1800x1080+60+0 instead of 1920x1080+0+0). On a physically-rotated monitor
# this shows as content cut at top and bottom.
#
# The fix is to set pixel-aspect-ratio on the pipeline output caps to a value
# that cancels the EDID correction kmssink applies. Empirically 16/15 works
# for many monitors regardless of their specific EDID.
detect_display_par() {
    header "Step 2b: Display aspect correction"

    local physical_size
    physical_size=$(modetest -M vc4 -c 2>/dev/null | awk -v id="$CONNECTOR_ID" '$1 == id && $3 == "connected" {print $5; exit}')

    if [[ -n "$physical_size" && "$physical_size" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        local w_mm="${BASH_REMATCH[1]}"
        local h_mm="${BASH_REMATCH[2]}"
        local aspect
        # Use awk for floating-point math (bash does integer only).
        aspect=$(awk -v w="$w_mm" -v h="$h_mm" 'BEGIN { printf "%.3f", w/h }')
        echo "Monitor reports physical size: ${w_mm}x${h_mm} mm (aspect $aspect)"
        local target="1.778"  # true 16:9
        local within
        within=$(awk -v a="$aspect" -v t="$target" 'BEGIN { print (a - t < 0.01 && t - a < 0.01) ? 1 : 0 }')
        if [[ "$within" == "1" ]]; then
            DISPLAY_PAR="1/1"
            green "EDID looks accurate — using DISPLAY_PAR=1/1"
        else
            DISPLAY_PAR="16/15"
            yellow "EDID aspect $aspect differs from true 16:9 ($target) — using DISPLAY_PAR=16/15 to prevent letterboxing"
        fi
    else
        # No physical size reported — safest default
        DISPLAY_PAR="16/15"
        yellow "Cannot read EDID physical size — defaulting DISPLAY_PAR=16/15"
    fi
}

# -----------------------------------------------------------------------------
# Step 3: Rotation calibration
# -----------------------------------------------------------------------------
calibrate_rotation() {
    header "Step 3: Rotation calibration"

    echo "A SMPTE color-bar test pattern will be shown on the monitor."
    echo "For each rotation option, answer whether the pattern looks correct."
    echo
    echo "Quickest check — look for the ANIMATED gray NOISE block (like an"
    echo "old TV with no signal). It must be in the BOTTOM-RIGHT corner of"
    echo "your physical screen. If it is anywhere else, the rotation is wrong."
    echo
    echo "Full reference — a correctly-oriented SMPTE pattern has three bands:"
    echo "  - TOP    (~2/3): 7 tall color bars (white, yellow, cyan, green,"
    echo "                   magenta, red, blue) running top to bottom"
    echo "  - MIDDLE (thin): 7 shorter reversed bars"
    echo "  - BOTTOM (~1/4): mixed strip with the animated noise block on the right"
    echo

    stop_service_if_running

    local options=("counterclockwise" "clockwise" "rotate-180" "none")
    local opt
    for opt in "${options[@]}"; do
        echo "Trying rotation: $opt"

        local pipeline=(
            gst-launch-1.0
            videotestsrc pattern=smpte
            "!" "video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1"
            "!" videoflip "method=$opt"
            "!" videoscale "add-borders=false"
            "!" "video/x-raw,width=1920,height=1080,pixel-aspect-ratio=1/1"
            "!" videoconvert
            "!" kmssink "sync=false" "connector-id=$CONNECTOR_ID"
        )

        if ! launch_gst_bg "${pipeline[@]}"; then
            red "Could not display test pattern with method=$opt. Skipping."
            continue
        fi

        local answer
        read -rp "Does the test pattern look correct? [y/N/q=quit] " answer
        cleanup_gst

        case "$answer" in
            y|Y)
                ROTATION="$opt"
                green "Rotation set to: $ROTATION"
                return
                ;;
            q|Q)
                red "Calibration aborted."
                exit 1
                ;;
            *)
                ;;
        esac
    done

    red "None of the rotation options produced a correct image."
    read -rp "Enter rotation manually (clockwise/counterclockwise/rotate-180/none): " ROTATION
    case "$ROTATION" in
        clockwise|counterclockwise|rotate-180|none) ;;
        *) red "Invalid rotation."; exit 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Step 4: Source preset selection
# -----------------------------------------------------------------------------
show_iphone_diagram() {
    cat <<'DIAGRAM'

  ◄────────────── 1920px ──────────────►
            ┌────────────────┐            ▲
  ┌─────────┤────────────────┤─────────┐  │
  │░░░░░░░░░│                │░░░░░░░░░│  │
  │░░░░░░░░░│                │░░░░░░░░░│  │
  │░░░░░░░░░│                │░░░░░░░░░│
  │░░░░░░░░░│                │░░░░░░░░░│  1
  │░░░░░░░░░│                │░░░░░░░░░│  0
  │░ BLACK ░│    iPhone      │░ BLACK ░│  8
  │░ 656px ░│  content 608px │░ 656px ░│  0
  │░░░░░░░░░│                │░░░░░░░░░│  p
  │░░░░░░░░░│                │░░░░░░░░░│  x
  │░░░░░░░░░│                │░░░░░░░░░│
  │░░░░░░░░░│                │░░░░░░░░░│  │
  │░░░░░░░░░│                │░░░░░░░░░│  │
  └─────────┤────────────────┤─────────┘  │
            └────────────────┘            ▼
                   │  │
            ▲    ──┴──┴──    ▲
            └───── crop ─────┘

DIAGRAM
}

show_fullframe_diagram() {
    cat <<'DIAGRAM'

  ◄──── 1920px ────►
  ┌────────────────┐
  ├────────────────┤  ▲
  │░░            ░░│  │
  │░░            ░░│  │
  │░░            ░░│
  │░░            ░░│  1
  │░░            ░░│  0
  │░░    Full    ░░│  8
  │░░   Frame    ░░│  0
  │░░            ░░│  p
  │░░            ░░│  x
  │░░            ░░│
  │░░            ░░│  │
  │░░            ░░│  │
  ├────────────────┤  ▼
  └────────────────┘
         │  │
  ▲    ──┴──┴──    ▲
  └─── no crop ────┘

DIAGRAM
}

show_custom_diagram() {
    cat <<'DIAGRAM'

    ◄────────────── 1920px ──────────────►
              ┌────────────────┐            ▲
    ┌─────────┤────────────────┤─────────┐  │
    │░░░░░░░░░│░░░░░░░░░░░░░░░░│░░░░░░░░░│  │
    │░░░░░░░░░│░░░░░░░░░░░░░░░░│░░░░░░░░░│  │
┌►  │░░░░░░░░░│                │░░░░░░░░░│
│   │░░░░░░░░░│                │░░░░░░░░░│  1
c   │░░░░░░░░░│                │░░░░░░░░░│  0
r   │░░░░░░░░░│     Custom     │░░░░░░░░░│  8
o   │░░░░░░░░░│      Crop      │░░░░░░░░░│  0
p   │░░░░░░░░░│                │░░░░░░░░░│  p
│   │░░░░░░░░░│                │░░░░░░░░░│  x
└►  │░░░░░░░░░│                │░░░░░░░░░│
    │░░░░░░░░░│░░░░░░░░░░░░░░░░│░░░░░░░░░│  │
    │░░░░░░░░░│░░░░░░░░░░░░░░░░│░░░░░░░░░│  │
    └─────────┤────────────────┤─────────┘  │
              └────────────────┘            ▼
                     │  │
              ▲    ──┴──┴──    ▲
              └───── crop ─────┘

DIAGRAM
}

select_source_preset() {
    header "Step 4: Source preset (letterbox crop)"

    echo "iPhones send portrait content letterboxed inside a 1920x1080 landscape"
    echo "frame. The crop values remove the black bars so the content fills the"
    echo "monitor. For a standard 9:16 aspect ratio, each side bar is 656px."
    echo
    echo "Select your source:"
    echo "  1) iPhone 15 Pro Max or later (USB-C) — crop 656px sides  [default]"
    echo "  2) Full-frame source (no letterbox, no crop)"
    echo "  3) Custom crop values"
    echo

    local choice
    read -rp "Choice [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            CROP_LEFT=656
            CROP_RIGHT=656
            CROP_TOP=0
            CROP_BOTTOM=0
            show_iphone_diagram
            green "iPhone preset — crop 656px on each side."
            ;;
        2)
            CROP_LEFT=0
            CROP_RIGHT=0
            CROP_TOP=0
            CROP_BOTTOM=0
            show_fullframe_diagram
            green "No crop — full frame."
            ;;
        3)
            show_custom_diagram
            echo
            echo "Enter pixels to remove from each edge of the 1920x1080 source."
            echo "Reference: iPhone 9:16 letterbox = 656 left + 656 right."
            echo "Press Enter to keep the default (shown in brackets)."
            echo
            read -rp "  CROP_LEFT   [656]: " CROP_LEFT;   CROP_LEFT="${CROP_LEFT:-656}"
            read -rp "  CROP_RIGHT  [656]: " CROP_RIGHT;  CROP_RIGHT="${CROP_RIGHT:-656}"
            read -rp "  CROP_TOP    [0]:   " CROP_TOP;    CROP_TOP="${CROP_TOP:-0}"
            read -rp "  CROP_BOTTOM [0]:   " CROP_BOTTOM; CROP_BOTTOM="${CROP_BOTTOM:-0}"
            for v in "$CROP_LEFT" "$CROP_RIGHT" "$CROP_TOP" "$CROP_BOTTOM"; do
                [[ "$v" =~ ^[0-9]+$ ]] || { red "Values must be non-negative integers."; exit 1; }
            done
            if (( CROP_LEFT + CROP_RIGHT >= 1920 )); then
                red "CROP_LEFT + CROP_RIGHT must be < 1920."; exit 1
            fi
            if (( CROP_TOP + CROP_BOTTOM >= 1080 )); then
                red "CROP_TOP + CROP_BOTTOM must be < 1080."; exit 1
            fi
            local content_w=$((1920 - CROP_LEFT - CROP_RIGHT))
            local content_h=$((1080 - CROP_TOP - CROP_BOTTOM))
            green "Custom crop: L=$CROP_LEFT R=$CROP_RIGHT T=$CROP_TOP B=$CROP_BOTTOM → ${content_w}x${content_h} content"
            ;;
        *)
            red "Invalid choice."
            exit 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Step 5: Write config
# -----------------------------------------------------------------------------
write_config() {
    header "Step 5: Writing config"

    mkdir -p "$CONFIG_DIR"

    if [[ -f "$CONFIG_FILE" ]]; then
        local backup
        backup="$CONFIG_FILE.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$CONFIG_FILE" "$backup"
        yellow "Existing config backed up to $backup"
    fi

    cat > "$CONFIG_FILE" <<EOF
# rpi-hdmi-rotator configuration
# Generated by setup.sh v$VERSION on $(date -Iseconds)

DEVICE="$DEVICE"
INPUT_ENCODING="$INPUT_ENCODING"
INPUT_FORMAT="$INPUT_FORMAT"
INPUT_WIDTH=$INPUT_WIDTH
INPUT_HEIGHT=$INPUT_HEIGHT
FRAMERATE=$FRAMERATE

CROP_LEFT=$CROP_LEFT
CROP_RIGHT=$CROP_RIGHT
CROP_TOP=$CROP_TOP
CROP_BOTTOM=$CROP_BOTTOM

ROTATION="$ROTATION"

CONNECTOR_ID=$CONNECTOR_ID
OUTPUT_WIDTH=1920
OUTPUT_HEIGHT=1080
DISPLAY_PAR="$DISPLAY_PAR"

DEVICE_WAIT_SECONDS=3
EOF
    chmod 0644 "$CONFIG_FILE"
    green "Config written to $CONFIG_FILE"
}

# -----------------------------------------------------------------------------
# Step 6: Test run
# -----------------------------------------------------------------------------
test_run() {
    header "Step 6: Live test"

    echo "Running the final pipeline for 10 seconds..."

    local pipeline=(
        gst-launch-1.0
        v4l2src "device=$DEVICE" "io-mode=mmap"
    )
    if [[ "$INPUT_ENCODING" == "mjpeg" ]]; then
        pipeline+=(
            "!" "image/jpeg,width=$INPUT_WIDTH,height=$INPUT_HEIGHT,framerate=$FRAMERATE/1"
            "!" jpegdec
        )
    else
        pipeline+=(
            "!" "video/x-raw,format=$INPUT_FORMAT,width=$INPUT_WIDTH,height=$INPUT_HEIGHT,framerate=$FRAMERATE/1"
        )
    fi
    if (( CROP_LEFT > 0 || CROP_RIGHT > 0 || CROP_TOP > 0 || CROP_BOTTOM > 0 )); then
        pipeline+=(
            "!" videocrop
            "left=$CROP_LEFT" "right=$CROP_RIGHT"
            "top=$CROP_TOP" "bottom=$CROP_BOTTOM"
        )
    fi
    if [[ "$ROTATION" != "none" ]]; then
        pipeline+=( "!" videoflip "method=$ROTATION" )
    fi
    pipeline+=(
        "!" videoscale "add-borders=false"
        "!" "video/x-raw,width=1920,height=1080,pixel-aspect-ratio=1/1"
        "!" videoconvert
        "!" kmssink "sync=false" "connector-id=$CONNECTOR_ID"
    )

    if ! launch_gst_bg "${pipeline[@]}"; then
        red "Live test failed. Review /tmp/rotator-setup.log for details."
        return 1
    fi

    sleep 10
    cleanup_gst

    local answer
    read -rp "Did the live feed look correct? [y/N] " answer
    case "$answer" in
        y|Y) green "Live test confirmed OK."; return 0 ;;
    esac

    # Test failed — offer targeted recovery instead of starting over.
    echo
    echo "What looks wrong?"
    echo "  1) Rotation is off (image sideways or upside-down)"
    echo "  2) Crop is off (too much cut or black bars visible)"
    echo "  3) Something else — re-run the full wizard"
    echo "  4) Give up — restore previous config"
    echo
    read -rp "Choice [3]: " answer
    answer="${answer:-3}"

    case "$answer" in
        1)
            calibrate_rotation
            write_config
            test_run
            ;;
        2)
            select_source_preset
            write_config
            test_run
            ;;
        3)
            return 1
            ;;
        4)
            # Restore the backup made in write_config.
            local latest_bak
            latest_bak=$(find "$CONFIG_DIR" -name "rotator.conf.bak.*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
            if [[ -n "$latest_bak" ]]; then
                cp "$latest_bak" "$CONFIG_FILE"
                green "Previous config restored from $latest_bak"
            else
                yellow "No backup found to restore."
            fi
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Step 7: Finalize
# -----------------------------------------------------------------------------
finalize() {
    header "Step 7: Service"

    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true

    local answer
    if [[ "${SERVICE_WAS_RUNNING:-0}" -eq 1 ]]; then
        read -rp "Restart $SERVICE_NAME now? [Y/n] " answer
    else
        read -rp "Start $SERVICE_NAME now? [Y/n] " answer
    fi
    case "$answer" in
        n|N) yellow "Service not started. Run: sudo systemctl start $SERVICE_NAME" ;;
        *)
            systemctl restart "$SERVICE_NAME"
            sleep 1
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                green "Service is running."
            else
                red "Service failed to start. Check: journalctl -u $SERVICE_NAME -n 20"
            fi
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Main flow
# -----------------------------------------------------------------------------
main() {
    header "rpi-hdmi-rotator setup wizard v$VERSION"
    echo "This wizard will detect hardware, calibrate rotation, and write $CONFIG_FILE."
    echo

    detect_capture_device
    detect_input_format
    detect_connector
    detect_display_par
    calibrate_rotation
    select_source_preset
    write_config
    if ! test_run; then
        local retry
        read -rp "Re-run the full wizard from the start? [y/N] " retry
        case "$retry" in
            y|Y) main; return ;;
            *)   yellow "Config left as-is. Edit manually or re-run $0." ;;
        esac
    fi
    finalize

    header "Done"
    green "Setup complete. Diagnose anytime with:"
    echo "  /opt/rpi-hdmi-rotator/bin/diagnose.sh"
}

main
