#!/usr/bin/env bash
# Orchestrate the UEFI ↔ FFA ↔ SP ↔ MCTP/serial ↔ EC E2E test
#
# SPDX-License-Identifier: MIT
#
# Thin wrapper over lib/dual-qemu-harness.sh: same dual-QEMU + PTY-bridge
# orchestration as test-serial.sh, with two additions:
#   - --vdrive-dir flag (mounts the UEFI test EFI's FAT drive)
#   - verification = grep for the EC_MCTP_OK marker in SBSA_SERIAL_LOG
#     (instead of the EC boot string in EC_SERIAL_LOG).
#
# Existing scripts/test-serial.sh and scripts/test-e2e.sh are UNTOUCHED so
# the FFA-only `make e2e-test` flow continues to pass.
#
# Run `test-e2e-mctp.sh --help` for usage. Must be executed inside the
# odp-platform-qemu-sbsa devcontainer (requires swtpm, qemu-system-riscv32,
# qemu-system-aarch64, defmt-print, stdbuf, setsid, timeout, pkill on PATH).

set -o pipefail
# Intentionally NOT `set -e`: we use `cmd || EXIT=$?` patterns; see
# test-serial.sh for the v1.1 hardening rationale.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/swtpm.sh
source "$SCRIPT_DIR/lib/swtpm.sh"
# shellcheck source=lib/ec-qemu.sh
source "$SCRIPT_DIR/lib/ec-qemu.sh"
# shellcheck source=lib/dual-qemu-harness.sh
source "$SCRIPT_DIR/lib/dual-qemu-harness.sh"

# Contract-locked PASS marker prefix. Single source of truth:
#   e2e-tests/test-support/src/lib.rs::EC_MCTP_OK_MARKER_PREFIX
# Extract at run time via sed so the script and the test EFI can never
# drift. The full emitted log line is `<prefix> battery_status=<hex>`.
MARKER_SRC="$SCRIPT_DIR/../e2e-tests/test-support/src/lib.rs"
MARKER=$(sed -n 's/^pub const EC_MCTP_OK_MARKER_PREFIX: &str = "\(.*\)";$/\1/p' "$MARKER_SRC")
if [ -z "$MARKER" ]; then
    echo "ERROR: failed to extract EC_MCTP_OK_MARKER_PREFIX from $MARKER_SRC" >&2
    echo "       (did the const declaration change shape?)" >&2
    exit 1
fi

usage() {
    cat <<'EOF'
Usage: test-e2e-mctp.sh --ec-elf PATH --bios-fv-dir DIR --build-dir DIR \
                        --vdrive-dir DIR \
                        [--ec-timeout N] [--sbsa-timeout N] \
                        -- <qemu-common-args...>

  --ec-elf        EC firmware ELF (riscv32)
  --bios-fv-dir   Directory containing SECURE_FLASH0.fd and QEMU_EFI.fd
  --build-dir     Build/ directory (logs and swtpm-state live here)
  --vdrive-dir    FAT drive directory containing ec-battery.efi + startup.nsh
                  (typically e2e-tests/Build/vdrive-mctp/, populated by the
                  e2e-tests Makefile `test-mctp` target)
  --ec-timeout    Seconds for EC QEMU run (default: 30)
  --sbsa-timeout  Seconds for SBSA QEMU run (default: 120)
  --              Everything after this is forwarded verbatim to
                  qemu-system-aarch64 as the SBSA common args (machine,
                  cpu, mem, smbios, etc. — typically $(QEMU_COMMON_ARGS)
                  from Common.mk)

Exits 0 on PASS (marker present, SBSA exit 0), non-zero on FAILURE.
First failure mode wins:
  - Setup error (swtpm socket / EC PTY discovery) -> exits 1
  - SBSA QEMU non-zero exit                       -> exits with that code
  - EC_MCTP_OK marker missing                     -> exits 1
EOF
    exit "${1:-0}"
}

