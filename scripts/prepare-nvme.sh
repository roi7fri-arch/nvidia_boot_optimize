#!/bin/bash
#
# prepare-nvme.sh — Prepare a blank NVMe drive for Jetson Orin Nano fast boot
#
# Usage:
#   1. Power off the Jetson
#   2. Remove NVMe from the Jetson
#   3. Insert NVMe into M.2 USB adapter and connect to host PC
#   4. Run: sudo ./prepare-nvme.sh /dev/sdX
#   5. Remove NVMe from adapter and reinstall in Jetson
#
# This script will:
#   - Wipe the NVMe and create a single GPT partition (ext4, label "APP")
#   - Extract the Buildroot rootfs
#   - Install the optimized kernel Image and DTB
#   - Create extlinux.conf with fast-boot kernel cmdline
#   - Create startup.nsh (UEFI Shell fallback)
#   - Fix init script permissions for fast boot
#   - Install reboot-to-recovery utility
#
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
# All paths relative to the workspace root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"  # Go up from scripts/ to workspace parent

# Adjust these if your directory layout differs
BUILDROOT_DIR="${BASE_DIR}/buildroot-2026.02"
LINUX_CUSTOM="${BUILDROOT_DIR}/output/build/linux-custom"
L4T_DIR="${BASE_DIR}/Linux_for_Tegra"

ROOTFS_TAR="${BUILDROOT_DIR}/output/images/rootfs.tar"
KERNEL_IMAGE="${LINUX_CUSTOM}/arch/arm64/boot/Image"
DTB_FILE="${L4T_DIR}/kernel/dtb/tegra234-p3768-0000+p3767-0005-nv.dtb"

# ─── Argument Parsing ─────────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Usage: sudo $0 /dev/sdX"
    echo ""
    echo "  /dev/sdX — The NVMe device connected via M.2 USB adapter"
    echo ""
    echo "WARNING: This will ERASE ALL DATA on the target device!"
    exit 1
fi

DEVICE="$1"
PARTITION="${DEVICE}1"

# Handle NVMe naming (nvme0n1 → nvme0n1p1)
if [[ "$DEVICE" == *nvme* ]]; then
    PARTITION="${DEVICE}p1"
fi

# ─── Safety Checks ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)"
    exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
    echo "ERROR: $DEVICE is not a block device"
    exit 1
fi

# Verify it's not a system disk
ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$ROOT_DEV" == "$DEVICE"* ]]; then
    echo "ERROR: $DEVICE appears to be your system disk! Aborting."
    exit 1
fi

# Verify source files exist
for f in "$ROOTFS_TAR" "$KERNEL_IMAGE" "$DTB_FILE"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Required file not found: $f"
        exit 1
    fi
done

# ─── Confirmation ────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        Jetson Orin Nano — NVMe Preparation Script           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Target device: $DEVICE"
echo "║  Rootfs:        $ROOTFS_TAR"
echo "║  Kernel:        $KERNEL_IMAGE"
echo "║  DTB:           $DTB_FILE"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  WARNING: ALL DATA ON $DEVICE WILL BE DESTROYED!  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
read -p "Type 'YES' to proceed: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Aborted."
    exit 0
fi

# ─── Step 1: Unmount & Wipe ──────────────────────────────────────────────────
echo ""
echo ">>> Step 1/7: Unmounting and wiping $DEVICE..."
umount "${DEVICE}"* 2>/dev/null || true
sleep 1

# Wipe partition table
sgdisk --zap-all "$DEVICE"
sleep 1

# ─── Step 2: Create GPT Partition ────────────────────────────────────────────
echo ">>> Step 2/7: Creating GPT partition table..."
sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:"APP" "$DEVICE"
partprobe "$DEVICE"
sleep 2

# ─── Step 3: Format ext4 ────────────────────────────────────────────────────
echo ">>> Step 3/7: Formatting ${PARTITION} as ext4..."
mkfs.ext4 -L "APP" -O ^metadata_csum -F "$PARTITION"
sleep 1

