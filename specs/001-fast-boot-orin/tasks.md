# Tasks: Fast Boot to Serial Shell on NVIDIA Orin Nano

**Input**: Design documents from `/specs/001-fast-boot-orin/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Tests**: Integration tests included — boot time measurement is core to this feature.

**Organization**: Tasks follow the phased optimization order:
- Phase A (pre-Linux): firmware + UEFI → target 4–5s
- Phase B (Linux): kernel + userspace → target 3–4s

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

- **Repository root**: `scripts/`, `config/`, `tests/`
- **Buildroot tree**: `/media/roifr/482a837d-d424-44cd-9783-464d9403e86e/buildroot-2026.02/`
- **Buildroot config**: `configs/orin_nano_serial_defconfig`
- **Kernel config**: `board/nvidia/orin-nano/linux-orin-minimal.config`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization, measurement tooling, and baseline

- [X] T001 Create scripts/common.sh with shared constants (BUILDROOT_DIR, SERIAL_PORT=/dev/ttyUSB0, BAUD=115200, TARGET_BOOT_MS=8000)
- [X] T002 Create scripts/measure-boot-time.sh that monitors /dev/ttyUSB0 for shell prompt and outputs JSON timing
- [X] T003 [P] Create tests/test_boot_time.sh integration test wrapper around measure-boot-time.sh
- [X] T004 Measure and record baseline boot time with current image via scripts/measure-boot-time.sh (document in specs/001-fast-boot-orin/measurements/baseline.json)

**Checkpoint**: Measurement infrastructure ready. Baseline recorded. Every subsequent change can be quantified.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Flash tooling and build scripts that ALL optimization phases depend on

**⚠️ CRITICAL**: No optimization work can begin until these are complete

- [X] T005 Create scripts/flash-optimized.sh that wraps L4T flash.sh for flashing QSPI/bootloader (device already in recovery mode with jumper)
- [X] T006 Create scripts/build-image.sh that invokes buildroot make with orin_nano_serial_defconfig and optional kernel fragment merge
- [X] T007 [P] Create scripts/write-nvme.sh that writes rootfs.ext4 to NVMe SSD via M.2 adapter on host (prompts user for NVMe insertion)

**Checkpoint**: Can build, flash, and write NVMe. Ready for optimization iterations.

---

## Phase 3: User Story 1 — Pre-Linux Boot ≤4-5s (Priority: P1) 🎯 Phase A

**Goal**: Reduce firmware + UEFI + kernel-handoff time to 4–5 seconds from power-on.

**Independent Test**: Monitor /dev/ttyUSB0 — measure time from power-on to first kernel message (or UEFI→kernel handoff log).

### Firmware Optimization (MB1/MB2)

- [X] T008 [US1] Create config/firmware/mb1-mb2-loglevel.dtsi setting log_level=0 in tegra234-mb1-bct-misc-common.dtsi
- [X] T009 [US1] Document how to apply mb1-mb2-loglevel.dtsi to L4T flash layout in scripts/flash-optimized.sh

### UEFI Bootloader Optimization

- [X] T010 [US1] Create config/bootloader/uefi-removals.txt listing all UEFI components to strip (NetworkPkg/*, SCSI/SATA, Logo, EQOS, Realtek, UEFI Shell)
- [X] T011 [US1] Create config/bootloader/timeout-patch.cfg setting PcdPlatformBootTimeOut to 0
- [X] T012 [US1] Write script or documentation in scripts/flash-optimized.sh for applying UEFI removals to L4T UEFI build (patch NVIDIA.common.dsc.inc, NVIDIA.fvmain.fdf.inc, Jetson.fdf, Jetson.dsc.inc)
- [X] T013 [US1] Create config/device-tree/bpmp-serial-strip.dts — decompile tegra234-bpmp-3767-0000-a02-3509-a02.dtb, empty /serial node, recompile

### UEFI Build & Flash

- [X] T014 [US1] Build stripped UEFI firmware using L4T UEFI source with removals applied
- [X] T015 [US1] Flash optimized UEFI + firmware to device via scripts/flash-optimized.sh (board in recovery mode with jumper connected)
- [X] T016 [US1] Measure pre-Linux boot time: power-on to first kernel message on /dev/ttyUSB0 — target ≤4-5s (achieved: 4.1-5.3s cold, 4.1s warm)

**Checkpoint**: Pre-Linux stages validated at 4–5 seconds. UEFI ~2s proven. Ready for Phase B.

---

## Phase 4: User Story 2 — Strip Unnecessary Subsystems (Priority: P1) 🎯 Phase B Kernel

**Goal**: Disable GPU, audio, camera, unused PCIe, WiFi/BT in kernel and device tree so kernel boots in ≤2.5s.

**Independent Test**: After boot, `lsmod` shows no GPU/audio/camera modules; `cat /proc/device-tree/...` shows disabled nodes.

### Kernel Config Fragment

- [ ] T017 [P] [US2] Create config/kernel/fastboot-fragment.config disabling CONFIG_DRM, CONFIG_SND, CONFIG_WLAN, CONFIG_BT, CONFIG_VIDEO_DEV, CONFIG_FTRACE, CONFIG_KMEMLEAK, CONFIG_DEBUG_INFO
- [ ] T018 [P] [US2] Add to fastboot-fragment.config: modularize CONFIG_FUSE_FS, CONFIG_VFAT_FS, CONFIG_NTFS_FS, CONFIG_USB_HID, CONFIG_USB_NET
- [ ] T019 [US2] Apply fastboot-fragment.config via scripts/apply-kernel-config.sh to buildroot kernel config and rebuild

### Device Tree Overlay

- [ ] T020 [P] [US2] Create config/device-tree/overlays/disable-gpu-display.dts — disable display controller, HDMI, DP nodes (status = "disabled")
- [ ] T021 [P] [US2] Create config/device-tree/overlays/disable-audio.dts — disable AHUB, I2S, audio codec nodes
- [ ] T022 [P] [US2] Create config/device-tree/overlays/disable-pcie-non-nvme.dts — disable all PCIe controllers except the one for NVMe
- [ ] T023 [P] [US2] Create config/device-tree/overlays/disable-camera.dts — disable VI, ISP, CSI nodes
- [ ] T024 [P] [US2] Create config/device-tree/overlays/disable-wifi-bt.dts — disable WiFi/BT nodes (PCIe or SDIO)
- [ ] T025 [US2] Integrate DT overlays into buildroot build (add to BR2_LINUX_KERNEL_DTS_SUPPORT or apply as post-build step)

### Kernel Command Line

- [ ] T026 [US2] Create config/kernel/cmdline.txt with optimized boot parameters (quiet loglevel=0 rootwait ro raid=noautodetect noresume nohibernate audit=0)
- [ ] T027 [US2] Apply cmdline.txt to extlinux.conf or UEFI boot config for NVMe root boot

### Build & Measure

- [ ] T028 [US2] Rebuild image via scripts/build-image.sh with kernel fragment and DT overlays
- [ ] T029 [US2] Flash kernel+DTB to device or update NVMe (user: please insert NVMe SSD in M.2 adapter)
- [ ] T030 [US2] Measure full boot time — target: kernel stage ≤2.5s, total ≤8s
- [ ] T031 [US2] Create tests/test_services.sh — verify no GPU/audio/camera modules loaded after boot

**Checkpoint**: Kernel boots without unnecessary subsystems. Total kernel time ≤2.5s verified.

---

## Phase 5: User Story 1 — Userspace to Shell Optimization (Priority: P1) 🎯 Phase B Init

**Goal**: Optimize BusyBox init to reach shell prompt in ≤1.0s after kernel exec's init.

**Independent Test**: Measure delta between "init started" kernel message and shell prompt on serial.

- [ ] T032 [US1] Optimize overlay_fs/etc/inittab — remove swapon (not needed), minimize sysinit commands, move non-critical mounts to background
- [ ] T033 [US1] Optimize /etc/init.d/rcS in buildroot overlay — ensure network bringup is async (not blocking shell)
- [ ] T034 [US1] Rebuild rootfs via scripts/build-image.sh and update NVMe (user: insert NVMe SSD in M.2 adapter)
- [ ] T035 [US1] Measure final total boot time — target ≤8s power-on to shell on /dev/ttyUSB0
- [ ] T036 [US1] Run tests/test_boot_time.sh and confirm PASS (≤8000ms)

**Checkpoint**: Full boot path validated at ≤8 seconds. US1 acceptance scenario met.

---

## Phase 6: User Story 3 — Software Recovery Mode (Priority: P2)

**Goal**: Validate `sudo reboot --force forced-recovery` enters APX mode without jumper removal.

**Independent Test**: Issue command from serial shell, verify host detects APX device via lsusb.

- [ ] T037 [US3] Verify reboot forced-recovery support in current L4T/UEFI build (check PMC scratch register write)
- [ ] T038 [US3] Create tests/test_recovery_mode.sh — issue reboot command via serial, check lsusb on host for NVIDIA APX device
- [ ] T039 [US3] Test: from running shell, execute `sudo reboot --force forced-recovery` and confirm host detects APX (repeat 3x for reliability)

**Checkpoint**: Software recovery validated. No jumper manipulation needed for re-flash during development.

---

## Phase 7: User Story 4 — Reproducible Scripts (Priority: P2)

**Goal**: Package all optimizations into reproducible scripts that work on a fresh setup.

**Independent Test**: Clone repo on new host, point to L4T + buildroot, run scripts, achieve same boot time.

- [ ] T040 [P] [US4] Create README.md at repo root documenting prerequisites, setup, and usage
- [ ] T041 [P] [US4] Create tests/test_network.sh — verify Ethernet comes up within 3s of shell prompt
- [ ] T042 [US4] Ensure scripts/build-image.sh + scripts/flash-optimized.sh + scripts/write-nvme.sh work end-to-end from clean state
- [ ] T043 [US4] Document final measurements in specs/001-fast-boot-orin/measurements/final.json with before/after comparison
- [ ] T044 [US4] Record optimized buildroot defconfig back to config/buildroot/orin_nano_serial_defconfig for version control

**Checkpoint**: Complete reproducible workflow documented and tested. Any developer can replicate the optimization.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Final validation, documentation, cleanup

- [ ] T045 Run ShellCheck on all scripts in scripts/ and tests/ — fix any warnings
- [ ] T046 Verify flash capability preserved: flash device from recovery mode after all optimizations
- [ ] T047 Final full boot time measurement (5 consecutive power cycles, report average and variance)
- [ ] T048 Update specs/001-fast-boot-orin/plan.md with final achieved results

---

## Dependencies

```
T001 → T002 → T004 (baseline measurement)
T001 → T005, T006, T007 (infrastructure)
T005 → T015 (need flash script before flashing)
T006 → T019, T028 (need build script before building)
T008..T013 → T014 → T015 → T016 (Phase A: firmware/UEFI chain)
T016 PASS → T017..T027 (Phase B starts only after Phase A validated)
T017..T027 → T028 → T029 → T030 (Phase B kernel build & measure)
T030 PASS → T032..T036 (userspace optimization after kernel verified)
T036 PASS → T037..T039 (recovery mode after boot working)
T039 → T040..T044 (documentation after all features working)
T044 → T045..T048 (polish after everything complete)
```

## Parallel Execution Opportunities

**Within Phase 1**: T003 can run parallel to T002 (test wrapper structure)
**Within Phase 3**: T008+T010+T011+T013 can all be developed in parallel (different files)
**Within Phase 4**: T017+T018 parallel; T020+T021+T022+T023+T024 all parallel (separate DT overlays)
**Within Phase 7**: T040+T041 parallel

## Implementation Strategy

1. **MVP = Phase A complete (T001–T016)**: Pre-Linux boot validated at 4–5s. This proves the firmware/UEFI path works.
2. **Increment 2 = Phase B kernel (T017–T031)**: Stripped kernel boots fast. Total approaching 8s.
3. **Increment 3 = Phase B init (T032–T036)**: Userspace optimized. Full 8s target hit.
4. **Increment 4 = Recovery + polish (T037–T048)**: Robustness, documentation, reproducibility.
