# Data Model: Fast Boot to Serial Shell on NVIDIA Orin Nano

**Feature**: 001-fast-boot-orin  
**Date**: 2026-05-14

## Entities

### BootStage

Represents a timed phase of the boot process.

| Field | Type | Description |
|-------|------|-------------|
| name | string | Stage identifier (firmware, uefi, kernel, userspace) |
| start_timestamp_ms | integer | Milliseconds from power-on when stage begins |
| end_timestamp_ms | integer | Milliseconds from power-on when stage ends |
| duration_ms | integer | Computed: end - start |
| target_ms | integer | Maximum allowed duration for this stage |
| status | enum | PASS (within target), FAIL (exceeds target), UNKNOWN |

**Stages** (ordered):
1. `firmware` — MB1 → MB2 → TOS/OP-TEE → DCE (power-on to UEFI handoff)
2. `uefi` — UEFI init → kernel load from NVMe/QSPI (UEFI start to ExitBootServices)
3. `kernel` — Kernel decompression → driver probes → init exec (first kernel msg to init start)
4. `userspace` — BusyBox init → shell prompt (init start to shell accepting input)

### BootProfile

A complete configuration set that produces a specific boot result.

| Field | Type | Description |
|-------|------|-------------|
| name | string | Profile identifier (e.g., "v1-baseline", "v2-uefi-stripped") |
| kernel_config | path | Path to kernel defconfig/fragment |
| kernel_cmdline | string | Complete kernel command line |
| dt_overlay | path | Path to device tree overlay file |
| uefi_config | path | Path to UEFI modification descriptor |
| firmware_config | path | Path to firmware log-level config |
| inittab | path | Path to BusyBox inittab |
| total_boot_ms | integer | Measured total boot time |
| measured_at | datetime | When measurement was taken |

### DisabledComponent

A hardware/software component explicitly disabled for boot time.

| Field | Type | Description |
|-------|------|-------------|
| name | string | Component name (e.g., "nvgpu", "snd_soc_tegra") |
| layer | enum | kernel, device-tree, uefi, firmware |
| method | string | How disabled (kconfig, dt-overlay, uefi-removal, log-level) |
| time_saved_ms | integer | Estimated or measured time saved |
| risk | string | What breaks if this is disabled |
| reversible | boolean | Can be re-enabled without reflash |

### Measurement

A single boot time measurement record.

| Field | Type | Description |
|-------|------|-------------|
| id | integer | Sequential measurement number |
| profile | string | Which BootProfile was active |
| stages | list[BootStage] | Per-stage timing breakdown |
| total_ms | integer | Total power-on to shell |
| method | string | How measured (serial-timestamp, gpio-toggle) |
| serial_device | string | Host serial port used (/dev/ttyUSB0) |
| notes | string | Any anomalies or conditions |

## Relationships

```
BootProfile 1──* DisabledComponent  (a profile has many disabled components)
BootProfile 1──* Measurement        (a profile has many measurements)
Measurement 1──* BootStage          (a measurement has stage breakdowns)
```

## State Transitions

### Boot Optimization Workflow States

```
BASELINE → FIRMWARE_OPT → UEFI_OPT → KERNEL_OPT → DT_OPT → USERSPACE_OPT → VERIFIED
```

Each transition:
1. Apply one layer of optimization
2. Rebuild image (buildroot make)
3. Flash to device
4. Measure boot time
5. Record Measurement entity
6. If regression → revert and investigate
7. If improvement → proceed to next state

### Device States

```
POWERED_OFF → FIRMWARE_RUNNING → UEFI_RUNNING → KERNEL_BOOTING → SHELL_READY
                                                                       │
                                                                       ▼
                                                              RECOVERY_MODE (via reboot cmd)
                                                                       │
                                                                       ▼
                                                              FLASHING (host detects APX)
                                                                       │
                                                                       ▼
                                                              POWERED_OFF (power cycle)
```
