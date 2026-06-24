#!/usr/bin/env bash
# Orchestrate the two-QEMU thermal E2E test (host SP ↔ EC over MCTP/PL011).
#
# SPDX-License-Identifier: MIT
#
# Owns the EC sidecar lifecycle (RISC-V QEMU + PTY discovery) and
# delegates host QEMU launch + result classification to
# scripts/lib/host-qemu.sh::run_host_efi_and_parse_results. The
# previous incarnation was a serial-link smoke test; this rewrite
# asserts that the EC actually originated the response (DeciKelvin
# range, [PASS] line) via the unified runner.
#
# Run `test-sp-ec-link.sh --help` for usage. Must be executed inside the
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
# shellcheck source=lib/host-qemu.sh
source "$SCRIPT_DIR/lib/host-qemu.sh"

usage() {
    cat <<'EOF'
Usage: test-sp-ec-link.sh --ec-elf PATH --bios-fv-dir DIR --build-dir DIR \
                          --vdrive-dir DIR --coverage-plugin PATH --coverage-log PATH \
                          [--ec-timeout N] [--host-timeout N] [--serial-tee 0|1] \
                          -- <qemu-common-args...>

  --ec-elf           EC firmware ELF (riscv32)
  --bios-fv-dir      Directory containing SECURE_FLASH0.fd and QEMU_EFI.fd
  --build-dir        Build/ directory (logs and swtpm-state live here)
  --vdrive-dir       FAT drive directory exposed to UEFI shell
                     (typically e2e-tests/Build/vdrive-thermal)
  --coverage-plugin  Path to TCG coverage plugin (.so)
  --coverage-log     Path to write QEMU coverage PC trace
  --ec-timeout       Seconds for EC QEMU run (default: 30)
  --host-timeout     Seconds for host QEMU run (default: 180)
  --serial-tee       1 = tee QEMU serial to stdout AND file; 0 = file only (default: 0)
  --                 Everything after this is forwarded verbatim to
                     qemu-system-aarch64 as the host common args (machine,
                     cpu, mem, smbios, etc.)

Must run inside the odp-platform-qemu-sbsa devcontainer.

Exits 0 on PASS, non-zero on FAILURE. The first failure mode wins:
  - Setup error (swtpm socket / EC PTY discovery) -> exits 1
  - host QEMU classification (test FAIL / timeout / banner missing) -> exits 1
  - EC boot string missing (verified AFTER helper returns) -> exits 1
EOF
    exit "${1:-0}"
}

EC_ELF=""
BIOS_FV_DIR=""
BUILD_DIR=""
VDRIVE_DIR=""
COVERAGE_PLUGIN=""
COVERAGE_LOG=""
EC_TIMEOUT=30
HOST_TIMEOUT=180
SERIAL_TEE=0

require_arg() {
    # require_arg <flag-name> <value-or-empty>
    [ -n "$2" ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ec-elf)          require_arg "$1" "${2-}"; EC_ELF="$2";          shift 2 ;;
        --bios-fv-dir)     require_arg "$1" "${2-}"; BIOS_FV_DIR="$2";     shift 2 ;;
        --build-dir)       require_arg "$1" "${2-}"; BUILD_DIR="$2";       shift 2 ;;
        --vdrive-dir)      require_arg "$1" "${2-}"; VDRIVE_DIR="$2";      shift 2 ;;
        --coverage-plugin) require_arg "$1" "${2-}"; COVERAGE_PLUGIN="$2"; shift 2 ;;
        --coverage-log)    require_arg "$1" "${2-}"; COVERAGE_LOG="$2";    shift 2 ;;
        --ec-timeout)      require_arg "$1" "${2-}"; EC_TIMEOUT="$2";      shift 2 ;;
        --host-timeout)    require_arg "$1" "${2-}"; HOST_TIMEOUT="$2";    shift 2 ;;
        --serial-tee)      require_arg "$1" "${2-}"; SERIAL_TEE="$2";      shift 2 ;;
        -h|--help)         usage 0 ;;
        --)                shift; break ;;
        *)                 echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done
# Remaining "$@" is the host QEMU common args (smbios, machine, cpu, etc.)

for var in EC_ELF BIOS_FV_DIR BUILD_DIR VDRIVE_DIR COVERAGE_PLUGIN COVERAGE_LOG; do
    if [ -z "${!var}" ]; then
        echo "ERROR: --${var,,} (translated from \$$var) is required" >&2
        usage 1
    fi
done

