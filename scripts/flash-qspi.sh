#!/bin/bash
#
# flash-qspi.sh — Flash the complete QSPI firmware for Jetson Orin Nano fast boot
#
# Usage:
#   1. Put the Jetson into APX recovery mode:
#      - Option A (software): Run `reboot-to-recovery` on the Jetson, OR
#      - Option B (hardware): Power off, INSERT the recovery jumper (pins 9-10
#        on J14 button header, shorting FC_REC to GND), then power on.
#        After flash completes, power off and REMOVE the jumper.
#   2. Verify APX mode: lsusb | grep "0955:7523"
#   3. Run: sudo ./flash-qspi.sh
#
# This script will:
#   - Copy the optimized UEFI binary to L4T bootloader directory
#   - Copy DTB overlays (L4TConfiguration + disable-usb-net) to both kernel/dtb and bootloader
#   - Flash the entire QSPI (all firmware partitions)
#   - Cold-boot the device when done
#
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"  # Go up from scripts/ to workspace parent

# Adjust these if your directory layout differs
L4T_DIR="${BASE_DIR}/Linux_for_Tegra"
NVIDIA_UEFI_DIR="${BASE_DIR}/nvidia-uefi"

UEFI_BIN="${NVIDIA_UEFI_DIR}/images/uefi_t23x_midboot_RELEASE.bin"
L4T_CONFIG_DTBO="${L4T_DIR}/kernel/dtb/L4TConfiguration.dtbo"
DISABLE_USB_DTBO="${L4T_DIR}/kernel/dtb/disable-usb-net.dtbo"

# Flash target
BOARD="jetson-orin-nano-devkit-nvme"
ROOTDEV="nvme0n1p1"

# ─── Safety Checks ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)"
    exit 1
fi

# Verify source files exist
if [[ ! -f "$UEFI_BIN" ]]; then
    echo "ERROR: UEFI binary not found: $UEFI_BIN"
    echo "  Build it with:"
    echo "    cd $NVIDIA_UEFI_DIR"
    echo "    source venv/bin/activate"
    echo "    edk2-nvidia/Platform/NVIDIA/Tegra/build.sh --target RELEASE"
    exit 1
fi

if [[ ! -d "$L4T_DIR" ]]; then
    echo "ERROR: Linux_for_Tegra directory not found: $L4T_DIR"
    exit 1
fi

if [[ ! -f "$L4T_DIR/flash.sh" ]]; then
    echo "ERROR: flash.sh not found in $L4T_DIR"
    exit 1
fi

# Verify APX mode
if ! lsusb | grep -q "0955:7523"; then
    echo "ERROR: Jetson not detected in APX recovery mode!"
    echo ""
    echo "  To enter recovery mode:"
    echo "    Option A (software): Run 'reboot-to-recovery' on the Jetson"
    echo "    Option B (hardware): Power off, INSERT the recovery jumper"
    echo "      (pins 9-10 on J14, shorting FC_REC to GND), then power on."
    echo ""
    echo "  Verify with: lsusb | grep '0955:7523'"
    exit 1
fi

# ─── Display Plan ────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Jetson Orin Nano — QSPI Flash Script                 ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  UEFI binary:  $(basename "$UEFI_BIN")"
echo "║  Board:        $BOARD"
echo "║  Root device:  $ROOTDEV"
echo "║  L4T dir:      $L4T_DIR"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  This will flash the ENTIRE QSPI (all firmware partitions)   ║"
echo "║  Estimated time: ~5-8 minutes                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Kill stale flash processes ──────────────────────────────────────
echo ">>> Step 1/4: Cleaning up stale processes..."
killall -9 tegrarcm_v2 2>/dev/null || true
killall -9 tegradevflash_v2 2>/dev/null || true
sleep 2

# ─── Step 2: Stage files ─────────────────────────────────────────────────────
echo ">>> Step 2/4: Staging firmware files..."

# Copy UEFI binary
cp "$UEFI_BIN" "$L4T_DIR/bootloader/uefi_jetson.bin"
echo "    Copied UEFI binary → bootloader/uefi_jetson.bin"

# Copy DTB overlays to bootloader/ (flash.sh reads from there)
if [[ -f "$L4T_CONFIG_DTBO" ]]; then
    cp "$L4T_CONFIG_DTBO" "$L4T_DIR/bootloader/L4TConfiguration.dtbo"
    echo "    Copied L4TConfiguration.dtbo → bootloader/"
fi

if [[ -f "$DISABLE_USB_DTBO" ]]; then
    cp "$DISABLE_USB_DTBO" "$L4T_DIR/bootloader/disable-usb-net.dtbo"
    echo "    Copied disable-usb-net.dtbo → bootloader/"
fi

# Verify overlay config in p3767.conf.common
if ! grep -q "disable-usb-net.dtbo" "$L4T_DIR/p3767.conf.common" 2>/dev/null; then
    echo "    WARNING: disable-usb-net.dtbo not found in p3767.conf.common OVERLAY_DTB_FILE"
    echo "    You may need to add it manually."
fi

# Create minimal rootfs stubs (flash.sh expects these)
mkdir -p "$L4T_DIR/rootfs/lib" "$L4T_DIR/rootfs/etc/nv_boot_control" "$L4T_DIR/rootfs/opt/nvidia/l4t-packages"
touch "$L4T_DIR/rootfs/lib/libgpg-error.so.0"

# ─── Step 3: Flash QSPI ─────────────────────────────────────────────────────
echo ">>> Step 3/4: Flashing QSPI (this takes several minutes)..."
echo ""

cd "$L4T_DIR"
./flash.sh --qspi-only "$BOARD" "$ROOTDEV"

# ─── Step 4: Done ────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    QSPI Flash Complete!                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  The device should now cold-boot automatically.              ║"
echo "║                                                              ║"
echo "║  If you used the hardware jumper:                            ║"
echo "║    1. Power off the Jetson                                   ║"
echo "║    2. REMOVE the recovery jumper from J14 pins 9-10          ║"
echo "║    3. Power on                                               ║"
echo "║                                                              ║"
echo "║  Expected boot time: ~4.7 seconds (power-on → shell)        ║"
echo "║                                                              ║"
echo "║  NOTE: After a full QSPI reflash, the Boot0002 EFI          ║"
echo "║  variable is reset. On first boot, UEFI will fall through    ║"
echo "║  to Shell → startup.nsh → L4TLauncher (adds ~5s once).      ║"
echo "║  Subsequent boots use the recreated Boot0002 variable.       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
