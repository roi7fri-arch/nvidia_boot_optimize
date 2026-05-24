---
applyTo: "**"
---

# Partial QSPI Flash - Flash Only Changed Components

Full QSPI flash takes ~8 minutes. Use partial flash to iterate faster during debugging.

## QSPI Partition Layout (Orin Nano, jetson-orin-nano-devkit-nvme)

There is NO `kernel-dtb` partition on QSPI. The DTB and overlays are merged into the UEFI binary.

| What Changed | Partition to Flash | Contains |
|---|---|---|
| L4TConfiguration.dtbo, disable-usb-net.dtbo, or any overlay | `A_cpu-bootloader` | UEFI + merged DTB + all overlays |
| UEFI binary (uefi_jetson.bin) | `A_cpu-bootloader` | UEFI + merged DTB |
| BPMP DTB (bpmp-serial-strip.dts) | `A_bpmp-fw-dtb` | BPMP firmware device tree |
| MB1 log level (mb1_t234_prod.bin) | `A_mb1` | MB1 bootloader |
| MB2 log level (mb2_t234.bin) | `A_mb2` | MB2 bootloader |
| MB1 BCT config | `A_MB1_BCT` | MB1 boot config table |
| Memory config | `A_MEM_BCT` | Memory boot config table |

## Partial Flash Commands

### Flash only UEFI + DTB overlays (most common during boot optimization):

```bash
cd /media/roifr/482a837d-d424-44cd-9783-464d9403e86e/Linux_for_Tegra
sudo killall -9 tegrarcm_v2 2>/dev/null
sudo killall -9 tegradevflash_v2 2>/dev/null
sleep 2
sudo ./flash.sh --qspi-only --no-systemimg -k A_cpu-bootloader jetson-orin-nano-devkit-nvme nvme0n1p1
```

### Flash only BPMP DTB:

```bash
sudo ./flash.sh --qspi-only --no-systemimg -k A_bpmp-fw-dtb jetson-orin-nano-devkit-nvme nvme0n1p1
```

### Flash multiple specific partitions (comma-separated NOT supported — run sequentially):

```bash
sudo ./flash.sh --qspi-only --no-systemimg -k A_cpu-bootloader jetson-orin-nano-devkit-nvme nvme0n1p1
sudo ./flash.sh --qspi-only --no-systemimg -k A_bpmp-fw-dtb jetson-orin-nano-devkit-nvme nvme0n1p1
```

### Full QSPI flash (only when many partitions changed or recovering from corruption):

```bash
sudo ./flash.sh --qspi-only jetson-orin-nano-devkit-nvme nvme0n1p1
```

## Important Notes

1. **Always kill zombies first**: `sudo killall -9 tegrarcm_v2 tegradevflash_v2 2>/dev/null; sleep 2`
2. **Device must be in APX mode** (USB ID `0955:7523`) before any flash command.
3. **If partial flash fails with "probing the target board failed"**: Kill zombie processes and retry. If still fails, the USB connection may be stale — power cycle the board into recovery again.
4. **If partial flash fails with "Can not find partition type"**: The partition name doesn't exist in the current flash layout. Use exact names from `bootloader/flash.xml`.
5. **After interrupted flash**: The QSPI may be corrupted. A full flash is required to recover.
6. **A/B slots**: Only flash slot A (`A_cpu-bootloader`). The B slot is the backup and will be updated automatically by the bootloader on successful boot.

## When to Use Full Flash vs Partial

| Scenario | Use |
|---|---|
| Changed only L4TConfiguration.dtbo | Partial: `A_cpu-bootloader` |
| Changed only disable-usb-net.dtbo | Partial: `A_cpu-bootloader` |
| Changed uefi_jetson.bin (UEFI binary swap) | Partial: `A_cpu-bootloader` |
| Changed BPMP serial/log config | Partial: `A_bpmp-fw-dtb` |
| Changed MB1/MB2 log levels | Partial: `A_mb1` and/or `A_mb2` |
| Changed OVERLAY_DTB_FILE list in p3767.conf.common | Partial: `A_cpu-bootloader` (overlays merged into DTB) |
| Recovery from interrupted flash | Full QSPI |
| First flash after BSP changes | Full QSPI |
| Changed board config (.conf files) | Full QSPI |

## File-to-Partition Mapping

```
L4TConfiguration.dtbo          → merged into → uefi_jetson_with_dtb.bin → A_cpu-bootloader
disable-usb-net.dtbo           → merged into → uefi_jetson_with_dtb.bin → A_cpu-bootloader
tegra234-p3768-0000+p3767-0005-nv.dtb → merged into → uefi_jetson_with_dtb.bin → A_cpu-bootloader
uefi_jetson.bin                → packed into → uefi_jetson_with_dtb.bin → A_cpu-bootloader
tegra234-bpmp-3767-0003-3509-a02.dtb  →                                → A_bpmp-fw-dtb
mb1_t234_prod.bin              →                                        → A_mb1
mb2_t234.bin                   →                                        → A_mb2
```