# Validate timeouts at parse time. start_ec_qemu interpolates $timeout_s into
# an inner `bash -c` string (via setsid), so non-numeric input would risk
# command injection or an empty-`timeout` syntax error inside the inner shell.
# The library trusts its caller; the orchestrator is the right place to gate.
# Reject empty, non-digit, and zero in one pattern.
case "$EC_TIMEOUT" in
    ''|*[!0-9]*|0) echo "ERROR: --ec-timeout must be a positive integer (got: $EC_TIMEOUT)" >&2; exit 1 ;;
esac
case "$HOST_TIMEOUT" in
    ''|*[!0-9]*|0) echo "ERROR: --host-timeout must be a positive integer (got: $HOST_TIMEOUT)" >&2; exit 1 ;;
esac

# ----- tool preconditions -----
# Fail loudly here if a required tool is missing, rather than letting the
# session teardown degrade silently mid-run (e.g. a missing pkill leaks
# the EC QEMU pipeline into the devcontainer).
require_swtpm_tools || exit 1
require_ec_qemu_tools || exit 1
require_host_qemu_tools || exit 1
[ "$SERIAL_TEE" = "1" ] && { require_host_serial_tee_tools || exit 1; }

EC_OUT_LOG="$BUILD_DIR/ec-qemu-stdout.log"
EC_ERR_LOG="$BUILD_DIR/ec-qemu-stderr.log"
EC_SERIAL_LOG="$BUILD_DIR/ec-serial-output.log"
SERIAL_FIFO="$BUILD_DIR/serial.fifo"

# Caller-scope vars touched by the helper / EC library — listed here so the
# cleanup trap reaches them on signal interruption.
EC_PID=""
SWTPM_PID=""
QEMU_PID=""
TEE_PID=""

# shellcheck disable=SC2329  # invoked via `trap ... EXIT` below
cleanup() {
    # shellcheck disable=SC2317
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    # shellcheck disable=SC2317
    [ -n "${TEE_PID:-}" ] && kill "$TEE_PID" 2>/dev/null
    # shellcheck disable=SC2317
    kill_ec_session
    # shellcheck disable=SC2317
    kill_swtpm
    # shellcheck disable=SC2317
    wait 2>/dev/null
    # shellcheck disable=SC2317
    [ -n "${SERIAL_FIFO:-}" ] && rm -f "$SERIAL_FIFO"
    # shellcheck disable=SC2317
    true
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR"
rm -f "$EC_OUT_LOG" "$EC_ERR_LOG" "$EC_SERIAL_LOG"

# 1. EC QEMU sidecar + PTY discovery (swtpm is owned by the helper now).
start_ec_qemu "$EC_ELF" "$EC_OUT_LOG" "$EC_ERR_LOG" "$EC_SERIAL_LOG" "$EC_TIMEOUT"
PTY=$(discover_ec_pty "$EC_OUT_LOG" "$EC_ERR_LOG") || exit 1
echo "EC PTY: $PTY — launching host QEMU via run_host_efi_and_parse_results"

# 2. Hand off to the canonical EFI runner. It owns swtpm + host QEMU +
#    serial capture + the [PASS]/[FAIL] + "N passed, 0 failed" parse.
#    Pass the EC sidecar PTY so the helper bridges host's serial1.
QEMU_COMMON_ARGS=("$@")
EC_PTY="$PTY"
HELPER_EXIT=0
run_host_efi_and_parse_results || HELPER_EXIT=$?

# 3. Tear down the EC pipeline BEFORE verification so that defmt-print's
#    block-buffered stdout (redirected to a regular file) is fully flushed
#    to $EC_SERIAL_LOG before we grep it. The original Makefile recipe
#    got this for free: verification ran in a separate shell after the
#    bash -lc subshell's EXIT trap had already reaped EC. Clear EC_PID so
#    the EXIT trap below doesn't try to tear it down a second time.
kill_ec_session
EC_PID=""

# 4. Layer the EC-boot grep on top of the helper's classification.
#    First failure mode wins: if the helper said FAIL, we propagate that;
#    EC-boot is a secondary gate that catches "EC silently died but
#    fixture happened to time out cleanly".
if [ "$HELPER_EXIT" -ne 0 ]; then
    echo "host runner reported failure (exit $HELPER_EXIT)" >&2
    exit "$HELPER_EXIT"
fi

if grep -q "Starting uart service" "$EC_SERIAL_LOG" 2>/dev/null; then
    echo "EC: boot successful (PTY serial backend)"
else
    echo "=== EC serial output ==="
    cat "$EC_SERIAL_LOG" 2>/dev/null || echo "(empty)"
    echo "=== End EC serial output ==="
    echo "EC: boot FAILED — 'Starting uart service' not found"
    exit 1
fi

echo "RESULT: ALL TESTS PASSED"
exit 0
