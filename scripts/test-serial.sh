#!/usr/bin/env bash
# scripts/test-serial.sh — Orchestrate the EC ↔ SBSA serial-link test.
#
# Owns the long-lived child processes (swtpm + EC QEMU + SBSA QEMU),
# sets up the cleanup trap, and performs post-run verification.
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
# PTY raw-mode helper. Must run BEFORE SBSA QEMU opens the PTY so the kernel
# tty line discipline doesn't mangle MCTP framing bytes (0x7E flag, 0x7D
# escape, control codes).
# shellcheck source=lib/pty-raw.sh
source "$SCRIPT_DIR/lib/pty-raw.sh"

usage() {
    cat <<'EOF'
Usage: test-serial.sh --ec-elf PATH --bios-fv-dir DIR --build-dir DIR \
                      [--ec-timeout N] [--sbsa-timeout N] -- <qemu-common-args...>

  --ec-elf        EC firmware ELF (riscv32)
  --bios-fv-dir   Directory containing SECURE_FLASH0.fd and QEMU_EFI.fd
  --build-dir     Build/ directory (logs and swtpm-state live here)
  --ec-timeout    Seconds for EC QEMU run (default: 30)
  --sbsa-timeout  Seconds for SBSA QEMU run (default: 60)
  --fault-inject MODE
                  (DEBUG/CI-triage only) inject a deterministic failure:
                  ec-silent | sp-no-call | sbsa-hang. Default: off (no
                  behavior change). See e2e-tests/README.md
                  "Failure-mode triage".
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
FAULT_INJECT=""

require_arg() {
    # require_arg <flag-name> <value-or-empty>
    [ -n "$2" ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ec-elf)       require_arg "$1" "${2-}"; EC_ELF="$2"; shift 2 ;;
        --bios-fv-dir)  require_arg "$1" "${2-}"; BIOS_FV_DIR="$2"; shift 2 ;;
        --build-dir)    require_arg "$1" "${2-}"; BUILD_DIR="$2"; shift 2 ;;
        --ec-timeout)   require_arg "$1" "${2-}"; EC_TIMEOUT="$2"; shift 2 ;;
        --sbsa-timeout) require_arg "$1" "${2-}"; SBSA_TIMEOUT="$2"; shift 2 ;;
        --fault-inject) require_arg "$1" "${2-}"; FAULT_INJECT="$2"; shift 2 ;;
        --fault-inject=*) FAULT_INJECT="${1#*=}"; shift ;;
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

# Validate timeouts at parse time. start_ec_qemu interpolates $timeout_s into
# an inner `bash -c` string (via setsid), so non-numeric input would risk
# command injection or an empty-`timeout` syntax error inside the inner shell.
# The library trusts its caller; the orchestrator is the right place to gate.
# Reject empty, non-digit, and zero in one pattern.
case "$EC_TIMEOUT" in
    ''|*[!0-9]*|0) echo "ERROR: --ec-timeout must be a positive integer (got: $EC_TIMEOUT)" >&2; exit 1 ;;
esac
case "$SBSA_TIMEOUT" in
    ''|*[!0-9]*|0) echo "ERROR: --sbsa-timeout must be a positive integer (got: $SBSA_TIMEOUT)" >&2; exit 1 ;;
esac

# Phase 17 — fault-injection allowlist + sbsa-hang SBSA_TIMEOUT override.
# Allowlist validation MUST come AFTER the positive-int validation above so
# the override of `2` for sbsa-hang is set on a variable already validated.
case "$FAULT_INJECT" in
    ''|ec-silent|sp-no-call|sbsa-hang) ;;
    *) echo "ERROR: --fault-inject must be one of: ec-silent, sp-no-call, sbsa-hang (got: $FAULT_INJECT)" >&2; exit 1 ;;
esac

if [ "$FAULT_INJECT" = "sbsa-hang" ]; then
    SBSA_TIMEOUT=2
    # Clamp EC_TIMEOUT too: with SBSA reaped at 2s the EC pipeline must not
    # outlive it (otherwise cleanup waits up to the original EC_TIMEOUT).
    # Cap at SBSA_TIMEOUT but never below the EC_TIMEOUT validator's `>0`
    # contract.
    if [ "$EC_TIMEOUT" -gt "$SBSA_TIMEOUT" ]; then
        EC_TIMEOUT="$SBSA_TIMEOUT"
    fi
    echo "FAULT_INJECT=sbsa-hang: SBSA_TIMEOUT overridden to 2 (expect timeout(1) exit 124); EC_TIMEOUT clamped to $EC_TIMEOUT" >&2
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
FAULT_RACE_PID=""

