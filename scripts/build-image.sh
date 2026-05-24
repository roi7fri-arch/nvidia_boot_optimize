#!/usr/bin/env bash
# build-image.sh — Build optimized image using Buildroot

. "$(dirname "$0")/common.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────

BR_DIR="$BUILDROOT_DIR"
DEFCONFIG="$BUILDROOT_DEFCONFIG"
KERNEL_FRAGMENT=""
JOBS=$(nproc)
CLEAN=false
VERBOSE=false

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build the optimized image using Buildroot.

Options:
  --buildroot-dir PATH   Path to buildroot tree (default: $BUILDROOT_DIR)
  --defconfig NAME       Buildroot defconfig to use (default: $BUILDROOT_DEFCONFIG)
  --kernel-fragment PATH Additional kernel config fragment to merge
  --jobs N               Parallel build jobs (default: $(nproc))
  --clean                Run make clean before building
  --verbose              Show full build output
  -h, --help             Show this help

Exit codes:
  0 - Build completed successfully
  1 - Build failed
  2 - Buildroot directory not found
  3 - Defconfig not found
EOF
}

# ─── Parse Arguments ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --buildroot-dir)    BR_DIR="$2"; shift 2 ;;
        --defconfig)        DEFCONFIG="$2"; shift 2 ;;
        --kernel-fragment)  KERNEL_FRAGMENT="$2"; shift 2 ;;
        --jobs)             JOBS="$2"; shift 2 ;;
        --clean)            CLEAN=true; shift ;;
        --verbose)          VERBOSE=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) die "Unknown option: $1" "Run with --help for usage" ;;
    esac
done

# ─── Validation ──────────────────────────────────────────────────────────────

require_dir "$BR_DIR" "Buildroot directory"

if [[ ! -f "${BR_DIR}/configs/${DEFCONFIG}" ]]; then
    die "Defconfig not found: ${BR_DIR}/configs/${DEFCONFIG}" \
        "Available configs: ls ${BR_DIR}/configs/ | grep orin"
fi

if [[ -n "$KERNEL_FRAGMENT" ]]; then
    require_file "$KERNEL_FRAGMENT" "Kernel config fragment"
fi

# ─── Merge Kernel Fragment ───────────────────────────────────────────────────

if [[ -n "$KERNEL_FRAGMENT" ]]; then
    log_info "Merging kernel config fragment: $KERNEL_FRAGMENT"
    KCONFIG="${BR_DIR}/board/nvidia/orin-nano/linux-orin-minimal.config"

    if [[ ! -f "$KCONFIG" ]]; then
        die "Kernel config not found: $KCONFIG"
    fi

    # Use scripts/merge_config.sh from kernel source if available,
    # otherwise manually append fragment (buildroot handles merge via BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES)
    # For now, we configure buildroot to use the fragment
    log_info "Fragment will be applied via buildroot kernel config fragment mechanism"

    # Check if BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES is already set
    BR_CONFIG="${BR_DIR}/configs/${DEFCONFIG}"
    if ! grep -q "BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES" "$BR_CONFIG"; then
        log_info "Adding fragment to buildroot defconfig..."
        echo "BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=\"${KERNEL_FRAGMENT}\"" >> "$BR_CONFIG"
    else
        log_info "Updating fragment path in buildroot defconfig..."
        sed -i "s|BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=.*|BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=\"${KERNEL_FRAGMENT}\"|" "$BR_CONFIG"
    fi
fi

# ─── Build ───────────────────────────────────────────────────────────────────

cd "$BR_DIR"

if [[ "$CLEAN" == true ]]; then
    log_info "Cleaning build..."
    make clean
fi

log_info "Loading defconfig: $DEFCONFIG"
make "${DEFCONFIG}" 2>&1 | tail -5

log_info "Building (jobs=$JOBS)..."
BUILD_START=$(millis_now)

if [[ "$VERBOSE" == true ]]; then
    make -j"$JOBS" 2>&1
else
    make -j"$JOBS" > /tmp/buildroot-build.log 2>&1
fi

BUILD_EXIT=$?
BUILD_END=$(millis_now)
BUILD_DURATION=$(( (BUILD_END - BUILD_START) / 1000 ))

if [[ $BUILD_EXIT -ne 0 ]]; then
    log_error "Build failed after ${BUILD_DURATION}s (exit code: $BUILD_EXIT)"
    if [[ "$VERBOSE" == false ]]; then
        log_error "Last 30 lines of build log:"
        tail -30 /tmp/buildroot-build.log >&2
    fi
    exit 1
fi

log_info "Build completed in ${BUILD_DURATION}s"

# ─── Report Artifacts ────────────────────────────────────────────────────────

log_info "Built artifacts:"
KERNEL_IMG="${BUILDROOT_IMAGES}/Image"
ROOTFS_EXT4="${BUILDROOT_IMAGES}/rootfs.ext4"
ROOTFS_CPIO="${BUILDROOT_IMAGES}/rootfs.cpio"

[[ -f "$KERNEL_IMG" ]]   && log_info "  kernel: $KERNEL_IMG"
[[ -f "$ROOTFS_EXT4" ]]  && log_info "  rootfs: $ROOTFS_EXT4"
[[ -f "$ROOTFS_CPIO" ]]  && log_info "  initramfs: $ROOTFS_CPIO"

# Find DTB
DTB=$(find "$BUILDROOT_IMAGES" -name "tegra234*.dtb" -print -quit 2>/dev/null)
[[ -n "$DTB" ]] && log_info "  dtb: $DTB"

exit 0
