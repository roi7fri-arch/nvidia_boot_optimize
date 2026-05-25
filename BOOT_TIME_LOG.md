# Boot Time Optimization Log

**Target:** ≤ 8 seconds power-on to interactive serial shell  
**Platform:** NVIDIA Jetson Orin Nano DevKit (Tegra T234, ARM64)  
**Boot media:** NVMe (Realtek 10ec:5765 on PCIe bus 0004, controller `14160000.pcie`)  
**OS:** Buildroot 2026.02, BusyBox init, kernel 5.15.185-prod  
**Firmware:** L4T r36.5, UEFI 36.5.0  
**Serial:** FTDI FT232H at `/dev/ttyUSB0`, ttyTCU0 115200 baud  

---

## Current Best: ~3.95s BPMP→Shell (cold boot, clean shutdown) ✓

| Stage | Time | Notes |
|-------|------|-------|
| Power-on → BPMP start | ~320 ms (best) | MB1/MB2 log_level=0; varies 304-1890ms (DRAM training) |
| BPMP → OP-TEE → UEFI start | ~464 ms | OP-TEE 4.2 init |
| UEFI DXE (midboot, NVMe enum) | ~1,057 ms | VarStore + PCIe/NVMe DXE dispatch |
| UEFI DXE dispatch → BDS entry | ~671 ms | NVMe CSTS.RDY polling |
| UEFI BDS (EndOfDxe+Boot) | ~256 ms | MM notification, no ConnectAll |
| Post-BDS → kernel → shell | ~1,150 ms | L4TLauncher Direct Boot, kernel, init |
| **Firmware total (BPMP→Shell)** | **~3,952 ms** | Measured via grabserial (±16ms) |
| **Total cold boot (power-on → shell)** | **~4,270 ms** | Best case (short pre-BPMP) |
| **Total cold boot (worst pre-BPMP)** | **~5,840 ms** | Long DRAM training |

### After hard power-cut (NVMe FTL recovery):
| Stage | Time | Notes |
|-------|------|-------|
| **Firmware total (BPMP→Shell)** | **~5,168 ms** | +1.2s NVMe FTL recovery |
| **Worst case (4s FTL + long DRAM)** | **~9,900 ms** | Rare, only after severe power-cut |

---

## Optimization History

### Baseline (unoptimized L4T r36.5 UEFI)
- L4TLauncher Entry: **16,575 ms**
- Kernel to init: **4,260 ms**
- Total: **~20.8 seconds**

### Round 1: L4TConfiguration overlay (2026-05-14)
**Changes:**
- `DefaultBootPriority = "nvme"` — skip USB/SD/eMMC device enumeration
- `PlatformBootTimeoutSeconds = 0` — no timeout waiting for user input
- `Timeout = 0` (gEfiGlobalVariableGuid) — EFI standard timeout = 0
- `AutoUpdateBrBct = 0` — skip BR-BCT update check
- `RootfsRetryCountMax = 0` — no rootfs retry overhead

**Result:**
- L4TLauncher Entry: **10,408 ms** (saved 6.2s)

### Round 2: Aggressive hardware disable via DTB overlay (2026-05-14)
**Changes (disable-usb-net.dtbo applied to BL DTB):**
- Disabled `pcie@14100000` — Realtek WiFi (10ec:c822), not needed
- Disabled `pcie@141e0000` — Empty slot, **wasted 2s on link timeout!**
- Disabled `pcie@140a0000` — Realtek GbE (10ec:8168), not needed
- Disabled `usb@3610000` — xHCI USB host controller
- Disabled `usb@3550000` — XUDC USB device controller
- Disabled `xusb_padctl@3520000` — USB pad controller
- Disabled `ethernet@2310000` — EQOS ethernet
- Disabled `ethernet@6800000..6b00000` — 4x MGBE controllers
- Disabled `display@13800000` — Display engine (no screen needed)

**Kept only:**
- `pcie@14160000` — NVMe controller (bus 0004)

