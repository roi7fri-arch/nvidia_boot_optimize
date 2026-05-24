# Quickstart: Fast Boot Orin Nano Optimization

**Feature**: 001-fast-boot-orin  
**Prerequisites**: 
- Host PC running Ubuntu (18.04+)
- NVIDIA Jetson Orin Nano DevKit connected via USB (for flash) and serial (/dev/ttyUSB0)
- Recovery jumper installed on the device
- Buildroot 2026.02 at `/media/roifr/482a837d-d424-44cd-9783-464d9403e86e/buildroot-2026.02/`
- NVIDIA L4T flash tools (Linux_for_Tegra directory)
- Cross-compiler: `aarch64-linux-gnu-gcc`

## Quick Start (5 steps)

### 1. Measure Baseline

```bash
# Power on the device and measure current boot time
./scripts/measure-boot-time.sh --device /dev/ttyUSB0 --verbose
```

### 2. Build Optimized Image

```bash
# Apply kernel optimization fragment and rebuild
./scripts/build-image.sh \
  --buildroot-dir /media/roifr/482a837d-d424-44cd-9783-464d9403e86e/buildroot-2026.02/ \
  --kernel-fragment config/kernel/fastboot-fragment.config
```

### 3. Flash to Device

The device should already be in recovery mode (jumper connected).

```bash
# Verify device is in APX/recovery mode
lsusb | grep -i nvidia

# Flash the optimized image
./scripts/flash-optimized.sh \
  --l4t-dir /path/to/Linux_for_Tegra \
  --image /media/roifr/482a837d-d424-44cd-9783-464d9403e86e/buildroot-2026.02/output/images/rootfs.ext4
```

### 4. Measure Optimized Boot Time

After flash completes, power cycle the device:

```bash
./scripts/measure-boot-time.sh --device /dev/ttyUSB0 --output measurements/run-001.json
```

### 5. Enter Recovery Mode (for re-flash without jumper)

Once the device boots to shell, you can re-enter recovery via software:

```bash
# On the device (via serial console):
sudo reboot --force forced-recovery
```

Then re-flash from the host without touching the jumper.

## Iterative Optimization Loop

```
1. Identify slowest boot stage (from measurement JSON)
2. Apply targeted optimization (kernel config / DT overlay / UEFI strip)
3. Rebuild: ./scripts/build-image.sh
4. Flash: ./scripts/flash-optimized.sh
5. Measure: ./scripts/measure-boot-time.sh
6. Compare: did boot time decrease?
7. If yes → commit config change. If no → revert.
8. Repeat until ≤8s achieved.
```

## Key Files

| File | Purpose |
|------|---------|
| `config/kernel/fastboot-fragment.config` | Kconfig options to disable GPU, audio, unused PCIe |
| `config/kernel/cmdline.txt` | Optimized kernel command line |
| `config/device-tree/overlays/` | DT overlays disabling unused hardware |
| `config/firmware/mb1-mb2-loglevel.dtsi` | Firmware log suppression |
| `config/bootloader/uefi-removals.txt` | UEFI components to strip |

## Serial Console Access

```bash
# Connect to device serial console from host
minicom -D /dev/ttyUSB0 -b 115200
# Or with screen:
screen /dev/ttyUSB0 115200
```
