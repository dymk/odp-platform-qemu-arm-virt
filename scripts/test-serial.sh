#!/usr/bin/env bash
# Orchestrate the EC ↔ SBSA serial-link test
#
# SPDX-License-Identifier: MIT
#
# Owns the long-lived child processes (swtpm + EC QEMU + SBSA QEMU),
# sets up the cleanup trap, and performs post-run verification. Most of
# the orchestration logic lives in lib/dual-qemu-harness.sh; this script
# is the thin wrapper that parses args and defines the verification
# (grep for the EC boot string in EC_SERIAL_LOG, plus a non-empty check
# on SBSA_SERIAL_LOG).
#
# Run `test-serial.sh --help` for usage. Must be executed inside the
# odp-platform-qemu-sbsa devcontainer (requires swtpm, qemu-system-riscv32,
# qemu-system-aarch64, defmt-print, stdbuf, setsid, timeout, pkill on PATH).

set -o pipefail
# Intentionally NOT `set -e`: we use `cmd || EXIT=$?` patterns and the v1.1
# hardening cycle showed -e interferes with timeout(1) exit handling.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/swtpm.sh
source "$SCRIPT_DIR/lib/swtpm.sh"
# shellcheck source=lib/ec-qemu.sh
source "$SCRIPT_DIR/lib/ec-qemu.sh"
# shellcheck source=lib/dual-qemu-harness.sh
source "$SCRIPT_DIR/lib/dual-qemu-harness.sh"

usage() {
    cat <<'EOF'
Usage: test-serial.sh --ec-elf PATH --bios-fv-dir DIR --build-dir DIR \
                      [--ec-timeout N] [--sbsa-timeout N] -- <qemu-common-args...>

  --ec-elf        EC firmware ELF (riscv32)
  --bios-fv-dir   Directory containing SECURE_FLASH0.fd and QEMU_EFI.fd
  --build-dir     Build/ directory (logs and swtpm-state live here)
  --ec-timeout    Seconds for EC QEMU run (default: 30)
  --sbsa-timeout  Seconds for SBSA QEMU run (default: 60)
  --              Everything after this is forwarded verbatim to
                  qemu-system-aarch64 as the SBSA common args (machine,
                  cpu, mem, smbios, etc.)

Must run inside the odp-platform-qemu-sbsa devcontainer.

Exits 0 on PASS, non-zero on FAILURE. The first failure mode wins:
  - Setup error (swtpm socket / EC PTY discovery) -> exits 1
  - SBSA QEMU non-zero exit -> exits with that code (verification skipped)
  - EC boot string missing  -> exits 1 (after SBSA succeeded)
EOF
    exit "${1:-0}"
}

EC_ELF=""
BIOS_FV_DIR=""
BUILD_DIR=""
EC_TIMEOUT=30
SBSA_TIMEOUT=60

while [ $# -gt 0 ]; do
    case "$1" in
        --ec-elf)       harness_require_arg "$1" "${2-}"; EC_ELF="$2"; shift 2 ;;
        --bios-fv-dir)  harness_require_arg "$1" "${2-}"; BIOS_FV_DIR="$2"; shift 2 ;;
        --build-dir)    harness_require_arg "$1" "${2-}"; BUILD_DIR="$2"; shift 2 ;;
        --ec-timeout)   harness_require_arg "$1" "${2-}"; EC_TIMEOUT="$2"; shift 2 ;;
        --sbsa-timeout) harness_require_arg "$1" "${2-}"; SBSA_TIMEOUT="$2"; shift 2 ;;
        -h|--help)      usage 0 ;;
        --)             shift; break ;;
        *)              echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done
# Remaining "$@" is the SBSA QEMU common args (smbios, machine, cpu, etc.)

if [ -z "$EC_ELF" ] || [ -z "$BIOS_FV_DIR" ] || [ -z "$BUILD_DIR" ]; then
    echo "ERROR: --ec-elf, --bios-fv-dir, and --build-dir are required" >&2
    usage 1
fi

harness_validate_timeouts

# Mount the test-serial vdrive (existing behaviour; the FFA-only flow uses
# this drive for the original startup.nsh).
EXTRA_QEMU_ARGS=( -drive "file=fat:rw:test-serial-vdrive,format=raw,media=disk" )

harness_setup_paths
harness_install_cleanup
harness_start_services
echo "EC PTY: $PTY — launching SBSA QEMU"

harness_run_sbsa "$@"

# SBSA failure short-circuits before verification (matches original recipe).
if [ "$HARNESS_SBSA_EXIT" -ne 0 ]; then
    echo "SBSA QEMU exited with code $HARNESS_SBSA_EXIT" >&2
    exit "$HARNESS_SBSA_EXIT"
fi

# Flush the EC pipeline before grepping EC_SERIAL_LOG (the original
# Makefile recipe got this for free via subshell EXIT-trap ordering).
harness_shutdown_ec

# Verification (only on SBSA success).
PASS=true
if grep -q "Starting uart service" "$EC_SERIAL_LOG" 2>/dev/null; then
    echo "EC: boot successful (PTY serial backend)"
else
    echo "=== EC serial output ==="
    cat "$EC_SERIAL_LOG" 2>/dev/null || echo "(empty)"
    echo "=== End EC serial output ==="
    echo "EC: boot FAILED — 'Starting uart service' not found"
    PASS=false
fi

if [ -s "$SBSA_SERIAL_LOG" ]; then
    echo "SBSA: produced serial output (PTY connected)"
else
    echo "SBSA: WARNING — no serial output captured (may be OK if boot is slow)"
fi

if "$PASS"; then
    echo "RESULT: SERIAL LINK TEST PASSED"
    exit 0
else
    echo "RESULT: SERIAL LINK TEST FAILED"
    exit 1
fi
