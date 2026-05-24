#!/usr/bin/env bash
# apply-uefi-patches.sh — Apply UEFI/firmware boot time optimizations to L4T source
#
# This script patches the L4T UEFI source tree to:
#   - Remove unnecessary UEFI components (networking, SCSI, logo, shell)
#   - Set boot timeout to 0
#   - Disable MB1/MB2 logs
#   - Strip BPMP serial node
#
# Prerequisites:
#   - L4T BSP extracted (Linux_for_Tegra/)
#   - UEFI source available (edk2-nvidia)
#   - dtc (device tree compiler) installed

. "$(dirname "$0")/common.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────

L4T_DIR=""
UEFI_SRC=""
VERBOSE=false
DRY_RUN=false

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Apply UEFI/firmware boot time optimizations to L4T source tree.

Options:
  --l4t-dir PATH         Path to Linux_for_Tegra directory (required)
  --uefi-src PATH        Path to edk2-nvidia UEFI source (for component removal)
  --dry-run              Show what would be changed without modifying files
  --verbose              Show detailed output
  -h, --help             Show this help

Exit codes:
  0 - All patches applied successfully
  1 - Patch application failed
  2 - Required files/directories not found
EOF
}

# ─── Parse Arguments ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --l4t-dir)   L4T_DIR="$2"; shift 2 ;;
        --uefi-src)  UEFI_SRC="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --verbose)   VERBOSE=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "Unknown option: $1" "Run with --help for usage" ;;
    esac
done

# ─── Validation ──────────────────────────────────────────────────────────────

if [[ -z "$L4T_DIR" ]]; then
    die "--l4t-dir is required" "Provide path to Linux_for_Tegra directory"
fi
require_dir "$L4T_DIR" "Linux_for_Tegra directory"

PATCH_COUNT=0
FAIL_COUNT=0

apply_patch() {
    local desc="$1"
    local status="$2"  # "ok" or "fail"
    if [[ "$status" == "ok" ]]; then
        PATCH_COUNT=$((PATCH_COUNT + 1))
        log_info "✓ $desc"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log_error "✗ $desc"
    fi
}

# ─── 1. Disable MB1/MB2 Logs ────────────────────────────────────────────────

log_info "=== Applying firmware patches ==="

