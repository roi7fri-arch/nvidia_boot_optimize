# Cold Boot Variance Analysis

> **NOTE:** This file contains early investigation notes. For the **definitive results** with
> instrumented boot analysis, see [cold-boot-variance-report.md](cold-boot-variance-report.md).

## Problem Statement

On cold boots (power-cycle), there is a **~1.2-1.7s variance** in total boot time that does NOT occur on warm reboots (`reboot -f`).

## Root Cause Location (Confirmed via grabserial)

The variable delay occurs **between VarStore ready and EndOfDxe** in the UEFI DXE phase.

### Timeline from slow cold boot (grabserial capture):

| Timestamp | Delta | Event |
|-----------|-------|-------|
| 3.006s | - | UEFI banner |
| 4.142s | +1136ms | MmFvbSmmVarReady (VarStore ready) |
| 4.446s | +287ms | Last StandaloneMm output (blank) |
| **6.190s** | **+1744ms** | MmInstallProtocolInterface: EndOfDxe (24E70042) |
| 6.270s | +80ms | ReadyToBoot (7CE88FB3) |
| 6.830s | +560ms | ExitBootServices (27ABF055) |
| 7.534s | +704ms | "Roi debug" (Linux shell) |

### Timeline from warm reboot (same firmware):

| Timestamp | Delta | Event |
|-----------|-------|-------|
| 0.464s | - | UEFI banner |
| 1.605s | +1141ms | VarStore ready |
| 1.908s | +303ms | Last StandaloneMm output |
| **2.496s** | **+588ms** | EndOfDxe |
| 2.568s | +72ms | ReadyToBoot |
| 3.093s | +525ms | ExitBootServices |
| 3.748s | +655ms | Shell |

## The Gap

- **Warm boot**: VarStore→EndOfDxe = ~600ms
- **Slow cold boot**: VarStore→EndOfDxe = ~1750ms
- **Variance**: ~1150ms

## What Happens in VarStore→EndOfDxe

This is the period where UEFI's BDS (Boot Device Selection) phase:
1. Dispatches remaining DXE drivers
2. Connects PCI root bridges (triggers PCIe enumeration)
3. PCIe link training for NVMe controller (C7 x4 at pcie@14160000)
4. NVMe controller initialization (CSTS.RDY polling)
5. Filesystem discovery on NVMe

## Why Cold Boot is Slower

On cold boot, the NVMe SSD and PCIe PHY are in a fully powered-down state. The PCIe link training takes longer because:
- PHY calibration runs from scratch (no cached tuning)
- NVMe controller needs full initialization (vs warm reset which preserves link state)
- CSTS.RDY polling may take longer due to NVMe firmware cold-start

## Next Steps

Add DEBUG prints in PlatformBm.c around the ConnectRecursive call to split the 1744ms gap into:
1. Time to start PCI connect
2. Time for PCIe link-up (our polling code)
3. Time for NVMe CSTS.RDY
4. Time for filesystem/boot option discovery

## GUID Reference

- `24E70042-D5C5-4260-8C39-0AD3AA32E93D` = EndOfDxe
- `7CE88FB3-4BD7-4679-87A8-A8D8DEE50D2B` = ReadyToBoot
- `27ABF055-B1B8-4C26-8048-748F37BAA2DF` = ExitBootServices

## Key Source Files

- `nvidia-uefi/edk2-nvidia/Silicon/NVIDIA/Library/PlatformBootManagerLib/PlatformBm.c` — BDS logic, ConnectRecursive
- `nvidia-uefi/edk2-nvidia/Silicon/NVIDIA/Drivers/PcieDWControllerDxe/PcieControllerDxe.c` — PCIe init, PERST# delay
- `nvidia-uefi/edk2/MdeModulePkg/Bus/Pci/NvmExpressDxe/` — NVMe driver, CSTS.RDY polling
