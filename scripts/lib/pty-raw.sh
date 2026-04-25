# shellcheck shell=bash
# Sourceable library — provides enforce_pty_raw. Do NOT execute directly.
#
# Defensive PTY raw-mode enforcement for the back-to-back UART link between
# the SP and EC QEMU instances.
#
# Hazard: MCTP framing uses bytes 0x7E (flag), 0x7D (escape), and various
# control codes. If the PTY is left in canonical/cooked TTY discipline
# (ICANON, ICRNL, IXON, ECHO, ONLCR, etc.), the kernel's line discipline
# mangles or echoes those bytes — silently corrupting MCTP frames in both
# directions. This helper forces raw mode on the PTY slave path so a future
# harness change cannot silently re-cook the line.
#
# Naming: `enforce_pty_raw` is intentionally NOT named `assert_*` — it
# MUTATES global TTY state via `stty`, it does not just check it.

# Force raw mode + disable every cooking knob we know about. `min 1 time 0`
# ensures blocking single-byte reads (no buffering / no inter-byte timer).
#
# Single-retry on failure: when launching SBSA QEMU immediately after PTY
# discovery, a transient EIO from `stty` has been observed if the PTY
# master end is mid-handshake. One short retry covers that race without
# masking a genuinely broken PTY.
enforce_pty_raw() {
    local pty="$1"
    if [ -z "$pty" ]; then
        echo "ERROR: enforce_pty_raw: missing PTY path argument" >&2
        return 2
    fi
    if [ ! -e "$pty" ]; then
        echo "ERROR: enforce_pty_raw: PTY '$pty' does not exist" >&2
        return 1
    fi

    local attempt
    for attempt in 1 2; do
        if stty -F "$pty" raw -echo -echoe -echok -echoctl -echoke \
                               -ixon -ixoff -icrnl -inlcr -onlcr \
                               min 1 time 0 2>/tmp/enforce_pty_raw.$$.err; then
            rm -f /tmp/enforce_pty_raw.$$.err
            echo "PTY raw mode enforced on $pty (attempt $attempt)"
            return 0
        fi
        if [ "$attempt" -eq 1 ]; then
            echo "WARN: enforce_pty_raw: stty raw on '$pty' failed (attempt 1), retrying after 100ms" >&2
            sleep 0.1
        fi
    done

    echo "ERROR: enforce_pty_raw: stty raw on '$pty' failed after 2 attempts" >&2
    sed 's/^/  stty: /' /tmp/enforce_pty_raw.$$.err >&2 2>/dev/null || true
    rm -f /tmp/enforce_pty_raw.$$.err
    return 1
}