**Result:**
- L4TLauncher Entry: **3,761 ms** (saved 6.6s more)
- Kernel to init: **1,880 ms** (saved 2.4s — no unused PCIe link timeouts)

### Round 3: Fix warm reboot + eliminate Shell delay (2026-05-17)

**Problem:** After any reboot, device dropped to UEFI Shell with a 5-second startup delay. L4TLauncher's internal BDS boot failed with `FindPartitionInfo: Failed to find parents` because PCIe/NVMe wasn't connected when L4TLauncher ran from BDS.

**Root causes identified:**
1. Old NVMe had 15 L4T partitions — L4TLauncher found recovery initrd partitions instead of rootfs
2. Without an EFI System Partition, UEFI BDS couldn't create a valid NVMe boot entry
3. UEFI Shell has a hardcoded 5-second `startup.nsh` delay (PCD, not runtime-configurable)

**Fixes applied:**
1. **Clean NVMe** — Wiped all 15 partitions via M.2 adapter, created single ext4 partition labeled "APP"
2. **startup.nsh fallback** — Created `/startup.nsh` on NVMe root containing `FS0:\L4TLauncher.efi`
3. **Boot0002 EFI variable** — Created UEFI boot entry pointing to `Fv(49A79A15-...)/\L4TLauncher.efi`, set as first in BootOrder. This makes BDS call L4TLauncher directly, bypassing the Shell entirely.

**Result:**
- Eliminated 5-second Shell startup delay
- Warm reboot now reliably boots to Linux in same time as cold boot

### Round 4: Kernel BPMP optimizations (2026-05-17)

**Changes:**
1. **Skip BPMP debugfs init** (`drivers/firmware/tegra/bpmp.c`):
   - `tegra_bpmp_init_debugfs()` was recursively walking BPMP debugfs tree via IPC
   - Took **1,602 ms** (1.6 seconds!) of IPC round-trips at boot
   - Replaced call with: `/* Skip debugfs init — saves ~1.6s of IPC round-trips at boot */`
2. **Lazy BPMP clock registration** (`drivers/clk/tegra/clk-bpmp.c`):
   - All 465 clocks registered at probe time via individual BPMP IPC calls
   - Changed to on-demand registration: clocks registered only when first requested
   - Saved **~900 ms**

**Result:**
- Kernel boot: saved **~2.5s** combined

### Round 5: UEFI midboot defconfig + QuickBoot + PCIe polling + MDEPKG_NDEBUG (2026-05-17)

**Changes (all in one commit: `fast-boot-v1`):**
1. **Custom `t23x_midboot.defconfig`** — disables USB, display, network, SATA, eMMC drivers in UEFI
2. **QuickBoot + ConnectRecursive** (`PlatformBm.c`):
   - Replaced `EfiBootManagerConnectAll()` with targeted `ConnectRecursive()` on PCI root bridge only
   - Boots NVMe path without scanning all buses
3. **PCIe link-up polling** (`PcieControllerDxe.c`):
   - Replaced fixed `DeviceDiscoveryThreadMicroSecondDelay(200000)` (200ms sleep) with 1ms polling loop
   - Polls `PCI_EXP_LNKCTL_STATUS_DLL_ACTIVE` bit every 1ms, timeout at 200ms
   - NVMe link typically up in <10ms, saving ~190ms
4. **MDEPKG_NDEBUG for RELEASE** (`NVIDIA.common.dsc.inc`):
   - Added `GCC:RELEASE_*_*_CC_FLAGS = -DMDEPKG_NDEBUG` — eliminates ALL `DEBUG()` macro calls at compile time
   - Also added `-Wno-unused-variable -Wno-unused-but-set-variable` to suppress resulting warnings
   - Removes thousands of string formatting and serial output operations from the binary
5. **Boot timeout = 0** — no delay waiting for hotkeys

**Result:**
- UEFI DXE+BDS: saved **~1.5s** combined (polling + no debug output)

### Round 6: UEFI boot flow cleanup (2026-05-17)

