#!/usr/bin/env bash
# Orchestrate the UEFI ↔ FFA ↔ SP ↔ MCTP/serial ↔ EC E2E test
#
# SPDX-License-Identifier: MIT
#
# Combines the dual-QEMU + PTY-bridge flow from test-serial.sh with the
# vdrive + UEFI shell autoload from test-e2e.sh. Verifies the contract-
# locked marker
#
#   EC_MCTP_OK service_id=8 msg_id=GetBst
#
# appears in the SBSA serial log after ec-battery.efi runs. Existing
# scripts/test-serial.sh and scripts/test-e2e.sh are UNTOUCHED so the
# FFA-only `make e2e-test` flow continues to pass.
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

# Contract-locked marker prefix (HARNESS-02, D-37-02). The ec-battery.efi
# test app emits the full marker as
#   EC_MCTP_OK service_id=8 msg_id=GetBst battery_status=<hex>
# We grep the fixed prefix via `grep -F` (no regex).
MARKER='EC_MCTP_OK service_id=8 msg_id=GetBst'

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

require_arg() {
    [ -n "$2" ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ec-elf)       require_arg "$1" "${2-}"; EC_ELF="$2"; shift 2 ;;
        --bios-fv-dir)  require_arg "$1" "${2-}"; BIOS_FV_DIR="$2"; shift 2 ;;
        --build-dir)    require_arg "$1" "${2-}"; BUILD_DIR="$2"; shift 2 ;;
        --vdrive-dir)   require_arg "$1" "${2-}"; VDRIVE_DIR="$2"; shift 2 ;;
        --ec-timeout)   require_arg "$1" "${2-}"; EC_TIMEOUT="$2"; shift 2 ;;
        --sbsa-timeout) require_arg "$1" "${2-}"; SBSA_TIMEOUT="$2"; shift 2 ;;
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

# Timeout validation — same rationale as test-serial.sh: start_ec_qemu
# interpolates $timeout_s into an inner `bash -c` string via setsid, so
# non-numeric input would risk command injection. The orchestrator gates.
case "$EC_TIMEOUT" in
    ''|*[!0-9]*|0) echo "ERROR: --ec-timeout must be a positive integer (got: $EC_TIMEOUT)" >&2; exit 1 ;;
esac
case "$SBSA_TIMEOUT" in
    ''|*[!0-9]*|0) echo "ERROR: --sbsa-timeout must be a positive integer (got: $SBSA_TIMEOUT)" >&2; exit 1 ;;
esac

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

SWTPM_STATE="$BUILD_DIR/swtpm-state"
SWTPM_SOCK="$SWTPM_STATE/swtpm-sock"
SWTPM_LOG="$BUILD_DIR/swtpm.log"
EC_OUT_LOG="$BUILD_DIR/ec-qemu-stdout.log"
EC_ERR_LOG="$BUILD_DIR/ec-qemu-stderr.log"
EC_SERIAL_LOG="$BUILD_DIR/ec-serial-output.log"
SBSA_SERIAL_LOG="$BUILD_DIR/sbsa-serial-output.log"

EC_PID=""
SWTPM_PID=""

# See test-serial.sh::kill_ec_session for the rationale on
# `pkill -s` over `kill -- -$EC_PID`.
kill_ec_session() {
    [ -n "$EC_PID" ] || return 0
    pkill -TERM -s "$EC_PID" 2>/dev/null
    kill -- "-$EC_PID" 2>/dev/null
    wait "$EC_PID" 2>/dev/null
}

# shellcheck disable=SC2329  # invoked via `trap ... EXIT` below
cleanup() {
    # shellcheck disable=SC2317
    kill_ec_session
    # shellcheck disable=SC2317
    if [ -n "$SWTPM_PID" ]; then
        kill "$SWTPM_PID" 2>/dev/null
        wait "$SWTPM_PID" 2>/dev/null
    fi
    # shellcheck disable=SC2317
    true
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR" "$SWTPM_STATE"
rm -f "$EC_OUT_LOG" "$EC_ERR_LOG" "$EC_SERIAL_LOG" "$SBSA_SERIAL_LOG" "$SWTPM_SOCK"

# 1. swtpm
start_swtpm "$SWTPM_STATE" "$SWTPM_SOCK" "$SWTPM_LOG"
wait_for_swtpm_socket "$SWTPM_SOCK" || {
    echo "--- swtpm log ($SWTPM_LOG) ---" >&2
    cat "$SWTPM_LOG" >&2 2>/dev/null || echo "(empty or missing)" >&2
    echo "--- end swtpm log ---" >&2
    exit 1
}

# 2. EC QEMU + PTY discovery (same as test-serial.sh)
start_ec_qemu "$EC_ELF" "$EC_OUT_LOG" "$EC_ERR_LOG" "$EC_SERIAL_LOG" "$EC_TIMEOUT"
PTY=$(discover_ec_pty "$EC_OUT_LOG" "$EC_ERR_LOG") || exit 1
echo "EC PTY: $PTY — launching SBSA QEMU with vdrive $VDRIVE_DIR"

# 3. SBSA QEMU
# Differences from test-serial.sh:
#   - Mounts the VDRIVE_DIR via `-drive file=fat:rw:...` so the UEFI shell's
#     startup.nsh autoloads ec-battery.efi (matches test-e2e.sh's pattern).
#   - serial0 captures UEFI console (where ec-battery.efi log lands —
#     the marker source).
#   - serial1 bridges to the EC PTY (the MCTP path).
SBSA_EXIT=0
timeout "$SBSA_TIMEOUT" \
    qemu-system-aarch64 \
        "$@" \
        -drive "if=pflash,format=raw,unit=0,file=$BIOS_FV_DIR/SECURE_FLASH0.fd" \
        -drive "if=pflash,format=raw,unit=1,file=$BIOS_FV_DIR/QEMU_EFI.fd,readonly=on" \
        -chardev "socket,id=chrtpm,path=$SWTPM_SOCK" \
        -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
        -chardev "serial,id=ec-link,path=$PTY" \
        -serial "file:$SBSA_SERIAL_LOG" \
        -serial "chardev:ec-link" \
        -drive "file=fat:rw:$VDRIVE_DIR,format=raw,media=disk" \
        -display none \
        -no-reboot \
    || SBSA_EXIT=$?

# 4. SBSA failure short-circuits before verification.
if [ "$SBSA_EXIT" -ne 0 ]; then
    echo "SBSA QEMU exited with code $SBSA_EXIT" >&2
    echo "--- SBSA serial log tail ---" >&2
    tail -40 "$SBSA_SERIAL_LOG" 2>/dev/null >&2 || echo "(empty or missing)" >&2
    echo "--- end SBSA serial log ---" >&2
    exit "$SBSA_EXIT"
fi

# 5. Tear down the EC pipeline BEFORE verification so block-buffered
# defmt-print output is fully flushed. Clear EC_PID so the EXIT trap
# below doesn't try to tear it down a second time.
kill_ec_session
EC_PID=""

# 6. Verification — grep -F for the fixed prefix (no regex).
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
