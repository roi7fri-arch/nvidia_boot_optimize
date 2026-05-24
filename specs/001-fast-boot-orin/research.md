# Research: Fast Boot to Serial Shell on NVIDIA Orin Nano

**Feature**: 001-fast-boot-orin  
**Date**: 2026-05-14

## Current Boot State Analysis

### Existing Buildroot Setup (already working)

The user has a functional Buildroot-based image at `/media/roifr/482a837d-d424-44cd-9783-464d9403e86e/buildroot-2026.02/`:

- **Config**: `orin_nano_serial_defconfig`
- **Kernel**: NVIDIA L4T tegra-5.15.185, LZ4 compressed, custom minimal config (4894 lines)
- **Init**: BusyBox init (NOT systemd) — direct shell spawn on ttyTCU0
- **Rootfs**: CPIO archive (initramfs) — no disk mount needed for initial shell
- **DT**: In-tree `tegra234-p3768-0000+p3767-0005-nv`
- **Overlay**: Custom inittab with direct `/bin/sh` on ttyTCU0

### Reference Boot Log (ref.txt) Analysis

The reference boot log shows the firmware/UEFI sequence from power-on. Key observations:
- DCE firmware boots first (task init, SC7, RM)
- OP-TEE 4.2 initializes (security firmware)
- UEFI firmware v36.5.0 loads next
- Multiple StandaloneMM protocol installations (secure variable storage)
- QSPI and NOR flash operations occur
- FVB variable store validation
- Secure Boot variables checked (not set — test/insecure mode)

**Estimated firmware+UEFI time from reference**: The ref.txt log represents a successfully optimized build by a colleague who achieved ~2 seconds UEFI runtime (after firmware handoff). This is our proven target for the UEFI stage.

### Stock JetPack Baseline (from NVIDIA docs)

NVIDIA documents ~36s cold boot for stock JetPack on Orin Nano DevKit. Their optimizations reduce to ~16s. Our target (≤8s) requires going well beyond NVIDIA's documented optimizations.

## Boot Time Budget (Target: ≤8 seconds)

### Phase A: Pre-Linux (firmware + UEFI) — TARGET: 4–5 seconds

Focus here first. Get firmware through kernel handoff optimized before touching Linux.

| Stage | Target | Strategy | Reference |
|-------|--------|----------|----------|
| Firmware (MB1/MB2/TOS/DCE) | ≤2.0s | Disable logs, minimal init | — |
| UEFI Bootloader | ≤2.0s | Strip components, zero timeout, no PXE/SCSI/logo | Friend achieved ~2s with AI agent |
| UEFI → Kernel handoff | ≤1.0s | Kernel load from NVMe/QSPI, ExitBootServices | — |
| **Pre-Linux Total** | **4–5s** | | |

### Phase B: Linux (kernel + userspace) — TARGET: 3–4 seconds

After pre-Linux is validated at 4–5s, optimize kernel and userspace.

| Stage | Target | Strategy | Reference |
|-------|--------|----------|----------|
| Kernel init → init exec | ≤2.5s | Minimal config, LZ4, async probes, disable unused HW | — |
| Userspace → shell | ≤1.0s | BusyBox init already minimal; optimize mount sequence | — |
| **Linux Total** | **3–4s** | | |

### Combined Target: ≤8 seconds

> **Note**: A proven reference exists for UEFI optimization achieving ~2 seconds total UEFI time on the same platform (Orin Nano). This was accomplished by stripping networking, SCSI, logo, EQOS, Realtek drivers, and UEFI shell, plus setting timeout=0. The ref.txt serial log shows the UEFI firmware sequence from that optimized build.

### NVMe SSD Update Method

The NVMe SSD can be physically removed and mounted on the host PC via an **M.2 adapter**. The user will handle the physical swap. Scripts should:
- Prepare rootfs images that can be written directly to the NVMe via the M.2 adapter
- Clearly indicate when an NVMe update is needed (print a message and wait for confirmation)
- Support both: flash via recovery mode (QSPI/bootloader) and direct NVMe write (M.2 adapter)

## Research Findings by Boot Stage

### 1. Firmware / Pre-Bootloader (MB1, MB2, TOS/OP-TEE, DCE)

**Decision**: Disable MB1/MB2 log output; no other firmware changes needed.