**Changes (`L4TLauncher.c` + `PlatformBm.c`):**
1. **Default boot mode GRUB → DIRECT** — L4TBootMode NV variable doesn't exist on Buildroot, was defaulting to GRUB, loading non-existent GRUB binary, failing, then falling back to Direct Boot (wasted ~0.5-1s)
2. **Suppressed rootfs validation error** — `ValidateRootfsStatus()` checks NVIDIA A/B slot partition that doesn't exist in Buildroot; error print suppressed (already non-fatal)
3. **Removed boot menu prints** — ESC/F11/s/Enter hotkey prompt removed from `DisplaySystemAndHotkeyInformation()` (no display attached)
4. **Removed "Attempting GRUB/Direct Boot" prints** — unnecessary serial output

**Result:**
- Eliminated failed GRUB load path, cleaner serial output
- Warm reboot: **~7.0s** (was ~9.0s)

### Round 7: Minimal init (2026-05-17)

**Changes:**
- Disabled `S01syslogd` — no logging needed
- Disabled `S02klogd` — no kernel log daemon needed
- Disabled `S02sysctl` — no custom sysctl settings
- Disabled `S11modules` — no modules to load (`/etc/modules-load.d/` empty)
- Disabled `S40network` — no network interfaces (only loopback)
- Disabled `S50crond` — no scheduled tasks
- Kept only `S01seedrng` (RNG seed, ~16ms)
- Fixed `rcS` to skip non-executable scripts silently (`[ ! -x "$i" ] && continue`)

**Result:**
- Init scripts: ~16ms (was ~150ms with sysctl, ~1.5s if all ran)
- No "Permission denied" noise in serial output

### Round 8: Kernel cmdline optimization (2026-05-17)

**Changes:**
- Added `quiet loglevel=0` — suppress all kernel console output
- Reduced serial I/O overhead during boot

### Round 9: Kernel PCIe warm-handoff (2026-05-24)

**Changes (`drivers/pci/controller/dwc/pcie-tegra194.c`):**
- If UEFI already initialized the PCIe link (link is up when Linux probes), **skip PERST# assertion and LTSSM re-enable entirely**
- Checks `APPL_LINK_STATUS_RDLH_LINK_UP` — if set, returns immediately
- This preserves the NVMe controller state from UEFI, so the NVMe firmware stays in SRAM and doesn't need a cold reset

**Why this matters:**
- Without this patch, Linux re-asserts PERST# → NVMe does full cold reset → waits for CSTS.RDY again (~500ms+)
- With this patch, NVMe stays ready from UEFI → kernel NVMe probe is much faster
- Enables the Round 10 optimization (NVMe warm reset instead of cold reset)

**Result:**
- PCIe NVMe ready time: saved **~300ms** (avoids redundant link training)

### Round 10: Kernel NVMe warm-handoff (2026-05-24)

**Changes (`drivers/nvme/host/pci.c`):**
- If `CC.EN` (Command/Control Enable) is already set when Linux NVMe driver probes, the controller was pre-enabled by UEFI
- Wait for `CSTS.RDY=1` (using CAP.TO-based timeout), then proceed with a **warm disable→enable cycle** instead of cold enable
- A warm reset is much faster because NVMe controller firmware stays in SRAM — no full firmware reload from flash

**Code:**
```c
if (readl(dev->bar + NVME_REG_CC) & NVME_CC_ENABLE) {
    /* Wait for pre-enabled controller to become ready */
    while (!(readl(dev->bar + NVME_REG_CSTS) & NVME_CSTS_RDY)) {
        if (time_after(jiffies, timeout)) break;
        usleep_range(1000, 2000);
    }
}
/* Then does standard disable→enable which is fast on warm path */
```

**Result:**
- NVMe probe time: saved **~200ms** (warm reset vs cold reset)

### Round 11: Cold boot variance investigation (2026-05-25)