# Unique tag baked into the SBSA QEMU `-name` argument (and used by every
# `pkill -f` that targets the SBSA process). Replaces the pre-fix `pkill -P
# $$ -f qemu-system-aarch64` pattern which matched no PIDs (qemu's parent is
# `timeout(1)`, not the orchestrator shell, so the -P filter excluded the
# real qemu) and risked accidental cross-job kills if -P were dropped.
SBSA_TAG="sbsa-test-$$"

# Cleanup log — captures stderr from in-trap pkill/wait so that a noisy
# teardown (e.g. SIGSTOPed children that wouldn't accept SIGTERM) leaves a
# breadcrumb instead of polluting the main test output.
CLEANUP_LOG=""

# Tear down the EC session (no-op if EC_PID is unset).
#
# EC_PID is the session leader of a session created by `setsid` (in
# ec-qemu.sh). Bash auto-enables job control for session-leader children,
# which puts each pipeline stage (timeout/tee/defmt-print) in its OWN
# process group inside the session — so a single `kill -- -$EC_PID` only
# signals the leader's own pgrp and leaks `timeout` + `qemu-system-riscv32`.
# Signal the whole session via `pkill -s` so every descendant process group
# is reached, then `kill -- -$EC_PID` as a belt-and-braces fallback.
kill_ec_session() {
    [ -n "$EC_PID" ] || return 0
    # Phase 17: send SIGCONT first in case --fault-inject=ec-silent left the
    # session SIGSTOPed — otherwise the SIGTERM below queues forever and the
    # `wait` at the end hangs.
    pkill -CONT -s "$EC_PID" 2>/dev/null
    pkill -TERM -s "$EC_PID" 2>/dev/null
    kill -- "-$EC_PID" 2>/dev/null
    wait "$EC_PID" 2>/dev/null
}

