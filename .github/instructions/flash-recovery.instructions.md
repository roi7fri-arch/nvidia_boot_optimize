---
applyTo: "**"
---

# Flash Recovery Mode Procedure

When you need to put the Jetson Orin Nano into APX/recovery mode for flashing:

## Step 1: Try software reboot into recovery

Before asking the user to use the physical jumper, attempt to send the recovery reboot command over serial.
**NOTE**: This works if the device has `/usr/sbin/reboot-to-recovery` installed (our custom 424-byte
static binary that calls `reboot(RESTART2, "forced-recovery")`). It also works with full L4T userspace.

```bash
sudo screen -dmS serial /dev/ttyUSB0 115200
sleep 1
# Try NVIDIA's native recovery command first
sudo screen -S serial -X stuff 'reboot-to-recovery 2>/dev/null || nv-reboot-to-recovery 2>/dev/null || reboot --force forced-recovery 2>/dev/null || { echo 0x02 > /sys/kernel/reboot/mode 2>/dev/null; reboot -f; }\r'
sleep 2
sudo screen -S serial -X quit
```

Then wait ~8 seconds for the device to reboot into APX mode, and verify:

```bash
sleep 8
lsusb | grep "0955:7523"
```

## Step 2: If software reboot fails (Buildroot, boot loop, no OS, or UEFI Shell)

If the software reboot command fails, instruct the user:

1. **Insert the recovery jumper** (short FC REC and GND pins)
2. **Power cycle** the board (unplug and replug power, or press reset)
3. Wait 2 seconds, then **remove the jumper**

Then verify APX mode:

```bash
lsusb | grep "0955:7523"
```

## Step 3: Kill zombie processes before flashing

Always kill any leftover tegrarcm processes before starting a flash:

```bash
sudo killall -9 tegrarcm_v2 2>/dev/null
```

## Known Limitations

- BusyBox `reboot` does NOT support `forced-recovery` argument
- Plain Buildroot kernel lacks NVIDIA's `tegra-pmc` reboot-reason driver
- `devmem` writes to PMC scratch registers (0x0c3a0000) do NOT reliably trigger APX on T234
- The UEFI Shell `reset` command does NOT support recovery mode
- Software recovery requires `CONFIG_TEGRA_PMC=y` and NVIDIA's systemd reboot hooks in userspace

## Important Notes

- The serial port is `/dev/ttyUSB0` at 115200 baud
- APX device shows as USB ID `0955:7523`
- If the device is stuck in UEFI Shell, type `reset` to reboot normally first
- After Linux boots, future optimization: enable `CONFIG_TEGRA_PMC` in Buildroot kernel and add a `/usr/sbin/reboot-to-recovery` script