**Discovery (not an optimization, but important finding):**
- Instrumented UEFI PlatformBm.c with `[BT]` AsciiPrint timing markers at 4 key BDS points
- Captured boots after clean shutdown and after hard power-cut
- **Definitive finding**: 100% of variance is in DXE dispatch phase (NVMe CSTS.RDY polling)
- After hard power-cut: NVMe SSD needs 1-4s extra for FTL metadata recovery
- `ConnectRecursive` in BDS takes <1ms in ALL cases (devices already connected during DXE)
- **Conclusion**: Variance is NVMe hardware behavior — unfixable in software
- **Mitigation**: Always do clean shutdown, or use SSD with Power-Loss Protection (PLP)

---

## Boot Flow Diagram

```
Power-On
  → MB1 (log_level=0)
  → MB2 (log_level=0)
  → BPMP
  → OP-TEE
  → UEFI DXE (t23x_midboot: no USB/display/net/SATA/eMMC)
  → UEFI BDS (QuickBoot + ConnectRecursive on PCI root only)
  → Boot0002: Fv(49A79A15-...)/\L4TLauncher.efi
  → L4TLauncher Direct Boot (no GRUB fallback, no rootfs validation)
  → EFI stub loads kernel + DTB from NVMe
  → Linux kernel 5.15.185-prod (lazy BPMP clocks, no debugfs)
  → PCIe NVMe enumeration (single controller: 14160000)
  → Mount ext4 rootfs on nvme0n1p1
  → /sbin/init (BusyBox)
  → S01seedrng only (~16ms)
  → Interactive shell (#)
```

---

## Key Files