MB1_BCT="${L4T_DIR}/bootloader/tegra234-mb1-bct-misc-common.dtsi"
if [[ -f "$MB1_BCT" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would set log_level=0 in $MB1_BCT"
        apply_patch "MB1/MB2 log_level → 0" "ok"
    else
        if sed -i 's/log_level = <[0-9]*>/log_level = <0>/g' "$MB1_BCT"; then
            apply_patch "MB1/MB2 log_level → 0 in $MB1_BCT" "ok"
        else
            apply_patch "MB1/MB2 log_level patch" "fail"
        fi
    fi
else
    log_warn "MB1 BCT not found: $MB1_BCT (skipping)"
fi

# ─── 2. Strip BPMP Serial Node ──────────────────────────────────────────────

log_info "=== Applying BPMP serial strip ==="

BPMP_DTB="${L4T_DIR}/bootloader/t186ref/tegra234-bpmp-3767-0000-a02-3509-a02.dtb"
if [[ -f "$BPMP_DTB" ]]; then
    require_cmd dtc
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would strip /serial node in $BPMP_DTB"
        apply_patch "BPMP serial node strip" "ok"
    else
        BPMP_DTS="/tmp/bpmp-temp.dts"
        # Decompile
        if dtc -I dtb -O dts -o "$BPMP_DTS" "$BPMP_DTB" 2>/dev/null; then
            # Empty the serial node contents (keep node, remove children/properties)
            if sed -i '/^\tserial {/,/^\t};/{/^\tserial {/!{/^\t};/!d}}' "$BPMP_DTS"; then
                # Recompile
                if dtc -I dts -O dtb -o "$BPMP_DTB" "$BPMP_DTS" 2>/dev/null; then
                    apply_patch "BPMP serial node stripped in $BPMP_DTB" "ok"
                else
                    apply_patch "BPMP DTB recompile" "fail"
                fi
            else
                apply_patch "BPMP serial node sed" "fail"
            fi
        else
            apply_patch "BPMP DTB decompile" "fail"
        fi
        rm -f "$BPMP_DTS"
    fi
else
    log_warn "BPMP DTB not found: $BPMP_DTB (skipping — may have different filename for your L4T version)"
fi

# ─── 3. Set UEFI Timeout to 0 ───────────────────────────────────────────────

log_info "=== Applying UEFI timeout patch ==="

if [[ -n "$UEFI_SRC" ]] && [[ -d "$UEFI_SRC" ]]; then
    DSC_FILE=$(find "$UEFI_SRC" -name "NVIDIA.common.dsc.inc" -print -quit 2>/dev/null)
    if [[ -n "$DSC_FILE" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY RUN] Would set PcdPlatformBootTimeOut=0 in $DSC_FILE"
            apply_patch "UEFI timeout → 0" "ok"
        else
            if sed -i 's/PcdPlatformBootTimeOut|L"Timeout"|gEfiGlobalVariableGuid|0x0|[0-9]*/PcdPlatformBootTimeOut|L"Timeout"|gEfiGlobalVariableGuid|0x0|0/' "$DSC_FILE"; then
                apply_patch "UEFI timeout → 0 in $DSC_FILE" "ok"
            else
                apply_patch "UEFI timeout patch" "fail"
            fi
        fi
    else
        log_warn "NVIDIA.common.dsc.inc not found in $UEFI_SRC"
    fi
else
    log_warn "UEFI source not provided (--uefi-src). Timeout patch skipped."
    log_info "  To apply manually: set PcdPlatformBootTimeOut to 0 in NVIDIA.common.dsc.inc"
fi

# ─── 4. Remove UEFI Components ──────────────────────────────────────────────

log_info "=== Applying UEFI component removals ==="

REMOVALS_FILE="${CONFIG_DIR}/bootloader/uefi-removals.txt"
if [[ -n "$UEFI_SRC" ]] && [[ -d "$UEFI_SRC" ]] && [[ -f "$REMOVALS_FILE" ]]; then
    # Find all .dsc.inc and .fdf.inc files to patch
    DSC_FILES=$(find "$UEFI_SRC" -name "*.dsc.inc" -o -name "*.fdf.inc" -o -name "*.fdf" -o -name "*.dsc" 2>/dev/null | grep -i "nvidia\|jetson")
    
    REMOVED=0
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        
        # Extract component path (after [category] prefix)
        COMPONENT=$(echo "$line" | sed 's/^\[.*\] *//')
        [[ -z "$COMPONENT" ]] && continue

        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY RUN] Would remove: $COMPONENT"
            REMOVED=$((REMOVED + 1))
        else
            # Comment out the component in all relevant files
            for f in $DSC_FILES; do
                if grep -q "$COMPONENT" "$f" 2>/dev/null; then
                    sed -i "s|.*${COMPONENT}.*|# REMOVED for boot optimization: &|" "$f"
                    REMOVED=$((REMOVED + 1))
                    [[ "$VERBOSE" == true ]] && log_info "  Removed $COMPONENT from $(basename "$f")"
                fi
            done
        fi
    done < "$REMOVALS_FILE"

    if [[ $REMOVED -gt 0 ]]; then
        apply_patch "Removed $REMOVED UEFI component references" "ok"
    else
        log_warn "No UEFI components found to remove (files may already be patched)"
    fi
else
    if [[ -z "$UEFI_SRC" ]]; then
        log_warn "UEFI source not provided. Component removal skipped."
        log_info "  See config/bootloader/uefi-removals.txt for manual removal list."
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

log_info "=== Patch Summary ==="
log_info "Applied: $PATCH_COUNT patches"
if [[ $FAIL_COUNT -gt 0 ]]; then
    log_error "Failed: $FAIL_COUNT patches"
    exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
    log_info "(Dry run — no files were modified)"
fi

log_info "Next steps:"
log_info "  1. Build UEFI firmware (if source patches applied)"
log_info "  2. Flash to device: scripts/flash-optimized.sh --l4t-dir $L4T_DIR"
log_info "  3. Measure: scripts/measure-boot-time.sh"
exit 0