# shellcheck disable=SC2329  # invoked via `trap ... EXIT` below
cleanup() {
    # SC2317: invoked via `trap ... EXIT`, not statically reachable.
    # shellcheck disable=SC2317
    {
        kill_ec_session
        if [ -n "$SWTPM_PID" ]; then
            kill "$SWTPM_PID" 2>/dev/null
            wait "$SWTPM_PID" 2>/dev/null
        fi
        if [ -n "$FAULT_RACE_PID" ]; then
            kill "$FAULT_RACE_PID" 2>/dev/null
            wait "$FAULT_RACE_PID" 2>/dev/null
        fi
        # Belt-and-braces: any orphaned SBSA QEMU tagged with our session's
        # SBSA_TAG (rare — should already be reaped by the foreground
        # `timeout` or the sp-no-call race-killer). Matches against the
        # qemu cmdline so it is scoped to *this* test run only.
        pkill -KILL -f "$SBSA_TAG" 2>/dev/null
        true
    } 2> >(if [ -n "$CLEANUP_LOG" ]; then tee -a "$CLEANUP_LOG" >&2; else cat >&2; fi)
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR" "$SWTPM_STATE"
CLEANUP_LOG="$BUILD_DIR/cleanup.log"
rm -f "$EC_OUT_LOG" "$EC_ERR_LOG" "$EC_SERIAL_LOG" "$SBSA_SERIAL_LOG" "$SWTPM_SOCK" "$CLEANUP_LOG"

# 1. swtpm
start_swtpm "$SWTPM_STATE" "$SWTPM_SOCK" "$SWTPM_LOG"
wait_for_swtpm_socket "$SWTPM_SOCK" || {
    echo "--- swtpm log ($SWTPM_LOG) ---" >&2
    cat "$SWTPM_LOG" >&2 2>/dev/null || echo "(empty or missing)" >&2
    echo "--- end swtpm log ---" >&2
    exit 1
}

# 2. EC QEMU + PTY discovery
start_ec_qemu "$EC_ELF" "$EC_OUT_LOG" "$EC_ERR_LOG" "$EC_SERIAL_LOG" "$EC_TIMEOUT"
PTY=$(discover_ec_pty "$EC_OUT_LOG" "$EC_ERR_LOG") || exit 1
echo "EC PTY: $PTY — launching SBSA QEMU"

# signature-emitter:pty-raw-enforce
# Put PTY into raw mode BEFORE SBSA QEMU opens it. Prevents the kernel TTY
# line discipline from mangling MCTP framing bytes (0x7E flag, 0x7D escape,
# control codes). See scripts/lib/pty-raw.sh.
enforce_pty_raw "$PTY" || { echo "FATAL: cannot put $PTY in raw mode" >&2; exit 1; }

# signature-emitter:fault-ec-silent
# FAULT_INJECT=ec-silent — freeze the EC after PTY is up so the SP-side MCTP
# timeout fires (expected outcome: MCTP_PING_FAIL timeout). SIGSTOP via
# `pkill -s "$EC_PID"` reaches every process group in the session — the
# leader-only kill leaks because each pipeline stage (timeout/qemu/tee/
# defmt-print) is in its own pgrp inside the session.
if [ "$FAULT_INJECT" = "ec-silent" ]; then
    echo "FAULT_INJECT=ec-silent: SIGSTOP'ing EC session led by EC_PID=$EC_PID" >&2
    pkill -STOP -s "$EC_PID" 2>/dev/null \
        || echo "WARN: pkill -STOP -s $EC_PID failed (session may have already exited)" >&2
fi

# 3. SBSA QEMU
SBSA_EXIT=0

# signature-emitter:fault-sp-no-call
# FAULT_INJECT=sp-no-call — race-kill the SBSA QEMU ~2s into boot, well
# before SP reaches send_mctp_ping. Targeting is by SBSA_TAG (baked into
# qemu's `-name` arg below) — the previous `pkill -P $$ -f qemu-system-
# aarch64` pattern matched no PIDs because qemu's parent is `timeout(1)`,
# not the orchestrator shell. SBSA_TAG includes the orchestrator PID so it
# is unique across concurrent runs.
if [ "$FAULT_INJECT" = "sp-no-call" ]; then
    echo "FAULT_INJECT=sp-no-call: race-killing SBSA QEMU (tag=$SBSA_TAG) in 2s" >&2
    ( sleep 2 && pkill -KILL -f "$SBSA_TAG" 2>/dev/null ) &
    FAULT_RACE_PID=$!
fi

# signature-emitter:sbsa-qemu-launch
# `-name "$SBSA_TAG"` makes the SBSA QEMU process greppable by sp-no-call /
# cleanup. The tag is unique-per-orchestrator-pid so this is safe under
# concurrent test runs.
timeout "$SBSA_TIMEOUT" \
    qemu-system-aarch64 \
        -name "$SBSA_TAG" \
        "$@" \
        -drive "if=pflash,format=raw,unit=0,file=$BIOS_FV_DIR/SECURE_FLASH0.fd" \
        -drive "if=pflash,format=raw,unit=1,file=$BIOS_FV_DIR/QEMU_EFI.fd,readonly=on" \
        -chardev "socket,id=chrtpm,path=$SWTPM_SOCK" \
        -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
        -chardev "serial,id=ec-link,path=$PTY" \
        -serial "file:$SBSA_SERIAL_LOG" \
        -serial "chardev:ec-link" \
        -drive "file=fat:rw:test-serial-vdrive,format=raw,media=disk" \
        -display none \
        -no-reboot \
    || SBSA_EXIT=$?

# 4. SBSA failure short-circuits before verification (matches original recipe).
if [ "$SBSA_EXIT" -ne 0 ]; then
    echo "SBSA QEMU exited with code $SBSA_EXIT" >&2
    exit "$SBSA_EXIT"
fi

# 5. Tear down the EC pipeline BEFORE verification so that defmt-print's
# block-buffered stdout (redirected to a regular file) is fully flushed to
# $EC_SERIAL_LOG before we grep it. The original Makefile recipe got this
# for free: verification ran in a separate shell after the bash -lc subshell's
# EXIT trap had already reaped EC. Clear EC_PID so the EXIT trap below
# doesn't try to tear it down a second time.
kill_ec_session
EC_PID=""

# 6. Verification (only on SBSA success).
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

# signature-emitter:mctp-ping-verify
# MCTP ping-pong assertion. PASS: SBSA serial log contains MCTP_PING_OK and
# NOT MCTP_PING_FAIL. FAIL: MCTP_PING_FAIL line OR neither marker present.
# There is intentionally no log-grep readiness handshake here — the SP-side
# timeout (surfaced as `MCTP_PING_FAIL timeout`) is the cold-start
# failure-detection mechanism.
if grep -q "MCTP_PING_FAIL" "$SBSA_SERIAL_LOG" 2>/dev/null; then
    fail_line=$(grep "MCTP_PING_FAIL" "$SBSA_SERIAL_LOG" | head -1)
    echo "MCTP: PING FAILED -- $fail_line"
    PASS=false
elif grep -q "MCTP_PING_OK" "$SBSA_SERIAL_LOG" 2>/dev/null; then
    ok_line=$(grep "MCTP_PING_OK" "$SBSA_SERIAL_LOG" | head -1)
    echo "MCTP: ping OK -- $ok_line"
else
    echo "MCTP: neither MCTP_PING_OK nor MCTP_PING_FAIL seen in $SBSA_SERIAL_LOG"
    PASS=false
fi

if "$PASS"; then
    echo "RESULT: SERIAL LINK TEST PASSED"
    exit 0
else
    echo "RESULT: SERIAL LINK TEST FAILED"
    exit 1
fi
