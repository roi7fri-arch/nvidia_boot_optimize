#!/usr/bin/env bash
# write-nvme.sh — Write rootfs image to NVMe SSD via M.2 adapter on host
# Prompts user for physical NVMe insertion.

. "$(dirname "$0")/common.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────

IMAGE="${BUILDROOT_IMAGES}/rootfs.ext4"
NVME_DEV=""
PARTITION=1
VERBOSE=false

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Write rootfs image to NVMe SSD connected via M.2 adapter on host.

Options:
  --image PATH           Path to rootfs image (default: buildroot output/images/rootfs.ext4)
  --nvme-dev DEVICE      NVMe block device on host (e.g., /dev/nvme0n1). Auto-detected if omitted.
  --partition N          Partition number to write to (default: 1)
  --verbose              Show dd progress
  -h, --help             Show this help

Exit codes:
  0 - Write completed successfully
  1 - Write failed
  2 - NVMe device not found
  3 - Required files missing
EOF
}

# ─── Parse Arguments ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)     IMAGE="$2"; shift 2 ;;
        --nvme-dev)  NVME_DEV="$2"; shift 2 ;;
        --partition) PARTITION="$2"; shift 2 ;;
        --verbose)   VERBOSE=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "Unknown option: $1" "Run with --help for usage" ;;
    esac
done

# ─── Validation ──────────────────────────────────────────────────────────────

require_file "$IMAGE" "rootfs image"
require_cmd dd
require_cmd lsblk

# ─── Prompt for NVMe Insert ─────────────────────────────────────────────────

prompt_nvme_insert

# ─── Detect NVMe Device ──────────────────────────────────────────────────────

if [[ -z "$NVME_DEV" ]]; then
    log_info "Auto-detecting NVMe device..."
    # Look for NVMe devices (exclude the host's boot drive)
    NVME_DEVS=$(lsblk -dpno NAME,TRAN 2>/dev/null | grep "nvme" | awk '{print $1}')

    if [[ -z "$NVME_DEVS" ]]; then
        die "No NVMe device detected" "Check M.2 adapter connection and run: lsblk"
    fi

    # If multiple NVMe devices, list them and ask
    NVME_COUNT=$(echo "$NVME_DEVS" | wc -l)
    if [[ "$NVME_COUNT" -gt 1 ]]; then
        log_warn "Multiple NVMe devices found:"
        echo "$NVME_DEVS" | while read -r dev; do
            SIZE=$(lsblk -dpno SIZE "$dev" 2>/dev/null)
            printf "  %s (%s)\n" "$dev" "$SIZE"
        done
        die "Please specify --nvme-dev explicitly" "Choose from the list above"
    fi

    NVME_DEV="$NVME_DEVS"
    log_info "Detected NVMe device: $NVME_DEV"
fi

if [[ ! -b "$NVME_DEV" ]]; then
    die "NVMe device not found: $NVME_DEV" "Check connection and run: lsblk"
fi

# Show device info for confirmation
NVME_SIZE=$(lsblk -dpno SIZE "$NVME_DEV" 2>/dev/null)
log_info "Target device: $NVME_DEV ($NVME_SIZE)"

# ─── Safety Check ────────────────────────────────────────────────────────────

# Ensure we're not writing to the host root device
ROOT_DEV=$(findmnt -no SOURCE / 2>/dev/null | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
if [[ "$NVME_DEV" == "$ROOT_DEV" ]]; then
    die "ABORT: $NVME_DEV appears to be the host root device!" \
        "Disconnect host NVMe or specify correct --nvme-dev"
fi

log_warn "This will ERASE all data on ${NVME_DEV}p${PARTITION}!"
read -rp "Continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    log_info "Aborted by user."
    exit 0
fi

# ─── Partition & Write ───────────────────────────────────────────────────────

TARGET_PART="${NVME_DEV}p${PARTITION}"

# Unmount if mounted
if mountpoint -q "$TARGET_PART" 2>/dev/null || mount | grep -q "$TARGET_PART"; then
    log_info "Unmounting $TARGET_PART..."
    sudo umount "$TARGET_PART" 2>/dev/null || true
fi

# Write the image
log_info "Writing $IMAGE to $TARGET_PART..."
IMAGE_SIZE=$(stat -c%s "$IMAGE")
log_info "Image size: $(( IMAGE_SIZE / 1024 / 1024 )) MB"

if [[ "$VERBOSE" == true ]]; then
    sudo dd if="$IMAGE" of="$TARGET_PART" bs=4M status=progress conv=fsync
else
    sudo dd if="$IMAGE" of="$TARGET_PART" bs=4M conv=fsync 2>/dev/null
fi

DD_EXIT=$?
if [[ $DD_EXIT -ne 0 ]]; then
    die "dd failed with exit code: $DD_EXIT" "Check device permissions and disk space"
fi

sync
log_info "Write completed successfully."

# ─── Prompt to Return NVMe ───────────────────────────────────────────────────

prompt_nvme_return

log_info "NVMe SSD ready. Power on the device to test boot."
exit 0
