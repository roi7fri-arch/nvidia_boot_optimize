#!/usr/bin/env bash
# flash-optimized.sh — Flash optimized image to Orin Nano DevKit
# Expects device to be in recovery mode (jumper connected).

. "$(dirname "$0")/common.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────

L4T_DIR=""
IMAGE="${BUILDROOT_IMAGES}/rootfs.ext4"
KERNEL="${BUILDROOT_IMAGES}/Image"
DTB=""
SKIP_ROOTFS=false
USE_MINIMAL_UEFI=true
VERBOSE=false

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Flash the optimized image to the Orin Nano DevKit.
Device must be in recovery/APX mode (jumper connected).

Options:
  --l4t-dir PATH         Path to Linux_for_Tegra directory (required)
  --image PATH           Path to rootfs image (default: buildroot output)
  --kernel PATH          Path to kernel Image (default: buildroot output)
  --dtb PATH             Path to device tree blob (default: auto-detect)
  --skip-rootfs          Flash only bootloader/kernel/DTB, skip rootfs
  --no-minimal-uefi      Use full uefi_jetson.bin instead of minimal
  --verbose              Show flash.sh output
  -h, --help             Show this help

Exit codes:
  0 - Flash completed successfully
  1 - Flash failed
  2 - Device not in recovery mode (APX not detected)
  3 - Required files missing
EOF
}

# ─── Parse Arguments ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --l4t-dir)     L4T_DIR="$2"; shift 2 ;;
        --image)       IMAGE="$2"; shift 2 ;;
        --kernel)      KERNEL="$2"; shift 2 ;;
        --dtb)         DTB="$2"; shift 2 ;;
        --skip-rootfs) SKIP_ROOTFS=true; shift ;;
        --no-minimal-uefi) USE_MINIMAL_UEFI=false; shift ;;
        --verbose)     VERBOSE=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) die "Unknown option: $1" "Run with --help for usage" ;;
    esac
done

# ─── Validation ──────────────────────────────────────────────────────────────

if [[ -z "$L4T_DIR" ]]; then
    die "--l4t-dir is required" "Provide path to Linux_for_Tegra directory"
fi

require_dir "$L4T_DIR" "Linux_for_Tegra directory"
require_file "${L4T_DIR}/flash.sh" "L4T flash.sh"

if [[ "$SKIP_ROOTFS" == false ]]; then
    require_file "$IMAGE" "rootfs image"
fi
require_file "$KERNEL" "kernel Image"

# Auto-detect DTB if not specified
if [[ -z "$DTB" ]]; then
    DTB=$(find "$BUILDROOT_IMAGES" -name "tegra234-p3768*.dtb" -print -quit 2>/dev/null)
    if [[ -z "$DTB" ]]; then
        DTB=$(find "$BUILDROOT_IMAGES" -name "tegra234*.dtb" -print -quit 2>/dev/null)
    fi
    if [[ -n "$DTB" ]]; then
        log_info "Auto-detected DTB: $DTB"
    fi
fi

# Check device is in recovery mode
log_info "Checking for device in recovery/APX mode..."
if ! lsusb 2>/dev/null | grep -qi "nvidia"; then
    die "No NVIDIA device detected in APX/recovery mode" \
        "Verify: jumper is connected, USB cable connected, device powered. Run: lsusb | grep -i nvidia"
fi
log_info "NVIDIA device detected in recovery mode."

# ─── Prepare Flash ───────────────────────────────────────────────────────────

log_info "Preparing flash..."

# Apply firmware optimizations: MB1/MB2 log suppression
MB1_BCT="${L4T_DIR}/bootloader/tegra234-mb1-bct-misc-common.dtsi"
if [[ -f "$MB1_BCT" ]]; then
    log_info "Applying MB1/MB2 log_level=0..."
    sed -i 's/log_level = <[0-9]*>/log_level = <0>/g' "$MB1_BCT"
fi