| File | Location | Purpose |
|------|----------|---------|
| `L4TConfiguration.dtbo` | `kernel/dtb/` & `bootloader/` | UEFI variables (timeout=0, nvme priority) |
| `disable-usb-net.dtbo` | `kernel/dtb/` & `bootloader/` | Disable unused PCIe/USB/display/ethernet |
| `p3767.conf.common` | L4T root | `OVERLAY_DTB_FILE` includes both overlays |
| `uefi_jetson.bin` | `bootloader/` | Built from t23x_midboot defconfig (3.1MB) |
| `NVIDIA.common.dsc.inc` | `edk2-nvidia/Platform/NVIDIA/` | MDEPKG_NDEBUG for RELEASE builds |
| `PcieControllerDxe.c` | `edk2-nvidia/Silicon/NVIDIA/Drivers/PcieDWControllerDxe/` | PCIe link-up polling (1ms intervals) |
| `L4TLauncher.c` | `edk2-nvidia/Silicon/NVIDIA/Application/L4TLauncher/` | Boot mode default=DIRECT, no GRUB fallback |
| `PlatformBm.c` | `edk2-nvidia/Silicon/NVIDIA/Library/PlatformBootManagerLib/` | QuickBoot, ConnectRecursive, no boot menu |
| `clk-bpmp.c` | `linux-custom/drivers/clk/tegra/` | Lazy on-demand clock registration |
| `bpmp.c` | `linux-custom/drivers/firmware/tegra/` | Debugfs init skipped |
| `pcie-tegra194.c` | `linux-custom/drivers/pci/controller/dwc/` | PCIe warm-handoff (skip PERST# if link up) |
| `pci.c` | `linux-custom/drivers/nvme/host/` | NVMe warm-handoff (CC.EN pre-enabled path) |

| `startup.nsh` | NVMe `/` (root) | Fallback: `FS0:\L4TLauncher.efi` |
| `extlinux.conf` | NVMe `/boot/extlinux/` | Kernel boot config |
| `rcS` | NVMe `/etc/init.d/` | Modified: skips non-executable scripts |

## NVMe Partition Layout (Clean)

Single partition, GPT:
- **Partition 1**: ext4, label "APP", partlabel "APP" (~298 GB)

```
/boot/Image                    — 13 MB ARM64 kernel
/boot/dtb                      — 250 KB tegra234-p3768-0000+p3767-0005-nv.dtb
/boot/extlinux/extlinux.conf   — L4TLauncher boot config
/startup.nsh                   — UEFI Shell auto-boot script (fallback)
```

### extlinux.conf
```
TIMEOUT 30
DEFAULT primary

MENU TITLE L4T boot options

LABEL primary
      MENU LABEL primary kernel
      LINUX /boot/Image
      FDT /boot/dtb
      APPEND root=/dev/nvme0n1p1 rw rootwait rootfstype=ext4 console=ttyTCU0,115200 fbcon=map:0 net.ifnames=0 quiet loglevel=0
```

## UEFI Boot Variables

```
BootOrder: Boot0002, Boot0001, Boot0000, Boot0006, Boot0007
Boot0002: L4TLauncher — Fv(49A79A15-8F69-4BE7-A30C-A172F44ABCE7)/\L4TLauncher.efi  ← PRIMARY
Boot0001: NVMe device (fails without ESP, falls through)
Boot0000: Enter Setup
Boot0006: BootManagerMenuApp
Boot0007: UEFI Shell (runs startup.nsh as last resort)
```

## Flash Commands

```bash
# Full QSPI (~8 min, use only when recovering from corruption):
cd /media/roifr/482a837d-d424-44cd-9783-464d9403e86e/Linux_for_Tegra
sudo killall -9 tegrarcm_v2 tegradevflash_v2 2>/dev/null; sleep 2
sudo ./flash.sh --qspi-only jetson-orin-nano-devkit-nvme nvme0n1p1

# Partial: UEFI + DTB overlays only (~62s):
sudo killall -9 tegrarcm_v2 tegradevflash_v2 2>/dev/null; sleep 2
sudo ./flash.sh --qspi-only --no-systemimg -k A_cpu-bootloader jetson-orin-nano-devkit-nvme nvme0n1p1

# Partial: BPMP DTB only:
sudo ./flash.sh --qspi-only --no-systemimg -k A_bpmp-fw-dtb jetson-orin-nano-devkit-nvme nvme0n1p1

# Verify APX mode:
lsusb | grep "0955:7523"
```

## Problems Solved

| Problem | Root Cause | Fix |
|---------|-----------|-----|
| Boot loop (no rootfs) | Minimal UEFI (1.6MB) lacks NVMe drivers | Restored full UEFI (3.1MB) |
| ASSERT in BdsEntry.c(533) | Invalid UEFI vars (ConIn, BootMenuEnabled) | Removed from overlay |
| Warm reboot → UEFI Shell | L4TLauncher can't find NVMe before PCIe connected | Boot0002 FV entry + startup.nsh fallback |
| L4TLauncher finds wrong partition | Old 15-partition GPT had recovery initrd | Clean single-partition NVMe |
| 5-second Shell delay | Shell PCD hardcoded delay | Boot0002 bypasses Shell entirely |
| Flash probe failures | Zombie tegrarcm_v2 processes | Always kill before flash |
| `devmem` PMC writes blocked | `CONFIG_STRICT_DEVMEM=y` | Hardware limitation (use physical jumper for recovery) |
| BPMP debugfs takes 1.6s | `tegra_bpmp_init_debugfs()` IPC round-trips | Skip debugfs init entirely |
| BPMP clocks take 0.9s | All 465 clocks registered at probe via IPC | Lazy on-demand registration |
| UEFI tries GRUB first | `L4TBootMode` NV var missing → default GRUB | Changed default to DIRECT |
| "Failed to validate rootfs" | NVIDIA A/B slot partition missing in Buildroot | Suppressed error print (non-fatal) |
| ESC/F11/s/Enter on serial | `DisplaySystemAndHotkeyInformation()` always prints | Removed Print calls |
| Init scripts "Permission denied" | `rcS` runs all `S*` files without `-x` check | Added `[ ! -x "$i" ] && continue` |
| PCIe link-up wastes 200ms | Fixed `MicroSecondDelay(200000)` in UEFI | 1ms polling loop, exits on DLL_ACTIVE |
| Linux re-trains PCIe link | Kernel asserts PERST# even if UEFI link is up | Skip PERST# if `RDLH_LINK_UP` set |
| Linux cold-resets NVMe | Kernel does full disable+enable cycle | Detect CC.EN, do warm reset instead |
| UEFI DEBUG() serial spam | Thousands of DEBUG() calls in RELEASE build | `-DMDEPKG_NDEBUG` eliminates at compile time |
| Cold boot +2-4s variance | NVMe FTL recovery after hard power-cut | Hardware limitation; use clean shutdown |

## Known Limitations

- Display overlay (`display@13800000` disabled) suppresses UEFI combined-uart serial output; serial resumes at kernel
- `devmem` writes to PMC scratch registers are blocked by `CONFIG_STRICT_DEVMEM=y`
- The `uefi_jetson_minimal.bin` (1.6MB) lacks PCIe/NVMe drivers — cannot boot from NVMe
- UEFI Shell PCD delay (5s) is compile-time — cannot be changed without rebuilding UEFI
- Boot0002 EFI variable is volatile — a full QSPI reflash resets it (must re-create from Linux after flash)

## Cold Boot Timing Variance

Cold boot times vary depending on two factors:

### Variance Source 1: Pre-BPMP (304ms – 1890ms)

**Root cause: MB1 LPDDR5 DRAM training**

On Tegra T234, MB1 stores DRAM training results in PMC scratch registers. These are powered by the board's always-on rail capacitors (no backup battery on DevKit):

| Scenario | What happens | Pre-BPMP time |
|----------|-------------|-----------|
| Quick power cycle (caps still charged) | PMC scratch preserved → fast DRAM path | **~320 ms** |
| Long power off (caps fully drained, >3-5s) | PMC scratch lost → full DRAM training | **~1,500-1,890 ms** |
| Warm reboot (`reboot` command) | Never loses power → always fast | **~320 ms** |

**Not fixable in software.** On a production board with a coin cell battery or supercapacitor on the PMC/always-on rail, cold boot would always hit the fast path.

### Variance Source 2: NVMe FTL Recovery (after hard power-cut only)

**Root cause: NVMe SSD internal FTL metadata recovery**

After an unclean power loss (unplug while running), the NVMe SSD must recover its Flash Translation Layer mapping tables before it can signal `CSTS.RDY=1`. This adds 0-4 seconds to the UEFI DXE dispatch phase.

| Scenario | Extra delay | Total BPMP→Shell |
|----------|-------------|------------------|
| Clean shutdown | 0ms | **3,952 ms** (consistent ±16ms) |
| Hard power-cut (mild) | +1,122 ms | **~5,074 ms** |
| Hard power-cut (severe) | +3,136 ms | **~7,088 ms** |

**Confirmed via instrumented boot analysis** (AsciiPrint markers in PlatformBm.c):
- `ConnectRecursive` takes <1ms in ALL cases
- 100% of variance is in NVMe DXE driver polling `CSTS.RDY` during DXE dispatch
- Variance is quantized at ~2s increments (0, 1, or 2 FTL recovery cycles)

**Not fixable in software.** Mitigation: clean shutdown before power removal, or use SSD with PLP (Power-Loss Protection) capacitors.

## Future Optimization Opportunities

- [ ] Kernel: LZ4 compressed Image for faster load from NVMe
- [ ] Kernel: disable unused subsystems (sound, media, crypto) at compile time
- [ ] Init: replace BusyBox init with direct `/bin/sh` exec (skip rcS entirely)
- [ ] Consider: store kernel in QSPI flash to eliminate NVMe dependency
- [ ] UEFI: reduce OP-TEE/StMM init time (~1.4s currently)
- [ ] Shutdown: faster reboot path (skip SIGTERM grace period)
- [ ] Consider: SSD with Power-Loss Protection (PLP) to eliminate FTL recovery variance

### Confirmed Not Feasible
- ~~PCIe: tune NVMe link training timeout~~ — Already optimized (polling at 1ms, <10ms typical)
- ~~NVMe cold boot variance~~ — Hardware limitation (SSD FTL recovery), unfixable in software
- ~~Pre-BPMP variance~~ — Silicon behavior (DRAM training), requires hardware mod (coin cell/supercap)
