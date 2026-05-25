# Jetson Orin Nano Fast Boot — Complete Optimization Guide

**Result:** Power-on to interactive shell in **~4.3 seconds** (cold boot, clean shutdown, best pre-BPMP)  
**Measured:** BPMP→Shell = **3,952 ms ± 16ms** (12 grabserial captures, clean shutdown)  
**Baseline:** 20.8 seconds (stock L4T r36.5)  
**Platform:** NVIDIA Jetson Orin Nano DevKit, L4T r36.5, Buildroot 2026.02, NVMe boot  

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                         QSPI Flash (64MB)                            │
│  MB1 → MB2 → BPMP-FW → OP-TEE → UEFI (t23x_midboot)               │
│  + DTB overlays: L4TConfiguration.dtbo, disable-usb-net.dtbo        │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│                         NVMe (single ext4 partition)                  │
│  /boot/Image        — Custom kernel (lazy BPMP, no debugfs)          │
│  /boot/dtb          — Device tree blob                               │
│  /boot/extlinux/    — L4TLauncher boot config                        │
│  /                  — Buildroot minimal rootfs                        │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 1. UEFI Firmware Optimizations

### 1.1 Custom Midboot Defconfig (`t23x_midboot.defconfig`)

A stripped-down UEFI configuration that removes all unnecessary drivers:

- **Disabled:** USB host/device, display, network (Ethernet/WiFi), SATA, eMMC, SD card
- **Kept:** PCIe/NVMe, serial console, EFI variable services
- **Effect:** Faster DXE phase — fewer drivers to load and initialize

**Build:**
```bash
cd nvidia-uefi
source venv/bin/activate
edk2-nvidia/Platform/NVIDIA/Tegra/build.sh --target RELEASE
# Output: images/uefi_t23x_midboot_RELEASE.bin
```

### 1.2 QuickBoot + ConnectRecursive (`PlatformBm.c`)

Modified UEFI Boot Device Selection (BDS) phase:

- **Replaced** `EfiBootManagerConnectAll()` with targeted `ConnectRecursive()` on PCI root bridge only
- **Effect:** Only connects the NVMe path instead of scanning all buses (USB, SATA, network)
- **Location:** `edk2-nvidia/Silicon/NVIDIA/Library/PlatformBootManagerLib/PlatformBm.c`

### 1.3 PCIe Link-Up Polling (`PcieControllerDxe.c`)

Replaced fixed 200ms delay with active link-up polling:

- **Before:** `DeviceDiscoveryThreadMicroSecondDelay(200000)` — always waits 200ms
- **After:** Poll `PCI_EXP_LNKCTL_STATUS_DLL_ACTIVE` every 1ms, exit as soon as link is up
- **Timeout:** Still 200ms for slow/absent endpoints
- **Result:** NVMe link typically up in <10ms, saving ~190ms
- **Location:** `edk2-nvidia/Silicon/NVIDIA/Drivers/PcieDWControllerDxe/PcieControllerDxe.c`

```c
for (PollIndex = 0; PollIndex < 200; PollIndex++) {
    DeviceDiscoveryThreadMicroSecondDelay(1000);
    LinkStatus = MmioRead32(Private->DbiBase + PCI_EXP_LNKCTL_STATUS);
    if (LinkStatus & PCI_EXP_LNKCTL_STATUS_DLL_ACTIVE) break;
}
```

### 1.4 MDEPKG_NDEBUG (`NVIDIA.common.dsc.inc`)

Eliminates ALL `DEBUG()` macro calls at compile time for RELEASE builds:

```ini
GCC:RELEASE_*_*_CC_FLAGS = -DMDEPKG_NDEBUG -Wno-unused-variable -Wno-unused-but-set-variable
```

- **Effect:** Removes thousands of string formatting operations and serial output from the binary
- **Why `-Wno-unused-*`**: Many variables are only used inside `DEBUG()` — suppresses resulting warnings
- **Impact:** Significant reduction in code size and execution time throughout DXE/BDS

### 1.5 Direct Boot Default (`L4TLauncher.c`)

- **Changed** default boot mode from `NVIDIA_L4T_BOOTMODE_GRUB` → `NVIDIA_L4T_BOOTMODE_DIRECT`
- **Why:** The `L4TBootMode` EFI variable doesn't exist on Buildroot systems. Old default tried to load non-existent GRUB binary, failed, then fell back to Direct Boot — wasting ~0.5-1s
- **Location:** `edk2-nvidia/Silicon/NVIDIA/Application/L4TLauncher/L4TLauncher.c` line ~1751

### 1.6 Suppressed Rootfs Validation

