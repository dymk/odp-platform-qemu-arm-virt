#!/usr/bin/env bash
# Run the single-QEMU e2e test suite against the secure partition.
#
# SPDX-License-Identifier: MIT
#
# Thin caller: argument parsing, tool checks, and high-level exit-code
# propagation. The swtpm launch, host QEMU invocation, serial capture,
# and result classification all live in
# scripts/lib/host-qemu.sh::run_host_efi_and_parse_results so the
# two-QEMU thermal runner (test-sp-ec-link.sh) can share the same
# parser. No EC sidecar is attached here (single-QEMU path).
#
# Run `test-sp-services.sh --help` for usage. Must be executed inside the
# odp-platform-qemu-sbsa devcontainer (requires swtpm, qemu-system-aarch64,
# timeout, tee on PATH).

set -o pipefail
# Intentionally NOT `set -e`: we use `cmd || EXIT=$?` patterns and rely
# on explicit exit codes for the QEMU run + log parsing. test-sp-ec-link.sh
# documents the same rationale (see v1.1 hardening cycle).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/swtpm.sh
source "$SCRIPT_DIR/lib/swtpm.sh"
# shellcheck source=lib/host-qemu.sh
source "$SCRIPT_DIR/lib/host-qemu.sh"

usage() {
    cat <<'EOF'
Usage: test-sp-services.sh --bios-fv-dir DIR --build-dir DIR --vdrive-dir DIR \
                           --coverage-plugin PATH --coverage-log PATH \
                           [--host-timeout N] [--serial-tee 0|1] -- <qemu-common-args...>

  --bios-fv-dir      Directory containing SECURE_FLASH0.fd and QEMU_EFI.fd
  --build-dir        Build/ directory (test-output.log, swtpm state, etc. live here)
  --vdrive-dir       FAT drive directory exposed to UEFI shell (one .efi + startup.nsh)
  --coverage-plugin  Path to TCG coverage plugin (.so)
  --coverage-log     Path to write QEMU coverage PC trace
  --host-timeout     Seconds for host QEMU run (default: 180)
  --serial-tee       1 = tee QEMU serial to stdout AND file; 0 = file only (default: 0)

After --, all remaining args are passed verbatim to qemu-system-aarch64
(typically the QEMU_COMMON_ARGS from Common.mk).

Exit codes:
  0  — banner present, "N passed, 0 failed" line present, QEMU exit 0
  1  — banner missing, [FAIL] present, timed out, or other failure
EOF
}

# ----- arg parsing -----
BIOS_FV_DIR=""
BUILD_DIR=""
VDRIVE_DIR=""
COVERAGE_PLUGIN=""
COVERAGE_LOG=""
HOST_TIMEOUT=180
SERIAL_TEE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bios-fv-dir)     BIOS_FV_DIR="$2";     shift 2 ;;
        --build-dir)       BUILD_DIR="$2";       shift 2 ;;
        --vdrive-dir)      VDRIVE_DIR="$2";      shift 2 ;;
        --coverage-plugin) COVERAGE_PLUGIN="$2"; shift 2 ;;
        --coverage-log)    COVERAGE_LOG="$2";    shift 2 ;;
        --host-timeout)    HOST_TIMEOUT="$2";    shift 2 ;;
        --serial-tee)      SERIAL_TEE="$2";      shift 2 ;;
        --help|-h)         usage; exit 0 ;;
        --)                shift; break ;;
        *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for var in BIOS_FV_DIR BUILD_DIR VDRIVE_DIR COVERAGE_PLUGIN COVERAGE_LOG; do
    if [ -z "${!var}" ]; then
        echo "ERROR: --${var,,} (translated from \$$var) is required" >&2
        usage >&2
        exit 2
    fi
done

QEMU_COMMON_ARGS=("$@")

# ----- tool preconditions -----
# Fail loudly here if a required tool is missing, before any filesystem
# side effects or process launches.
require_swtpm_tools || exit 1
require_host_qemu_tools || exit 1
[ "$SERIAL_TEE" = "1" ] && { require_host_serial_tee_tools || exit 1; }

mkdir -p "$BUILD_DIR"

# Cleanup trap: QEMU_PID / TEE_PID / SWTPM_PID may be set by
# run_host_efi_and_parse_results in this caller's scope; if a signal
# arrives mid-`wait`, this trap reaches them.
QEMU_PID=""
TEE_PID=""
SERIAL_FIFO="$BUILD_DIR/serial.fifo"
cleanup() {
    local sig=$?
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    [ -n "${TEE_PID:-}" ] && kill "$TEE_PID" 2>/dev/null
    kill_swtpm
    wait 2>/dev/null
    [ -n "${SERIAL_FIFO:-}" ] && rm -f "$SERIAL_FIFO"
    exit "$sig"
}
trap cleanup EXIT INT TERM

# Single-QEMU path — no EC sidecar.
EC_PTY=""

run_host_efi_and_parse_results
exit $?
