# Implementation Plan: Fast Boot to Serial Shell on NVIDIA Orin Nano

**Branch**: `001-fast-boot-orin` | **Date**: 2026-05-14 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-fast-boot-orin/spec.md`

## Summary

Reduce NVIDIA Jetson Orin Nano DevKit boot time to ≤8s power-on to interactive serial shell. The user already has a working Buildroot-based Linux image (no JetPack/systemd) built from `/media/roifr/482a837d-d424-44cd-9783-464d9403e86e/buildroot-2026.02/` using the `orin_nano_serial_defconfig` config. The userspace is already minimal (BusyBox init, direct shell on ttyTCU0, no GUI). Approach: multi-layer optimization across firmware (disable MB1/MB2 logs, strip UEFI components), bootloader (zero timeout, remove network/SCSI/logo/EQOS stacks, remove UEFI shell), kernel (further trim the existing `linux-orin-minimal.config` — disable GPU/audio/unused PCIe/USB controllers, async probes, LZ4 compression already set), device tree (disable unused controllers, keep only NVMe on PCIe, disable display/audio nodes, strip BPMP serial node), and rootfs (optimize BusyBox init sequence, eliminate unnecessary mounts). Linux rootfs on NVMe via initramfs pivot or direct boot. Serial console /dev/ttyTCU0 at 115200 baud. Recovery via `sudo reboot --force forced-recovery`. Board in recovery mode with jumper connected, host serial at /dev/ttyUSB0 for measurement.

## Technical Context

**Language/Version**: Bash (scripts), Kconfig (kernel), DTS (device tree), UEFI EDK2 (bootloader), Buildroot (build system)  
**Build System**: Buildroot 2026.02 at `/media/roifr/482a837d-d424-44cd-9783-464d9403e86e/buildroot-2026.02/`  
**Buildroot Config**: `orin_nano_serial_defconfig` (already exists)  
**Kernel Source**: NVIDIA L4T tegra-5.15.185 (custom tarball, LZ4 compressed Image)  
**Kernel Config**: `board/nvidia/orin-nano/linux-orin-minimal.config` (4894 lines, already trimmed)  
**Rootfs Overlay**: `overlay_fs/` with custom BusyBox inittab (direct shell on ttyTCU0)  
**Init System**: BusyBox init (NOT systemd) — already minimal  
**Primary Dependencies**: NVIDIA L4T flash tools (flash.sh), cross-compiler (aarch64-linux-gnu-gcc), dtc  
**Storage**: NVMe SSD (rootfs), QSPI (firmware/bootloader)  
**Testing**: Serial console timing (host /dev/ttyUSB0, target /dev/ttyTCU0 at 115200 baud)  
**Target Platform**: NVIDIA Jetson Orin Nano DevKit (ARM64, Tegra T234)  
**Project Type**: Embedded system configuration / boot optimization  
**Performance Goals**: ≤8 seconds power-on to shell prompt (Phase A: pre-Linux ≤4-5s, Phase B: Linux ≤3-4s)  
**Constraints**: Must preserve: Ethernet networking, serial console, NVMe root, flash capability, software-triggered recovery mode. Only NVMe needed on PCIe — no other PCIe devices.  
**NVMe Update**: User can remove NVMe SSD and mount on host via M.2 adapter for direct rootfs writes. Scripts must indicate when NVMe update is needed.  
**Optimization Order**: Pre-Linux stages first (firmware + UEFI → 4-5s), then Linux stages (kernel + userspace → 3-4s)  
**Scale/Scope**: Single board type (Orin Nano DevKit), single boot profile optimized for headless serial operation  
**Existing Image**: User has a working Buildroot image; optimizations are applied on top of it, not from scratch

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Code Quality | ✅ PASS | All scripts will follow ShellCheck, constants for paths, single-responsibility modules |
| II. Testing Standards | ✅ PASS | Boot time measurement script provides integration test; baseline measured before optimization |
| III. User Experience Consistency | ✅ PASS | Consistent CLI args (--device, --timeout, --verbose); error messages with corrective actions |
| IV. Performance Requirements | ✅ PASS | This IS the performance feature; baseline will be established first; every change measured |

**Gate Result**: PASS — proceeding to Phase 0.

## Project Structure

### Documentation (this feature)

```text
specs/001-fast-boot-orin/
├── plan.md              # This file
├── research.md          # Phase 0: optimization research findings
├── data-model.md        # Phase 1: boot stages and configuration entities
├── quickstart.md        # Phase 1: how to apply optimizations
├── contracts/           # Phase 1: CLI interface contracts
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
scripts/
├── measure-boot-time.sh     # Measures boot time via serial /dev/ttyUSB0
├── flash-optimized.sh       # Flashes optimized image to device (board in recovery w/ jumper)
├── build-image.sh           # Invokes buildroot make with orin_nano_serial_defconfig
├── apply-kernel-config.sh   # Applies kernel config changes and rebuilds
└── common.sh                # Shared constants and utility functions

config/
├── kernel/
│   ├── fastboot-fragment.config  # Kconfig fragment to apply on top of linux-orin-minimal.config
│   └── cmdline.txt               # Optimized kernel command line
├── bootloader/
│   ├── uefi-removals.txt     # List of UEFI components to strip
│   └── timeout-patch.cfg     # UEFI timeout = 0
├── device-tree/
│   ├── overlays/             # DT overlays to disable unused hardware (non-NVMe PCIe, display, audio)
│   └── bpmp-serial-strip.dts # BPMP DT with serial node emptied
├── buildroot/
│   └── orin_nano_serial_defconfig  # Updated defconfig (synced back from buildroot)
└── firmware/
    └── mb1-mb2-loglevel.dtsi # MB1/MB2 log_level = 0

tests/
├── test_boot_time.sh         # Integration: power-cycle and measure via /dev/ttyUSB0
├── test_services.sh          # Verify no GPU/audio processes running
├── test_recovery_mode.sh     # Verify software recovery works
└── test_network.sh           # Verify Ethernet comes up after boot
```

**Structure Decision**: Single-project layout with `scripts/` for host-side tooling, `config/` for all configuration artifacts organized by boot stage, and `tests/` for integration validation. The actual Buildroot tree lives externally at `/media/roifr/482a837d-d424-44cd-9783-464d9403e86e/buildroot-2026.02/` — this repo contains optimization configs and scripts that operate on it.

## Complexity Tracking

> No constitution violations — no complexity justification needed.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| [e.g., 4th project] | [current need] | [why 3 projects insufficient] |
| [e.g., Repository pattern] | [specific problem] | [why direct DB access insufficient] |