# ─── Step 4: Mount & Extract rootfs ─────────────────────────────────────────
MOUNT_DIR=$(mktemp -d /tmp/jetson-nvme.XXXXXX)
echo ">>> Step 4/7: Mounting at $MOUNT_DIR and extracting rootfs..."
mount "$PARTITION" "$MOUNT_DIR"

tar -xf "$ROOTFS_TAR" -C "$MOUNT_DIR"
echo "    Rootfs extracted."

# ─── Step 5: Install kernel & DTB ───────────────────────────────────────────
echo ">>> Step 5/7: Installing kernel Image and DTB..."
mkdir -p "$MOUNT_DIR/boot/extlinux"

cp "$KERNEL_IMAGE" "$MOUNT_DIR/boot/Image"
cp "$DTB_FILE" "$MOUNT_DIR/boot/dtb"

# ─── Step 6: Create boot configs ────────────────────────────────────────────
echo ">>> Step 6/7: Creating boot configuration..."

# extlinux.conf
cat > "$MOUNT_DIR/boot/extlinux/extlinux.conf" << 'EXTLINUX'
TIMEOUT 30
DEFAULT primary

MENU TITLE L4T boot options

LABEL primary
      MENU LABEL primary kernel
      LINUX /boot/Image
      FDT /boot/dtb
      APPEND root=/dev/nvme0n1p1 rw rootwait rootfstype=ext4 console=ttyTCU0,115200 fbcon=map:0 net.ifnames=0 quiet loglevel=0
EXTLINUX

# startup.nsh (UEFI Shell fallback)
cat > "$MOUNT_DIR/startup.nsh" << 'NSH'
FS0:\L4TLauncher.efi
NSH

# ─── Step 7: Fast-boot userspace tweaks ──────────────────────────────────────
echo ">>> Step 7/7: Applying fast-boot userspace tweaks..."

# Fix rcS to skip non-executable scripts silently
if [[ -f "$MOUNT_DIR/etc/init.d/rcS" ]]; then
    sed -i '/\[ ! -f "\$i" \] && continue/a\     [ ! -x "$i" ] && continue' "$MOUNT_DIR/etc/init.d/rcS"
fi

# Disable unnecessary init scripts (keep only S01seedrng)
for script in S01syslogd S02klogd S02sysctl S11modules S40network S50crond; do
    if [[ -f "$MOUNT_DIR/etc/init.d/$script" ]]; then
        chmod -x "$MOUNT_DIR/etc/init.d/$script"
    fi
done

# Ensure S01seedrng is executable
if [[ -f "$MOUNT_DIR/etc/init.d/S01seedrng" ]]; then
    chmod +x "$MOUNT_DIR/etc/init.d/S01seedrng"
fi

# Create /var/lib/seedrng directory for seed storage
mkdir -p "$MOUNT_DIR/var/lib/seedrng"

# Add a debug marker to inittab (shows "Roi debug" on boot)
if [[ -f "$MOUNT_DIR/etc/inittab" ]]; then
    if ! grep -q "Roi debug" "$MOUNT_DIR/etc/inittab"; then
        sed -i '/::sysinit/i ::once:/bin/echo "Roi debug"' "$MOUNT_DIR/etc/inittab" 2>/dev/null || true
    fi
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
echo ""
echo ">>> Syncing and unmounting..."
sync
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    NVMe Preparation Complete!                ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Next steps:                                                 ║"
echo "║  1. Remove NVMe from M.2 USB adapter                        ║"
echo "║  2. Install NVMe back into the Jetson Orin Nano             ║"
echo "║  3. Flash QSPI (if not already done):                       ║"
echo "║     sudo ./flash-qspi.sh                                    ║"
echo "║  4. Power on — should boot to shell in ~4.7 seconds         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
