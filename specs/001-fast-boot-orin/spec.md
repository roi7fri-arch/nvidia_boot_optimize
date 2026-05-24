# Feature Specification: Fast Boot to Serial Shell on NVIDIA Orin Nano

**Feature Branch**: `001-fast-boot-orin`  
**Created**: 2026-05-14  
**Status**: Draft  
**Input**: User description: "Reduce Linux boot time on NVIDIA Orin Nano DevKit to ≤8 seconds from power-on to interactive serial shell. No graphics or audio needed. Recovery mode via software reboot command preferred over physical jumper manipulation."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Power-On to Interactive Shell in ≤8 Seconds (Priority: P1)

As an embedded developer, I power on my NVIDIA Orin Nano DevKit and want an interactive shell available on the serial console within 8 seconds so I can begin working with minimal wait time.

**Why this priority**: This is the entire purpose of the feature — achieving the aggressive 8-second boot target is the primary deliverable.

**Independent Test**: Connect serial console (115200 baud), power cycle the device, measure time from power assertion to shell prompt accepting input.

**Acceptance Scenarios**:

1. **Given** the Orin Nano DevKit is powered off, **When** power is applied, **Then** an interactive shell prompt appears on the serial console within 8 seconds.
2. **Given** the device has booted to shell, **When** the user types a command, **Then** the command executes immediately without delay.
3. **Given** the device is running, **When** `sudo reboot --force forced-recovery` is issued, **Then** the device reboots into recovery mode without requiring physical jumper insertion.

---

### User Story 2 - Strip Unnecessary Subsystems (Priority: P1)

As an embedded developer, I want all graphics (GPU/display), audio, and other unnecessary subsystems disabled or removed from the boot process so that boot time is minimized and resources are freed.

**Why this priority**: Removing unneeded subsystems is the primary mechanism to reach the 8-second target. Graphics and audio drivers represent significant boot time overhead.

**Independent Test**: After optimization, verify that no display server, GPU driver stack, or audio subsystem loads during boot. Confirm via `systemctl list-units` and `lsmod` that none of these are active.

**Acceptance Scenarios**:

1. **Given** the optimized system, **When** boot completes, **Then** no display manager, X11, Wayland, or GPU userspace services are running.
2. **Given** the optimized system, **When** boot completes, **Then** no audio/sound services or kernel modules are loaded.
3. **Given** the optimized system, **When** boot completes, **Then** the serial console is the only interactive interface available.

---

### User Story 3 - Software-Triggered Recovery Mode (Priority: P2)

As an embedded developer, I want to enter recovery mode (APX/RCM) via a software command (`sudo reboot --force forced-recovery`) so I can re-flash or debug without physically manipulating the jumper each time.

**Why this priority**: Reduces friction during iterative development. Physical jumper manipulation is tedious during repeated flash cycles, but the device must still be flashable.

**Independent Test**: From a running shell, issue the reboot command and verify the host PC detects the device in APX/recovery mode via `lsusb`.

**Acceptance Scenarios**:

1. **Given** the device is booted to shell, **When** `sudo reboot --force forced-recovery` is executed, **Then** the device enters recovery/APX mode detectable by the host.
2. **Given** the device is in recovery mode, **When** the user flashes new firmware, **Then** the flash completes successfully and the device boots normally on next power cycle.

---

### User Story 4 - Reproducible Boot Configuration (Priority: P2)

As an embedded developer, I want the entire boot optimization to be scripted and reproducible so I can apply it to new devices or recover from a bad flash without manual configuration.

**Why this priority**: Ensures the optimization is not a one-off manual process. Critical for maintainability and applying to multiple boards.

**Independent Test**: Start from a stock JetPack image, run the optimization scripts, verify the device boots within the target time.

**Acceptance Scenarios**:

1. **Given** a freshly flashed stock JetPack image, **When** the optimization scripts are executed, **Then** the device achieves ≤8 second boot time on next reboot.
2. **Given** the optimization scripts, **When** applied to a different Orin Nano DevKit of the same model, **Then** the same boot time improvement is achieved.

---

### Edge Cases

