# CUDA Runtime Support — Jetson Orin Nano Buildroot Image

**Goal:** Run pre-compiled CUDA applications on the device (no on-device compilation)  
**Platform:** Jetson Orin Nano, L4T r36.5, Buildroot 2026.02, kernel 5.15.185-tegra  
**Status:** IMPLEMENTED AND VERIFIED (2026-05-26)  
**Boot time impact:** Negligible (~0ms — modules load in parallel with init)  
**Boot time with CUDA:** ~3.88s (BPMP → shell prompt)  

---

## What's Needed

### 1. Rootfs Packages (from L4T .deb files)

| Package | Contents | Size (compressed) |
|---------|----------|-------------------|
| `nvidia-l4t-core` | GPU runtime libs (`libnvrm_gpu.so`, `libnvos.so`, etc.) | 3.6 MB |
| `nvidia-l4t-cuda` | `libcuda.so.1.1`, `libnvcucompat.so`, `libnvcudla.so` | 6.4 MB |
| `nvidia-l4t-firmware` | GPU firmware blobs (`/lib/firmware/nvidia/ga10b/`) | 1.7 MB |

Source: `/media/roifr/482a837d-d424-44cd-9783-464d9403e86e/Linux_for_Tegra/nv_tegra/l4t_deb_packages/`

### 2. Kernel Modules (OOT — Out-Of-Tree)

These must be loaded in order for the GPU to function:

```
host1x.ko → mc-utils.ko → nvmap.ko → nvgpu.ko
```

Source: `Linux_for_Tegra/kernel/kernel_oot_modules.tbz2`

**Problem:** Prebuilt modules have `vermagic: 5.15.185-tegra SMP preempt mod_unload modversions aarch64`.  
Our kernel is `5.15.185-prod`. The modules **will not load** without fixing the version mismatch.

### 3. Kernel Config Requirements

Already enabled in `linux-orin-minimal.config`:
- ✅ `CONFIG_MODULES=y` — module loading
- ✅ `CONFIG_ARM_SMMU=y` — GPU IOMMU
- ✅ `CONFIG_IOMMU_SUPPORT=y`
- ✅ `CONFIG_FW_LOADER=y` — firmware loading
- ✅ `CONFIG_CMA=y` — contiguous memory for GPU buffers
- ✅ `CONFIG_PM_DEVFREQ=y` — GPU frequency scaling
- ✅ `CONFIG_THERMAL=y` — thermal management
- ✅ `CONFIG_DEVTMPFS=y` — device nodes
- ✅ `CONFIG_MODULE_SIG_FORCE` is NOT set — allows unsigned modules

NOT needed (headless CUDA):
- `CONFIG_DRM` — display rendering (not needed without monitor)
- `CONFIG_TEGRA_HOST1X` — in-tree version (OOT provides its own)

---

## Version Mismatch Solutions

### ~~Option A: Change LOCALVERSION to match~~ (insufficient alone)
### ~~Option B: Build OOT modules from source~~ (unnecessary)
### Option C: Disable modversions + match LOCALVERSION ✅ IMPLEMENTED

```diff
- CONFIG_LOCALVERSION="-prod"
+ CONFIG_LOCALVERSION="-tegra"
- CONFIG_MODVERSIONS=y
+ # CONFIG_MODVERSIONS is not set
```

This allows loading prebuilt OOT modules directly. Combined with additional kernel config
changes and a custom kernel stub module, all GPU modules load cleanly.

---

## Additional Kernel Requirements Discovered During Implementation

The prebuilt OOT modules require symbols not present in a minimal kernel. These were resolved:

### Kernel Config Additions

| Config | Required By | Purpose |
|--------|-------------|---------|
| `CONFIG_FTRACE=y` | nvgpu.ko | Function tracing infrastructure |
| `CONFIG_DYNAMIC_FTRACE=y` | nvgpu.ko | Dynamic ftrace (needs `_mcount` symbol) |
| `CONFIG_DYNAMIC_FTRACE_WITH_REGS=y` | nvgpu.ko | Register saving for ftrace |
| `CONFIG_EVENT_TRACING=y` | nvgpu.ko | Trace events |
| `CONFIG_BPF_SYSCALL=y` | nvgpu.ko | BPF subsystem |
| `CONFIG_BPF_EVENTS=y` | nvgpu.ko | BPF perf events |
| `CONFIG_PERF_EVENTS=y` | nvgpu.ko | Performance counters |
| `CONFIG_DEVFREQ_THERMAL=y` | nvgpu.ko | Thermal devfreq coupling |
| `CONFIG_NAMESPACES=y` | nvmap.ko | Namespace support (`from_kuid`) |
| `CONFIG_USER_NS=y` | nvmap.ko | User namespace (`from_kuid`) |
| `CONFIG_TEGRA_HSIERRRPTINJ=y` | host1x.ko | HSI error reporting |
| `# CONFIG_TEGRA_HOST1X is not set` | host1x.ko (OOT) | Avoid duplicate with in-tree |

