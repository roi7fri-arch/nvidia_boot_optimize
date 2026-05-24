# CLI Contracts: Boot Optimization Scripts

**Feature**: 001-fast-boot-orin  
**Date**: 2026-05-14

All scripts follow the constitution's UX consistency principle:
- stdout: progress/results (timestamped)
- stderr: errors
- Exit 0 on success, non-zero on failure
- Common flags: `--device`, `--timeout`, `--verbose`

---

## measure-boot-time.sh

**Purpose**: Measure boot time by monitoring serial output from device.

```
Usage: measure-boot-time.sh [OPTIONS]

Options:
  --device SERIAL_PORT   Host serial port (default: /dev/ttyUSB0)
  --baud RATE            Baud rate (default: 115200)
  --timeout SECONDS      Max wait time before declaring failure (default: 30)
  --prompt STRING        String that indicates shell is ready (default: "/ #")
  --output FILE          Write measurement JSON to file (default: stdout)
  --verbose              Print all serial output to stderr
  --power-cycle          Trigger power cycle before measuring (requires relay/GPIO)

Output (JSON):
{
  "total_ms": 7832,
  "stages": {
    "firmware_start_ms": 0,
    "uefi_start_ms": 1200,
    "kernel_start_ms": 2100,
    "shell_ready_ms": 7832
  },
  "target_ms": 8000,
  "status": "PASS",
  "timestamp": "2026-05-14T10:30:00Z"
}

Exit codes:
  0 - Measurement completed, target met
  1 - Measurement completed, target NOT met
  2 - Timeout: device did not boot within --timeout
  3 - Serial port error
```

---

## flash-optimized.sh

**Purpose**: Flash the optimized buildroot image to the device. Expects device to be in recovery mode (jumper connected).

```
Usage: flash-optimized.sh [OPTIONS]

Options:
  --l4t-dir PATH         Path to Linux_for_Tegra directory (required)
  --image PATH           Path to rootfs image (default: buildroot output/images/rootfs.ext4)
  --kernel PATH          Path to kernel Image (default: buildroot output/images/Image)
  --dtb PATH             Path to device tree blob (default: auto-detect from buildroot)
  --device USB_PATH      USB device for APX mode (default: auto-detect via lsusb)
  --skip-rootfs          Flash only bootloader/kernel/DTB, skip rootfs
  --verbose              Show flash.sh output

Exit codes:
  0 - Flash completed successfully
  1 - Flash failed
  2 - Device not in recovery mode (APX not detected)
  3 - Required files missing
```

---

## build-image.sh

**Purpose**: Build the optimized image using Buildroot.

```
Usage: build-image.sh [OPTIONS]

Options:
  --buildroot-dir PATH   Path to buildroot tree (default: /media/roifr/482a837d-d424-44cd-9783-464d9403e86e/buildroot-2026.02/)
  --defconfig NAME       Buildroot defconfig to use (default: orin_nano_serial_defconfig)
  --kernel-fragment PATH Additional kernel config fragment to merge
  --jobs N               Parallel build jobs (default: $(nproc))
  --clean                Run make clean before building
  --verbose              Show full build output

Output:
  Prints paths to built artifacts:
  kernel: /path/to/output/images/Image
  rootfs: /path/to/output/images/rootfs.ext4
  dtb: /path/to/output/images/tegra234-*.dtb

Exit codes:
  0 - Build completed successfully
  1 - Build failed
  2 - Buildroot directory not found
  3 - Defconfig not found
```

---

## apply-kernel-config.sh

**Purpose**: Merge a Kconfig fragment into the existing kernel config and rebuild.

```
Usage: apply-kernel-config.sh [OPTIONS]

Options:
  --buildroot-dir PATH   Path to buildroot tree
  --fragment PATH        Kconfig fragment file to merge (required)
  --save-defconfig       Save result back to board defconfig
  --verbose              Show merge details

Exit codes:
  0 - Config merged and kernel rebuilt
  1 - Merge conflict (fragment conflicts with hard requirements)
  2 - Build failed after merge
```