EC_ELF=""
BIOS_FV_DIR=""
BUILD_DIR=""
VDRIVE_DIR=""
EC_TIMEOUT=30
SBSA_TIMEOUT=120

while [ $# -gt 0 ]; do
    case "$1" in
        --ec-elf)       harness_require_arg "$1" "${2-}"; EC_ELF="$2"; shift 2 ;;
        --bios-fv-dir)  harness_require_arg "$1" "${2-}"; BIOS_FV_DIR="$2"; shift 2 ;;
        --build-dir)    harness_require_arg "$1" "${2-}"; BUILD_DIR="$2"; shift 2 ;;
        --vdrive-dir)   harness_require_arg "$1" "${2-}"; VDRIVE_DIR="$2"; shift 2 ;;
        --ec-timeout)   harness_require_arg "$1" "${2-}"; EC_TIMEOUT="$2"; shift 2 ;;
        --sbsa-timeout) harness_require_arg "$1" "${2-}"; SBSA_TIMEOUT="$2"; shift 2 ;;
        -h|--help)      usage 0 ;;
        --)             shift; break ;;
        *)              echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done
# Remaining "$@" is the SBSA QEMU common args (smbios, machine, cpu, etc.).

if [ -z "$EC_ELF" ] || [ -z "$BIOS_FV_DIR" ] || [ -z "$BUILD_DIR" ] || [ -z "$VDRIVE_DIR" ]; then
    echo "ERROR: --ec-elf, --bios-fv-dir, --build-dir, and --vdrive-dir are required" >&2
    usage 1
fi

harness_validate_timeouts

if [ ! -d "$VDRIVE_DIR" ]; then
    echo "ERROR: --vdrive-dir does not exist: $VDRIVE_DIR" >&2
    exit 1
fi
if [ ! -f "$VDRIVE_DIR/ec-battery.efi" ]; then
    echo "ERROR: ec-battery.efi missing from vdrive: $VDRIVE_DIR/ec-battery.efi" >&2
    exit 1
fi
if [ ! -f "$VDRIVE_DIR/startup.nsh" ]; then
    echo "ERROR: startup.nsh missing from vdrive: $VDRIVE_DIR/startup.nsh" >&2
    exit 1
fi

# Mount the vdrive so the UEFI shell's startup.nsh autoloads ec-battery.efi
# (matches test-e2e.sh's pattern).
EXTRA_QEMU_ARGS=( -drive "file=fat:rw:$VDRIVE_DIR,format=raw,media=disk" )

harness_setup_paths
harness_install_cleanup
harness_start_services
echo "EC PTY: $PTY — launching SBSA QEMU with vdrive $VDRIVE_DIR"

harness_run_sbsa "$@"

# SBSA failure short-circuits before verification.
if [ "$HARNESS_SBSA_EXIT" -ne 0 ]; then
    echo "SBSA QEMU exited with code $HARNESS_SBSA_EXIT" >&2
    echo "--- SBSA serial log tail ---" >&2
    tail -40 "$SBSA_SERIAL_LOG" 2>/dev/null >&2 || echo "(empty or missing)" >&2
    echo "--- end SBSA serial log ---" >&2
    exit "$HARNESS_SBSA_EXIT"
fi

harness_shutdown_ec

# Verification — grep -F for the fixed prefix (no regex).
if grep -qF "$MARKER" "$SBSA_SERIAL_LOG" 2>/dev/null; then
    matched=$(grep -F "$MARKER" "$SBSA_SERIAL_LOG" | head -1)
    echo "RESULT: MCTP E2E TEST PASSED"
    echo "  matched: $matched"
    exit 0
fi

echo "=== SBSA serial output ==="
cat "$SBSA_SERIAL_LOG" 2>/dev/null || echo "(empty)"
echo "=== End SBSA serial output ==="
echo "RESULT: MCTP E2E TEST FAILED — marker not found"
echo "  expected prefix: $MARKER"
exit 1