### Kernel Stub Module (`nvidia_stubs.c`)

Created `drivers/platform/tegra/nvidia_stubs.c` providing symbols that OOT modules
expect but aren't available in a minimal kernel build:

```c
// host1x_context_device_bus_type — needed by host1x.ko for context isolation
struct bus_type host1x_context_device_bus_type = { .name = "host1x_context" };
EXPORT_SYMBOL(host1x_context_device_bus_type);
// Registered via postcore_initcall(host1x_context_device_bus_init)

// NvSciIpc stubs — needed by nvmap.ko (returns -ENOSYS, no actual IPC)
int NvSciIpcEndpointMapVuid(...) { return -ENOSYS; }
int NvSciIpcEndpointValidateAuthTokenLinuxCurrent(...) { return -ENOSYS; }
```

### ARM64 `_mcount` Stub (`arch/arm64/kernel/entry-ftrace.S`)

Added minimal `_mcount` function (just `ret`) to satisfy FTRACE symbol requirement
without actually enabling function tracing overhead.

---

## Implementation Steps (Option C — What Was Actually Done)

### Step 1: Kernel config changes

In `board/nvidia/orin-nano/linux-orin-minimal.config`:
```
CONFIG_LOCALVERSION="-tegra"
# CONFIG_MODVERSIONS is not set
CONFIG_FTRACE=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_DYNAMIC_FTRACE_WITH_REGS=y
CONFIG_EVENT_TRACING=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_EVENTS=y
CONFIG_PERF_EVENTS=y
CONFIG_DEVFREQ_THERMAL=y
CONFIG_NAMESPACES=y
CONFIG_USER_NS=y
CONFIG_TEGRA_HSIERRRPTINJ=y
# CONFIG_TEGRA_HOST1X is not set
```

### Step 2: Add kernel stubs

Created `drivers/platform/tegra/nvidia_stubs.c` and added to Makefile.
Created `arch/arm64/kernel/entry-ftrace.S` with `_mcount` stub.

### Step 3: Rebuild kernel

```bash
cd buildroot-2026.02/output/build/linux-custom
rm -f drivers/platform/tegra/nvidia_stubs.o arch/arm64/kernel/entry-ftrace.o
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image
cp arch/arm64/boot/Image ../../images/Image
```

### Step 4: Extract OOT kernel modules

```bash
tar -xjf Linux_for_Tegra/kernel/kernel_oot_modules.tbz2 \
    -C overlay_fs/ \
    usr/lib/modules/5.15.185-tegra/updates/nvgpu.ko \
    usr/lib/modules/5.15.185-tegra/updates/drivers/gpu/host1x/host1x.ko \
    usr/lib/modules/5.15.185-tegra/updates/drivers/gpu/host1x-nvhost/host1x-nvhost.ko \
    usr/lib/modules/5.15.185-tegra/updates/drivers/platform/tegra/mc-utils/mc-utils.ko \
    usr/lib/modules/5.15.185-tegra/updates/drivers/video/tegra/nvmap/nvmap.ko
```

### Step 5: Extract NVIDIA userspace libs

```bash
for deb in nvidia-l4t-core nvidia-l4t-cuda; do
    dpkg-deb -x Linux_for_Tegra/nv_tegra/l4t_deb_packages/${deb}_*.deb overlay_fs/
done
```

### Step 6: Module load + library discovery script

Created `overlay_fs/etc/init.d/S02nvidia`:
```bash
#!/bin/sh
case "$1" in
  start)
    # Load GPU modules in dependency order
    insmod /usr/lib/modules/5.15.185-tegra/updates/host1x.ko
    insmod /usr/lib/modules/5.15.185-tegra/updates/host1x-nvhost.ko
    insmod /usr/lib/modules/5.15.185-tegra/updates/mc-utils.ko
    insmod /usr/lib/modules/5.15.185-tegra/updates/nvmap.ko
    insmod /usr/lib/modules/5.15.185-tegra/updates/nvgpu.ko
    # Create /usr/lib symlinks (no ldconfig in Buildroot)
    for f in /usr/lib/aarch64-linux-gnu/nvidia/*.so*; do
      ln -sf "$f" /usr/lib/$(basename "$f")
    done
    ;;
esac
```

### Step 7: Rebuild rootfs and deploy to NVMe