- **Removed** `ValidateRootfsStatus()` error print
- **Why:** Checks NVIDIA A/B slot partition that doesn't exist in Buildroot. Already non-fatal, just noisy
- **Location:** `L4TLauncher.c` line ~1808

### 1.7 Removed Boot Menu & Debug Prints

- **Removed** ESC/F11/s/Enter hotkey prompt from `DisplaySystemAndHotkeyInformation()` in `PlatformBm.c`
- **Removed** "Attempting GRUB Boot" and "Attempting Direct Boot" `ErrorPrint` calls
- **Why:** No display attached, serial-only. Reduces I/O overhead

### 1.8 L4TConfiguration DTB Overlay

UEFI variable overrides applied via device tree overlay:

| Variable | Value | Effect |
|----------|-------|--------|
| `DefaultBootPriority` | `"nvme"` | Skip USB/SD/eMMC enumeration |
| `PlatformBootTimeoutSeconds` | `0` | No timeout for user input |
| `Timeout` | `0` | EFI standard boot timeout |
| `AutoUpdateBrBct` | `0` | Skip BR-BCT update check |
| `RootfsRetryCountMax` | `0` | No rootfs retry overhead |

### 1.9 Hardware Disable DTB Overlay (`disable-usb-net.dtbo`)

Disables unused hardware at firmware level (BL-DTB):

| Device | Controller | Why Disabled |
|--------|-----------|--------------|
| PCIe WiFi (10ec:c822) | `pcie@14100000` | Not needed |
| PCIe Empty Slot | `pcie@141e0000` | Wasted 2s on link timeout! |
| PCIe GbE (10ec:8168) | `pcie@140a0000` | Not needed |
| USB xHCI | `usb@3610000` | Not needed |
| USB XUDC | `usb@3550000` | Not needed |
| USB Pad | `xusb_padctl@3520000` | Not needed |
| EQOS Ethernet | `ethernet@2310000` | Not needed |
| MGBE Ethernet (x4) | `ethernet@6800000..6b00000` | Not needed |
| Display Engine | `display@13800000` | No screen |

**Only kept:** `pcie@14160000` — the NVMe controller (PCIe bus 0004)

---

## 2. Kernel Optimizations

### 2.1 Skip BPMP Debugfs Init (`drivers/firmware/tegra/bpmp.c`)

- **Change:** Replaced `tegra_bpmp_init_debugfs(bpmp)` call with a comment
- **Why:** This function recursively walks the entire BPMP debugfs tree via IPC messages — took **1,602 ms** (1.6 seconds!) at every boot
- **Trade-off:** No `/sys/kernel/debug/bpmp/` filesystem (not needed in production)

```c
/* Skip debugfs init — saves ~1.6s of IPC round-trips at boot */
// tegra_bpmp_init_debugfs(bpmp);
```

### 2.2 Lazy BPMP Clock Registration (`drivers/clk/tegra/clk-bpmp.c`)

- **Change:** Instead of registering all 465 clocks at probe time (each requiring a BPMP IPC round-trip), clocks are registered on-demand when first requested
- **Saved:** ~900 ms
- **How:** Added `max_clk_id` and `clk_lock` mutex to `struct tegra_bpmp`. Clock registration deferred to `clk_hw_get()` time

### 2.3 PCIe Warm-Handoff (`drivers/pci/controller/dwc/pcie-tegra194.c`)

- **Change:** If the PCIe link was already initialized by UEFI (link is up when Linux probes), skip PERST# assertion and LTSSM re-enable entirely
- **Why:** Without this, Linux re-asserts PERST# on a link that UEFI already trained. This forces the NVMe endpoint to do a full cold reset (firmware reload from flash), wasting ~500ms+
- **How:** Check `APPL_LINK_STATUS_RDLH_LINK_UP` at the start of `tegra_pcie_dw_start_link()` — if set, return immediately
- **Saved:** ~300 ms (avoids redundant link training)

```c
val = appl_readl(pcie, APPL_LINK_STATUS);
if (val & APPL_LINK_STATUS_RDLH_LINK_UP) {
    dev_info(pci->dev, "Link already up (UEFI pre-init), skipping PERST#\n");
    return 0;
}
```

### 2.4 NVMe Warm-Handoff (`drivers/nvme/host/pci.c`)

- **Change:** If `CC.EN` (Command/Control Enable) is already set when the NVMe driver probes, wait for the pre-enabled controller to become ready, then do a warm disable→enable cycle instead of a cold enable
- **Why:** UEFI already enabled the NVMe controller and started its firmware. A warm reset is much faster because the controller firmware stays in SRAM — no full firmware reload from flash
- **Saved:** ~200 ms (warm reset vs cold reset)

