#!/usr/bin/env bash
# Shared dual-QEMU + PTY-bridge harness for orchestrator scripts.
#
# Encapsulates the common flow used by test-serial.sh (FFA-less serial link
# test) and test-e2e-mctp.sh (full MCTP E2E test): swtpm setup, EC QEMU
# launch with PTY discovery, SBSA QEMU launch bridging serial1 to the EC
# PTY, teardown. Both scripts share these steps verbatim — only their
# script-specific args (e.g. --vdrive-dir) and their post-run verification
# differ.
#
# Source order matters: callers must source lib/swtpm.sh and lib/ec-qemu.sh
# before sourcing this file, since the harness depends on `start_swtpm`,
# `wait_for_swtpm_socket`, `start_ec_qemu`, and `discover_ec_pty`.
#
# Caller contract:
#   - Set EC_ELF, BIOS_FV_DIR, BUILD_DIR, EC_TIMEOUT, SBSA_TIMEOUT.
#   - Optionally set the EXTRA_QEMU_ARGS array (e.g.
#       EXTRA_QEMU_ARGS=( -drive "file=fat:rw:$VDRIVE_DIR,format=raw,media=disk" )
#     ) for extra SBSA QEMU args (vdrive mounts, etc.).
#   - Call harness_validate_timeouts, harness_setup_paths,
#     harness_install_cleanup, harness_start_services.
#   - Then harness_run_sbsa "$@" with the SBSA common args (smbios, machine,
#     etc.). On return, $HARNESS_SBSA_EXIT is set; if non-zero the caller
#     should short-circuit before verification.
#   - Call harness_shutdown_ec to flush the EC pipeline before grepping
#     EC_SERIAL_LOG.
#   - Caller then performs its own verification on $SBSA_SERIAL_LOG /
#     $EC_SERIAL_LOG.

# Validate that a flag was given a value. Used by callers in their arg loop.
harness_require_arg() {
    # harness_require_arg <flag-name> <value-or-empty>
    [ -n "$2" ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
}

# Reject empty, non-digit, and zero in one pattern. start_ec_qemu
# interpolates $timeout_s into an inner `bash -c` string via setsid, so
# non-numeric input would risk command injection or an empty-`timeout`
# syntax error inside the inner shell. The library trusts its caller;
# orchestrators are the right place to gate.
harness_validate_timeouts() {
    case "$EC_TIMEOUT" in
        ''|*[!0-9]*|0) echo "ERROR: --ec-timeout must be a positive integer (got: $EC_TIMEOUT)" >&2; exit 1 ;;
    esac
    case "$SBSA_TIMEOUT" in
        ''|*[!0-9]*|0) echo "ERROR: --sbsa-timeout must be a positive integer (got: $SBSA_TIMEOUT)" >&2; exit 1 ;;
    esac
}

# Compute path globals + ensure clean state for log files. Must be called
# after BUILD_DIR is set; populates SWTPM_STATE, SWTPM_SOCK, SWTPM_LOG,
# EC_OUT_LOG, EC_ERR_LOG, EC_SERIAL_LOG, SBSA_SERIAL_LOG. Also initialises
# EC_PID and SWTPM_PID to empty so the cleanup trap can no-op safely
# before start_swtpm / start_ec_qemu run.
harness_setup_paths() {
    SWTPM_STATE="$BUILD_DIR/swtpm-state"
    SWTPM_SOCK="$SWTPM_STATE/swtpm-sock"
    SWTPM_LOG="$BUILD_DIR/swtpm.log"
    EC_OUT_LOG="$BUILD_DIR/ec-qemu-stdout.log"
    EC_ERR_LOG="$BUILD_DIR/ec-qemu-stderr.log"
    EC_SERIAL_LOG="$BUILD_DIR/ec-serial-output.log"
    SBSA_SERIAL_LOG="$BUILD_DIR/sbsa-serial-output.log"
    EC_PID=""
    SWTPM_PID=""
    mkdir -p "$BUILD_DIR" "$SWTPM_STATE"
    rm -f "$EC_OUT_LOG" "$EC_ERR_LOG" "$EC_SERIAL_LOG" "$SBSA_SERIAL_LOG" "$SWTPM_SOCK"
}

# Tear down the EC session (no-op if EC_PID is unset).
#
# EC_PID is the session leader of a session created by `setsid` (in
# ec-qemu.sh). Bash auto-enables job control for session-leader children,
# which puts each pipeline stage (timeout/tee/defmt-print) in its OWN
# process group inside the session — so a single `kill -- -$EC_PID` only
# signals the leader's own pgrp and leaks `timeout` + `qemu-system-riscv32`.
# Signal the whole session via `pkill -s` so every descendant process group
# is reached, then `kill -- -$EC_PID` as a belt-and-braces fallback.
harness_kill_ec_session() {
    [ -n "$EC_PID" ] || return 0
    pkill -TERM -s "$EC_PID" 2>/dev/null
    kill -- "-$EC_PID" 2>/dev/null
    wait "$EC_PID" 2>/dev/null
}

# shellcheck disable=SC2329  # invoked via `trap ... EXIT` below
harness_cleanup() {
    # SC2317: invoked via `trap ... EXIT`, not statically reachable.
    # shellcheck disable=SC2317
    harness_kill_ec_session
    # shellcheck disable=SC2317
    if [ -n "$SWTPM_PID" ]; then
        kill "$SWTPM_PID" 2>/dev/null
        wait "$SWTPM_PID" 2>/dev/null
    fi
    # shellcheck disable=SC2317
    true
}

harness_install_cleanup() {
    trap harness_cleanup EXIT
}

# Start swtpm + EC QEMU; populates the global PTY variable.
harness_start_services() {
    start_swtpm "$SWTPM_STATE" "$SWTPM_SOCK" "$SWTPM_LOG"
    wait_for_swtpm_socket "$SWTPM_SOCK" || {
        echo "--- swtpm log ($SWTPM_LOG) ---" >&2
        cat "$SWTPM_LOG" >&2 2>/dev/null || echo "(empty or missing)" >&2
        echo "--- end swtpm log ---" >&2
        exit 1
    }
    start_ec_qemu "$EC_ELF" "$EC_OUT_LOG" "$EC_ERR_LOG" "$EC_SERIAL_LOG" "$EC_TIMEOUT"
    PTY=$(discover_ec_pty "$EC_OUT_LOG" "$EC_ERR_LOG") || exit 1
}

# Run SBSA QEMU under timeout. Forwards "$@" verbatim as common QEMU args
# (machine, cpu, mem, smbios). Inserts the dual-flash, swtpm chardev, and
# EC-link chardev/serial setup. Splices in $EXTRA_QEMU_ARGS (caller-supplied
# array) just before the trailing -display/-no-reboot — typically used to
# add a `-drive file=fat:rw:...` vdrive mount.
#
# Captures SBSA's exit code in $HARNESS_SBSA_EXIT (does NOT exit on failure
# itself; the caller decides whether to short-circuit).
harness_run_sbsa() {
    HARNESS_SBSA_EXIT=0
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
            "${EXTRA_QEMU_ARGS[@]}" \
            -display none \
            -no-reboot \
        || HARNESS_SBSA_EXIT=$?
}

# Tear down the EC pipeline so block-buffered defmt-print stdout (redirected
# to a regular file) is fully flushed to $EC_SERIAL_LOG before the caller
# greps it. Clears EC_PID so the EXIT trap doesn't try to tear it down a
# second time.
harness_shutdown_ec() {
    harness_kill_ec_session
    EC_PID=""
}
