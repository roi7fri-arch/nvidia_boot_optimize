#!/usr/bin/env bash
# common.sh — Shared constants and utility functions for boot optimization scripts
# Source this file: . "$(dirname "$0")/common.sh"

set -euo pipefail

# ─── Constants ───────────────────────────────────────────────────────────────

readonly BUILDROOT_DIR="/media/roifr/482a837d-d424-44cd-9783-464d9403e86e/buildroot-2026.02"
readonly BUILDROOT_DEFCONFIG="orin_nano_serial_defconfig"
readonly BUILDROOT_OUTPUT="${BUILDROOT_DIR}/output"
readonly BUILDROOT_IMAGES="${BUILDROOT_OUTPUT}/images"
readonly KERNEL_CONFIG_PATH="${BUILDROOT_DIR}/board/nvidia/orin-nano/linux-orin-minimal.config"

readonly SERIAL_PORT="/dev/ttyUSB0"
readonly SERIAL_BAUD=115200
readonly TARGET_BOOT_MS=8000
readonly TARGET_PRELINUX_MS=5000

readonly SHELL_PROMPT="/ #"
readonly KERNEL_START_MARKER="Booting Linux"

# Project paths (relative to repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CONFIG_DIR="${REPO_ROOT}/config"
readonly SCRIPTS_DIR="${REPO_ROOT}/scripts"
readonly TESTS_DIR="${REPO_ROOT}/tests"

# ─── Utility Functions ───────────────────────────────────────────────────────

# Print timestamped message to stdout
log_info() {
    printf "[%s] INFO: %s\n" "$(date '+%H:%M:%S')" "$*"
}

# Print timestamped error to stderr
log_error() {
    printf "[%s] ERROR: %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}

# Print timestamped warning to stderr
log_warn() {
    printf "[%s] WARN: %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}

# Exit with error message and suggested action
die() {
    local msg="$1"
    local suggestion="${2:-}"
    log_error "$msg"
    if [[ -n "$suggestion" ]]; then
        printf "  Suggestion: %s\n" "$suggestion" >&2
    fi
    exit 1
}

# Check that a required command exists
require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        die "Required command '$cmd' not found" "Install it or add to PATH"
    fi
}

# Check that a file exists
require_file() {
    local path="$1"
    local desc="${2:-file}"
    if [[ ! -f "$path" ]]; then
        die "$desc not found: $path" "Check path or regenerate the file"
    fi
}

# Check that a directory exists
require_dir() {
    local path="$1"
    local desc="${2:-directory}"
    if [[ ! -d "$path" ]]; then
        die "$desc not found: $path" "Check path or create the directory"
    fi
}

# Check serial port is accessible
check_serial_port() {
    local port="${1:-$SERIAL_PORT}"
    if [[ ! -c "$port" ]]; then
        die "Serial port $port not found" "Check USB connection or run: ls /dev/ttyUSB*"
    fi
    if [[ ! -r "$port" ]] || [[ ! -w "$port" ]]; then
        die "No read/write permission on $port" "Run: sudo usermod -aG dialout \$USER && newgrp dialout"
    fi
}

# Prompt user for NVMe SSD insertion
prompt_nvme_insert() {
    log_info "╔══════════════════════════════════════════════════════════╗"
    log_info "║  ACTION REQUIRED: Please insert NVMe SSD in M.2 adapter ║"
    log_info "║  Connect the M.2 adapter to this host PC via USB        ║"
    log_info "╚══════════════════════════════════════════════════════════╝"
    read -rp "Press Enter when NVMe SSD is connected to host... "
}

# Prompt user to put NVMe back in device
prompt_nvme_return() {
    log_info "╔══════════════════════════════════════════════════════════╗"
    log_info "║  ACTION REQUIRED: Please return NVMe SSD to the device  ║"
    log_info "║  Remove from M.2 adapter and insert into Orin Nano      ║"
    log_info "╚══════════════════════════════════════════════════════════╝"
    read -rp "Press Enter when NVMe SSD is back in the device... "
}

# Get milliseconds since epoch
millis_now() {
    date +%s%3N
}