```c
if (readl(dev->bar + NVME_REG_CC) & NVME_CC_ENABLE) {
    unsigned long timeout = ((NVME_CAP_TIMEOUT(dev->ctrl.cap) + 1) * HZ / 2) + jiffies;
    dev_info(dev->ctrl.device, "CC.EN already set, waiting for RDY\n");
    while (true) {
        u32 csts = readl(dev->bar + NVME_REG_CSTS);
        if (csts & NVME_CSTS_RDY) break;
        if (time_after(jiffies, timeout)) break;
        usleep_range(1000, 2000);
    }
}
/* Standard nvme_disable_ctrl() then nvme_enable_ctrl() follows — fast on warm path */
```

### 2.5 Kernel Command Line (`extlinux.conf`)

```
APPEND root=/dev/nvme0n1p1 rw rootwait rootfstype=ext4 console=ttyTCU0,115200 fbcon=map:0 net.ifnames=0 quiet loglevel=0
```

- `quiet loglevel=0` — suppresses all kernel console output (saves serial I/O time)
- `rootfstype=ext4` — skips filesystem autodetection
- `rootwait` — waits for NVMe without timeout

---

## 3. Boot Flow Optimizations

### 3.1 Boot0002 EFI Variable

Created a UEFI boot entry that loads L4TLauncher directly from firmware volume:

```
Boot0002: L4TLauncher — Fv(49A79A15-8F69-4BE7-A30C-A172F44ABCE7)/\L4TLauncher.efi
BootOrder: Boot0002 first
```

**Effect:** BDS calls L4TLauncher immediately without going through UEFI Shell (which has a hardcoded 5-second startup delay)

### 3.2 startup.nsh Fallback

A file at NVMe root (`/startup.nsh`) containing:
```
FS0:\L4TLauncher.efi
```

If Boot0002 variable is lost (e.g., after full QSPI reflash), UEFI Shell auto-runs this script as last resort.

### 3.3 Single-Partition NVMe

- **Clean GPT** with a single ext4 partition (label "APP")
- **Why:** Old L4T 15-partition layout confused L4TLauncher (it found recovery initrd partitions instead of rootfs)

---

## 4. Userspace Optimizations

### 4.1 Minimal Init Scripts

Only `S01seedrng` runs at boot (~16ms). All others disabled via `chmod -x`:

| Script | Status | Why |
|--------|--------|-----|
| `S01seedrng` | ✅ Enabled | RNG seed — fast, good for security |
| `S01syslogd` | ❌ Disabled | No logging needed in embedded |
| `S02klogd` | ❌ Disabled | `dmesg` still works without it |
| `S02sysctl` | ❌ Disabled | No custom sysctl settings |
| `S11modules` | ❌ Disabled | `/etc/modules-load.d/` is empty |
| `S40network` | ❌ Disabled | Only loopback, not needed |
| `S50crond` | ❌ Disabled | No cron jobs configured |

### 4.2 Fixed rcS Script

Added `[ ! -x "$i" ] && continue` to `/etc/init.d/rcS` so non-executable scripts are silently skipped (no "Permission denied" noise).

---

## 5. Timing Breakdown

### Cold Boot (power-on → shell): ~4.3s (best case)

```
[0.000]  Power-on
[0.320]  BPMP ready (best case; can be up to 1.89s with full DRAM training)
[0.784]  OP-TEE + UEFI DXE start
[1.841]  VarStore validation complete
[2.512]  DXE dispatch done (PCIe/NVMe enumerated)
[2.768]  UEFI BDS → EndOfDxe → L4TLauncher
[3.918]  Kernel + NVMe warm-handoff + root mount
[~4.270] Interactive shell (#)
```

### Measured via grabserial (BPMP→Shell breakdown):