# Use minimal UEFI binary (pre-stripped by NVIDIA — no networking, SCSI, logo)
if [[ "$USE_MINIMAL_UEFI" == true ]]; then
    MINIMAL_UEFI="${L4T_DIR}/bootloader/uefi_jetson_minimal.bin"
    FULL_UEFI="${L4T_DIR}/bootloader/uefi_jetson.bin"
    if [[ -f "$MINIMAL_UEFI" ]]; then
        log_info "Switching to minimal UEFI (uefi_jetson_minimal.bin → uefi_jetson.bin)"
        cp "$FULL_UEFI" "${FULL_UEFI}.bak"
        cp "$MINIMAL_UEFI" "$FULL_UEFI"
    else
        log_warn "Minimal UEFI binary not found, using full UEFI"
    fi
fi

# Strip BPMP serial node (reduces combined UART init time)
BPMP_DTB="${L4T_DIR}/bootloader/generic/tegra234-bpmp-3767-0000-a02-3509-a02.dtb"
if [[ -f "$BPMP_DTB" ]]; then
    if command -v dtc &>/dev/null; then
        log_info "Stripping BPMP serial node..."
        BPMP_DTS="/tmp/bpmp-temp-$$.dts"
        BPMP_OUT="/tmp/bpmp-out-$$.dtb"
        if dtc -I dtb -O dts -o "$BPMP_DTS" "$BPMP_DTB" 2>/dev/null; then
            awk 'BEGIN{skip=0} /^\tserial \{/{skip=1} skip && /^\t};/{skip=0;next} !skip{print}' "$BPMP_DTS" > "${BPMP_DTS}.stripped"
            if dtc -I dts -O dtb -o "$BPMP_OUT" "${BPMP_DTS}.stripped" 2>/dev/null; then
                cp "$BPMP_OUT" "$BPMP_DTB"
                log_info "BPMP serial node stripped."
            fi
            rm -f "$BPMP_DTS" "${BPMP_DTS}.stripped" "$BPMP_OUT"
        fi
    else
        log_warn "dtc not found, skipping BPMP serial strip"
    fi
fi

# Copy kernel to L4T directory
cp "$KERNEL" "${L4T_DIR}/kernel/Image"
log_info "Kernel copied to ${L4T_DIR}/kernel/Image"

# Copy DTB if available
if [[ -n "$DTB" ]] && [[ -f "$DTB" ]]; then
    DTB_NAME=$(basename "$DTB")
    cp "$DTB" "${L4T_DIR}/kernel/dtb/${DTB_NAME}"
    log_info "DTB copied to ${L4T_DIR}/kernel/dtb/${DTB_NAME}"
fi

# Copy rootfs if not skipping
if [[ "$SKIP_ROOTFS" == false ]]; then
    log_info "Preparing rootfs for flash..."
    # L4T expects rootfs in rootfs/ directory
    if [[ "$IMAGE" == *.ext4 ]] || [[ "$IMAGE" == *.ext2 ]]; then
        log_info "Using ext4 image directly: $IMAGE"
    fi
fi

# ─── Flash ───────────────────────────────────────────────────────────────────

log_info "Starting flash (this may take several minutes)..."

FLASH_CMD=(sudo "${L4T_DIR}/flash.sh")

# Add board config for Orin Nano DevKit
FLASH_CMD+=(jetson-orin-nano-devkit)

# External storage (NVMe)
FLASH_CMD+=(external)

# Skip rootfs if requested (Phase A: bootloader/firmware only)
FLASH_ENV=()
if [[ "$SKIP_ROOTFS" == true ]]; then
    FLASH_ENV+=(NO_ROOTFS=1)
    log_info "Skipping rootfs (bootloader/firmware only)"
fi

if [[ "$VERBOSE" == true ]]; then
    sudo env "${FLASH_ENV[@]}" "${L4T_DIR}/flash.sh" jetson-orin-nano-devkit external 2>&1
else
    sudo env "${FLASH_ENV[@]}" "${L4T_DIR}/flash.sh" jetson-orin-nano-devkit external > /tmp/flash-output.log 2>&1
fi

FLASH_EXIT=$?

if [[ $FLASH_EXIT -ne 0 ]]; then
    log_error "Flash failed with exit code: $FLASH_EXIT"
    if [[ "$VERBOSE" == false ]]; then
        log_error "See log: /tmp/flash-output.log"
        tail -20 /tmp/flash-output.log >&2
    fi
    exit 1
fi

log_info "Flash completed successfully."
log_info "Device will reboot. Monitor serial on $SERIAL_PORT to verify boot."
exit 0
