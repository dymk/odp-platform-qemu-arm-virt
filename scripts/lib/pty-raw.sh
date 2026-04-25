# shellcheck shell=bash
# Sourceable library — provides assert_pty_raw. Do NOT execute directly.
#
# Phase 16 / PP-04 — defensive PTY raw-mode assertion.
#
# Hazard: MCTP framing uses bytes 0x7E (flag), 0x7D (escape), and various control codes.
# If the PTY (the back-to-back UART link between SP and EC QEMU instances) is left in
# canonical/cooked TTY discipline (ICANON, ICRNL, IXON, ECHO, ONLCR, etc.), the kernel's
# line discipline mangles or echoes those bytes — silently corrupting MCTP frames in
# both directions. This helper forces raw mode on the PTY slave path so a future harness
# change cannot silently re-cook the line.
#
# See .planning/research/v1.3/PITFALLS.md §3 ("PTY raw discipline").
# See .planning/phases/16-ping-pong-end-to-end/16-CONTEXT.md D-8 (AMENDED).

assert_pty_raw() {
    local pty="$1"
    if [ -z "$pty" ]; then
        echo "ERROR: assert_pty_raw: missing PTY path argument" >&2
        return 2
    fi
    if [ ! -e "$pty" ]; then
        echo "ERROR: assert_pty_raw: PTY '$pty' does not exist" >&2
        return 1
    fi
    # Force raw mode + disable every cooking knob we know about. `min 1 time 0` ensures
    # blocking single-byte reads (no buffering / no inter-byte timer).
    if ! stty -F "$pty" raw -echo -echoe -echok -echoctl -echoke \
                           -ixon -ixoff -icrnl -inlcr -onlcr \
                           min 1 time 0; then
        echo "ERROR: assert_pty_raw: stty raw on '$pty' failed" >&2
        return 1
    fi
    echo "PTY raw mode asserted on $pty (Phase 16 / PP-04)"
    return 0
}