```
BPMP start               → +0ms    (reference)
OP-TEE → UEFI banner     → +464ms
UEFI → VarStore ready    → +1521ms
DXE dispatch (NVMe enum) → +2192ms
[BT] WaitAsync           → +2544ms
EndOfDxe done            → +2800ms
ConnectRecursive         → +2801ms  (<1ms!)
kernel → shell           → +3952ms
```
[~4.700] Interactive shell (#)
```

### Warm Reboot (reboot command → shell): ~7.0s

```
[0.000]  reboot issued
[2.300]  Shutdown complete, hardware reset
[2.640]  BPMP starts
[2.970]  BPMP ready
[3.450]  OP-TEE → UEFI
[4.890]  L4TLauncher → kernel
[6.400]  NVMe warm-handoff + rootfs mounted
[~7.000] Interactive shell (#)
```

### After Hard Power-Cut (extra NVMe FTL recovery):

```
Same as cold boot, but DXE dispatch phase takes 1-4s longer
due to NVMe SSD internal FTL metadata recovery.
Total: ~5.4s to ~8.1s (BPMP→Shell = 5.2-7.1s)
```

---

## 6. Source File Locations

| Component | File | Path |
|-----------|------|------|
| UEFI midboot config | `t23x_midboot.defconfig` | `nvidia-uefi/nvidia-config/t23x_midboot/defconfig` |
| UEFI BDS (QuickBoot) | `PlatformBm.c` | `nvidia-uefi/edk2-nvidia/Silicon/NVIDIA/Library/PlatformBootManagerLib/` |
| UEFI PCIe polling | `PcieControllerDxe.c` | `nvidia-uefi/edk2-nvidia/Silicon/NVIDIA/Drivers/PcieDWControllerDxe/` |
| UEFI MDEPKG_NDEBUG | `NVIDIA.common.dsc.inc` | `nvidia-uefi/edk2-nvidia/Platform/NVIDIA/` |
| L4TLauncher (Direct Boot) | `L4TLauncher.c` | `nvidia-uefi/edk2-nvidia/Silicon/NVIDIA/Application/L4TLauncher/` |
| UEFI binary (built) | `uefi_t23x_midboot_RELEASE.bin` | `nvidia-uefi/images/` |
| BPMP driver (debugfs skip) | `bpmp.c` | `buildroot-2026.02/output/build/linux-custom/drivers/firmware/tegra/` |
| BPMP clocks (lazy) | `clk-bpmp.c` | `buildroot-2026.02/output/build/linux-custom/drivers/clk/tegra/` |
| BPMP header (fields) | `bpmp.h` | `buildroot-2026.02/output/build/linux-custom/include/soc/tegra/` |
| PCIe warm-handoff | `pcie-tegra194.c` | `buildroot-2026.02/output/build/linux-custom/drivers/pci/controller/dwc/` |
| NVMe warm-handoff | `pci.c` | `buildroot-2026.02/output/build/linux-custom/drivers/nvme/host/` |
| Kernel Image (built) | `Image` | `buildroot-2026.02/output/build/linux-custom/arch/arm64/boot/` |
| DTB overlay (UEFI vars) | `L4TConfiguration.dtbo` | `Linux_for_Tegra/kernel/dtb/` + `bootloader/` |
| DTB overlay (HW disable) | `disable-usb-net.dtbo` | `Linux_for_Tegra/kernel/dtb/` + `bootloader/` |
| Flash config (overlays) | `p3767.conf.common` | `Linux_for_Tegra/` |
| L4T flash tool | `flash.sh` | `Linux_for_Tegra/` |

---

## 7. Key Decisions & Trade-offs

| Decision | Benefit | Trade-off |
|----------|---------|-----------|
| Disable all PCIe except NVMe | -2s (link timeouts) | No WiFi, no Ethernet |
| Skip BPMP debugfs | -1.6s | No BPMP debug filesystem |
| Lazy clock registration | -0.9s | Slightly slower first clock access |
| UEFI midboot defconfig | -1.0s | No USB/display in firmware |
| MDEPKG_NDEBUG (RELEASE) | -0.3s | No DEBUG() output in UEFI at all |
| UEFI PCIe link-up polling | -0.19s | None (still has 200ms timeout) |
| Kernel PCIe warm-handoff | -0.3s | Requires UEFI to pre-init PCIe |
| Kernel NVMe warm-handoff | -0.2s | Requires UEFI to leave CC.EN set |
| Direct Boot default | -0.5s | Can't boot GRUB without NV var change |
| quiet loglevel=0 | -0.2s | No kernel messages on serial |
| Disable init scripts | -0.1s | No syslog, no network, no cron |

**Total savings from baseline:** ~20.8s → ~3.95s (BPMP→Shell) = **16.85 seconds removed**

---

## 8. Cold Boot Variance (Hardware Limitations)

Two sources of timing variance that are **not fixable in software**:

### Pre-BPMP: DRAM Training (304ms – 1890ms)
- PMC scratch registers lose DRAM training data when board capacitors drain
- Full DRAM retraining adds ~1.5s
- Fix: coin cell battery on PMC/always-on rail (hardware mod)

### NVMe FTL Recovery: After Hard Power-Cut (+0/2/4 seconds)
- NVMe SSD must recover internal Flash Translation Layer mapping tables
- UEFI polls `CSTS.RDY` in `NvmExpressDxe` during DXE dispatch
- Confirmed via instrumented boot: `ConnectRecursive` takes <1ms; 100% of delay is in DXE NVMe driver
- Fix: always do clean shutdown, or use SSD with Power-Loss Protection (PLP) capacitors