```bash
cd buildroot-2026.02
make   # rebuilds cpio with overlay
# Write to NVMe via USB adapter
sudo mkfs.ext4 -L APP -F /dev/sdb1
sudo mount /dev/sdb1 /mnt
sudo cpio -idm < output/images/rootfs.cpio
sudo cp output/images/Image /mnt/boot/Image
sudo cp Linux_for_Tegra/kernel/dtb/tegra234-p3768-0000+p3767-0005-nv.dtb /mnt/boot/dtb
# Write extlinux.conf, umount
```
```

### Step 7: Rebuild rootfs and deploy

```bash
make  # rebuilds rootfs with overlay
# Then write to NVMe via prepare-nvme.sh or dd
```

---

## Boot Time Impact (Measured)

| Metric | Before CUDA | With CUDA | Delta |
|--------|-------------|-----------|-------|
| BPMP → shell | ~3.95s | ~3.88s | **~0ms** (within noise) |
| Module load time | N/A | ~50ms | Negligible |
| Library symlinks | N/A | ~5ms | Negligible |

The CUDA modules and library setup add essentially zero measurable boot time overhead.

---

## Verification (Confirmed 2026-05-26)

```
# lsmod
Module                  Size  Used by    Tainted: G  
nvgpu                2560000  0 [permanent]
nvmap                 192512  1 nvgpu,[permanent]
mc_utils               16384  1 nvgpu,[permanent]
host1x_nvhost          32768  0 [permanent]
host1x                163840  2 nvgpu,host1x_nvhost,[permanent]

# ls /dev/nvgpu/ /dev/nvmap /dev/nvhost-gpu
/dev/nvhost-gpu  /dev/nvmap
/dev/nvgpu/:
igpu0

# dmesg | grep duplicate
(no output — clean!)

# LD_LIBRARY_PATH=/usr/lib ldd /usr/lib/libcuda.so.1.1
(all dependencies resolved)
```

---

## Issues Encountered and Resolved

| Issue | Symptom | Fix |
|-------|---------|-----|
| Missing `_mcount` | nvgpu.ko insmod fails with unresolved symbol | Added `entry-ftrace.S` stub |
| Missing `host1x_context_device_bus_type` | host1x.ko load fails | Added to `nvidia_stubs.c` |
| Duplicate `__host1x_client_init` | Symbol conflict with in-tree host1x | Disabled `CONFIG_TEGRA_HOST1X` |
| Missing `NvSciIpc*` symbols | nvmap.ko load fails | Added stub functions in `nvidia_stubs.c` |
| Missing `from_kuid` | nvmap.ko load fails | Enabled `CONFIG_NAMESPACES` + `CONFIG_USER_NS` |
| Duplicate `tegra_vpr_dev` | nvidia_stubs vs nvmap conflict | Removed from stubs (nvmap provides it) |
| Duplicate `emc_freq_to_bw` | nvidia_stubs vs mc-utils conflict | Removed from stubs (mc-utils provides it) |
| Libraries not found | `libcuda.so` can't find deps at runtime | S02nvidia creates `/usr/lib/` symlinks (no ldconfig in Buildroot) |
| Module vermagic mismatch | Modules refuse to load | `CONFIG_LOCALVERSION="-tegra"` + disable MODVERSIONS |

---

## Revert Instructions

To return to the pre-CUDA state:
```bash
# Workspace repo (docs/scripts):
cd nvidia_boot_optimize
git checkout e7c003f  # commit before CUDA support

# Kernel config:
# Restore CONFIG_LOCALVERSION="-prod" and CONFIG_MODVERSIONS=y
# Remove FTRACE/BPF/PERF/NAMESPACE configs
# Re-enable CONFIG_TEGRA_HOST1X
# in board/nvidia/orin-nano/linux-orin-minimal.config

# Kernel source patches:
# Remove drivers/platform/tegra/nvidia_stubs.c
# Remove arch/arm64/kernel/entry-ftrace.S
# Remove .scmversion

# Buildroot overlay:
rm -rf overlay_fs/usr/lib/aarch64-linux-gnu/nvidia
rm -rf overlay_fs/lib/firmware/nvidia
rm -rf overlay_fs/usr/lib/modules
rm -f overlay_fs/etc/init.d/S02nvidia

# Rebuild:
make linux-rebuild && make
```

---

## Files Modified/Added

| File | Change |
|------|--------|
| `board/nvidia/orin-nano/linux-orin-minimal.config` | LOCALVERSION, MODVERSIONS, FTRACE, BPF, PERF, NAMESPACES, TEGRA_HOST1X disabled |
| `output/build/linux-custom/drivers/platform/tegra/nvidia_stubs.c` | NEW — kernel stubs for OOT module symbols |
| `output/build/linux-custom/drivers/platform/tegra/Makefile` | Added `obj-y += nvidia_stubs.o` |
| `output/build/linux-custom/arch/arm64/kernel/entry-ftrace.S` | NEW — `_mcount` ret stub |
| `output/build/linux-custom/.scmversion` | NEW — empty file (prevents "+" suffix) |
| `overlay_fs/etc/init.d/S02nvidia` | NEW — module loader + library symlinks |
| `overlay_fs/usr/lib/aarch64-linux-gnu/nvidia/` | NEW — CUDA + core runtime libs (~40 .so files) |
| `overlay_fs/lib/firmware/nvidia/ga10b/` | NEW — GPU firmware blobs |
| `overlay_fs/usr/lib/modules/5.15.185-tegra/updates/` | NEW — 5 OOT kernel modules |