- What happens if the serial console hardware is not connected at boot? (Boot must still complete normally.)
- What happens if a kernel module required for serial communication fails to load? (System must fall back to a safe state where recovery is possible.)
- What happens if the rootfs becomes corrupted? (Recovery mode must remain accessible via software reboot command or, as last resort, physical jumper.)
- What happens if an OTA update adds back disabled services? (Optimization configuration must persist across package updates.)
- What if the 8-second target is not achievable with standard kernel? (Document what was achieved and what further steps — custom kernel, initramfs elimination — would be needed.)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST boot from power-on to interactive shell on serial console in ≤8 seconds.
- **FR-002**: System MUST NOT load any graphics/display subsystems (X11, Wayland, display manager, GPU userspace stack) during boot.
- **FR-003**: System MUST NOT load any audio/sound subsystems (PulseAudio, ALSA userspace daemons, audio kernel modules beyond base ALSA core if needed by serial).
- **FR-004**: System MUST provide an interactive shell (bash or sh) on the serial UART console (typically /dev/ttyTCU0 at 115200 baud).
- **FR-005**: System MUST support entering recovery/APX mode via `sudo reboot --force forced-recovery` without physical jumper manipulation.
- **FR-006**: System MUST disable or remove all systemd services not required for reaching an interactive serial shell.
- **FR-007**: System MUST optimize the bootloader (U-Boot/CBoot) configuration to minimize pre-kernel time.
- **FR-008**: System MUST optimize kernel boot parameters for fastest boot (quiet, minimal initramfs or direct boot, no splash).
- **FR-009**: System MUST provide scripts that apply all optimizations reproducibly to a stock JetPack image.
- **FR-010**: System MUST document the baseline boot time (stock) and optimized boot time with measurement methodology.
- **FR-011**: System MUST preserve network connectivity (Ethernet) for remote access after boot.
- **FR-012**: System MUST NOT break the ability to flash the device via NVIDIA SDK Manager / `flash.sh`.

### Key Entities

- **Boot Stage**: A timed phase of the boot process (firmware/BIOS → bootloader → kernel → userspace → shell). Each stage has a measured duration and optimization targets.
- **Disabled Service**: A systemd unit or kernel module that has been masked/disabled to reduce boot time. Tracked with its original purpose and impact on boot time.
- **Boot Profile**: A complete configuration (kernel cmdline, disabled services list, bootloader settings, device tree overlays) that produces a specific boot time result.
- **Measurement**: A timestamped boot time recording with methodology (serial timestamp, systemd-analyze, or GPIO toggle) for before/after comparison.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Device reaches interactive serial shell within 8 seconds of power-on (measured via serial console timestamps).
- **SC-002**: Zero graphics or audio processes/modules present after boot completion.
- **SC-003**: Software-triggered recovery mode works reliably (100% success rate over 10 consecutive attempts).
- **SC-004**: Optimization can be applied to a stock JetPack image in under 30 minutes (script execution time, not counting flash time).
- **SC-005**: Boot time improvement is at least 60% compared to stock JetPack boot time.
- **SC-006**: Device remains fully flashable via standard NVIDIA tools after optimization.
- **SC-007**: Network (Ethernet) is available within 3 seconds of shell prompt appearing.

## Assumptions

- Target hardware is NVIDIA Jetson Orin Nano Developer Kit (production module on carrier board).
- Base OS is NVIDIA JetPack (L4T/Ubuntu-based) — the latest stable release compatible with Orin Nano.
- Serial console is the primary and only interactive interface; no HDMI/DP display will be connected in production use.
- Ethernet connectivity is required for remote management but WiFi/Bluetooth are not needed and can be disabled.
- The device operates headless — no desktop environment, window manager, or GUI applications are needed.
- USB host functionality may be needed (for peripherals); USB gadget mode is not required unless needed for recovery.
- The 8-second target is aggressive and may require bootloader-level changes, kernel command line tuning, systemd unit pruning, and potentially a custom minimal initramfs or direct boot.
- `sudo reboot --force forced-recovery` is supported by the L4T platform (it writes to a scratch register that the bootloader reads on next boot).
- Physical jumper remains as a last-resort recovery method if software recovery fails.