**Rationale**: 
- MB1/MB2 logs add UART overhead. Setting `log_level` to 0 in `tegra234-mb1-bct-misc-common.dtsi` eliminates serial output delay.
- OP-TEE and DCE are required for platform security and display engine; cannot be removed but their logs can be suppressed.
- The reference shows this stage completing relatively quickly.

**Alternatives considered**:
- Custom MB1/MB2 firmware: Too risky, NVIDIA doesn't support this.
- Disable OP-TEE: Not possible — required for UEFI variable protection.

### 2. UEFI Bootloader

**Decision**: Strip all unnecessary UEFI components, set timeout=0, remove boot menu.

**Rationale** (from NVIDIA docs):
- Remove networking stacks (PXE boot not needed): saves ~0.5-1s
- Remove SCSI/SATA stack (NVMe is direct PCIe, not SCSI): saves probing time
- Remove logo/splash rendering: saves framebuffer init
- Remove UEFI shell: not needed in production
- Remove EQOS Ethernet driver from UEFI (Ethernet only needed in Linux)
- Remove Realtek PCIe Ethernet driver from UEFI
- Set boot timeout to 0: eliminates delay at boot menu

**Proven reference**: A colleague achieved ~2 seconds UEFI time using these exact optimizations (ref.txt shows the resulting boot log). This is a validated, achievable target.

**Alternatives considered**:
- Custom U-Boot instead of UEFI: The Orin Nano uses UEFI (not U-Boot) as the bootloader. Replacing it is not supported.
- Keep UEFI network for PXE: Not needed — boot is from NVMe.

### 3. Kernel Configuration

**Decision**: Further trim `linux-orin-minimal.config` with a Kconfig fragment targeting:

- **Disable GPU/Display**: `# CONFIG_DRM is not set`, disable nvgpu, display controller
- **Disable Audio**: `# CONFIG_SND is not set`, `# CONFIG_SND_SOC_TEGRA_ALT is not set`
- **Disable unused PCIe**: Keep only the PCIe controller connected to NVMe; disable others via DT
- **Disable USB controllers not needed for boot**: Modularize USB (load later if needed)
- **Disable WiFi/BT**: `# CONFIG_WLAN is not set`, `# CONFIG_BT is not set`
- **Disable cameras/ISP**: `# CONFIG_VIDEO_DEV is not set`
- **Async probes**: Enable `PROBE_PREFER_ASYNCHRONOUS` on remaining drivers
- **Modularize non-critical**: HID, QSPI (if not boot device), network drivers as modules
- **Disable debugging**: `# CONFIG_FTRACE is not set`, `# CONFIG_KMEMLEAK is not set`, `# CONFIG_DEBUG_INFO is not set`
- **Reduce console overhead**: Use `quiet` + `loglevel=0` on kernel command line (BUT keep serial console functional for shell — just suppress kernel messages)
- **Filesystem**: `CONFIG_FUSE_FS=m`, `CONFIG_VFAT_FS=m`, `CONFIG_NTFS_FS=m`

**Rationale**: The existing config is 4894 lines, already minimal, but likely still includes GPU (nvgpu is big), audio, and camera support for generic Jetson use.

**Alternatives considered**:
- Completely custom kernel from scratch: Too risky; NVIDIA's tegra BSP has many required platform drivers.
- Remove NVMe PCIe entirely and boot from initramfs only: Possible for even faster boot, but limits available storage.

### 4. Device Tree Optimization

**Decision**: Create DT overlay to disable unused hardware nodes.

**Key changes**:
- Disable all PCIe controllers except the one connected to NVMe SSD
- Disable display/HDMI/DP output nodes
- Disable audio codec / I2S / AHUB nodes
- Disable camera / VI / ISP nodes
- Disable WiFi/BT (if on PCIe or SDIO)
- Strip BPMP serial node contents (per NVIDIA docs — eliminates BPMP combined UART init)
- Keep: NVMe PCIe, Ethernet (EQOS or PCIe-based), serial UART (ttyTCU0), GPIO, I2C (if needed)

**Rationale**: Device tree node presence triggers driver probe even if driver is compiled as module. Disabling at DT level prevents any probe attempt.

**Alternatives considered**:
- Single monolithic DT modification: Harder to maintain than overlays.
- Kernel command line device disable: Less reliable than DT.

### 5. Kernel Command Line

**Decision**: Optimized cmdline for fastest boot:

```
root=/dev/nvme0n1p1 rootfstype=ext4 rootwait ro quiet loglevel=0 console=ttyTCU0,115200 init=/sbin/init raid=noautodetect noresume nohibernate systemd.unit=- audit=0 lpj=<calibrated_value> pci=noaer,nomsi,noats tsc=reliable
```

Key options:
- `quiet loglevel=0`: Suppress kernel messages (shell still works on ttyTCU0)
- `rootwait ro`: Wait for NVMe but mount read-only initially (faster)
- `raid=noautodetect`: Skip MD RAID scan
- `noresume nohibernate`: Skip swap/hibernate checks
- `audit=0`: Disable audit subsystem
- `lpj=<value>`: Skip loops-per-jiffy calibration (must measure once)
- `pci=noaer,nomsi,noats`: Disable PCIe advanced error reporting overhead

**Note**: Since buildroot currently produces a CPIO (initramfs), we may boot directly from initramfs and then pivot to NVMe. This is faster than waiting for NVMe probe before mounting root.

### 6. Userspace / Init

**Decision**: The BusyBox init is already near-optimal. Minor tweaks:

- Remove unnecessary mounts from inittab sysinit if not needed (swapon, /dev/shm if no tmpfs users)
- Ensure `/etc/init.d/rcS` does minimal work (no network bringup blocking shell)
- Consider moving network init to background (after shell is available)
- Ensure shell spawn happens before Ethernet DHCP/link-up completes

**Rationale**: Current inittab already spawns `/bin/sh` directly on ttyTCU0. The bottleneck is the `::sysinit:` commands that run before the shell respawn.

**Alternatives considered**:
- Custom init binary (C program): Marginal gain over BusyBox init for this use case.
- No initramfs, direct NVMe root: Requires NVMe to be probed before root mount — potentially slower than initramfs approach.

### 7. Boot Measurement Strategy

**Decision**: Use host-side serial monitoring on `/dev/ttyUSB0`.

**Method**:
- Python/bash script on host monitors serial output
- Timestamp first character received (firmware alive)
- Timestamp shell prompt or known string (boot complete)
- Delta = total boot time
- Also use kernel `printk_time` (if loglevel allows) for per-stage breakdown
- Device is already in recovery mode with jumper for flashing

### 8. Software Recovery Mode

**Decision**: Use `sudo reboot --force forced-recovery` (writes to PMC scratch register).

**Rationale**: L4T/Orin platform supports this natively. The PMIC scratch register `SCRATCH0` or `PMC_SCRATCH0` tells the bootloader to enter RCM/APX mode on next boot. No physical jumper manipulation needed during normal operation.

**Note**: The jumper is already connected for the initial flash. After first boot is working, recovery can be triggered via software command.

## Key Risks

| Risk | Mitigation |
|------|------------|
| 8s target infeasible with stock UEFI | Document best achieved; consider if NVIDIA provides faster UEFI build |
| NVMe probe time exceeds budget | Boot from initramfs first, mount NVMe async |
| Kernel changes break platform stability | Test each change incrementally; keep working config as fallback |
| UEFI modifications break flash capability | Keep recovery jumper as backup; test flash after each UEFI change |
| PCIe NVMe not found if other controllers disabled | Verify which PCIe controller NVMe is on before disabling others |

## Decisions Summary

| Topic | Decision | Rationale |
|-------|----------|-----------|
| Build system | Buildroot (existing) | Already working, minimal, no systemd overhead |
| Init system | BusyBox init | Already in place, ~0ms overhead vs systemd's seconds |
| Kernel compression | LZ4 (already set) | Fastest decompression for ARM64 |
| Root filesystem | initramfs (CPIO) + NVMe pivot | Fastest to first shell; NVMe for persistent storage |
| Bootloader | UEFI (stripped) | Only option for Orin Nano; strip all unnecessary components |
| Recovery method | Software reboot command | Avoids physical jumper; uses PMC scratch register |
| PCIe policy | NVMe only | Disable all other PCIe endpoints/controllers in DT |
| Network timing | Async after shell | Ethernet starts in background; don't block shell on DHCP |
