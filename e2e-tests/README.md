# `e2e-tests/` — End-to-end test harness

This directory contains the end-to-end integration test harness for the EC
Secure Partition platform. The two main entrypoints driven from the parent
`Makefile`:

| Target                            | What it does                                                                                                                                              | CI?           |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- |
| `make -C e2e-tests test-serial`   | Orchestrator-only SP↔EC serial-link test — launches swtpm + EC QEMU + SBSA QEMU, waits for the MCTP ping-pong handshake to complete, asserts pass/fail.   | yes (gating)  |
| `make -C e2e-tests test`          | Broader Python-driven UEFI test suite (thermal, TPM, etc.) running against the same SBSA QEMU image.                                                      | yes           |

The `test-serial` target is a thin wrapper around `scripts/test-serial.sh`
in the parent repo. Run `scripts/test-serial.sh --help` for the full flag
list, including `--fault-inject` for triage.

## Failure-mode triage

When CI goes red, the harness emits exactly **five** distinguishable log
signatures. The table below maps each verbatim signature to a
`{stuck-SP, stuck-EC, stuck-QEMU}` taxonomy bucket and the rule that
discriminates it from the others.

| #   | Log signature (verbatim)                                       | Exit code   | Taxonomy bucket                                                                                                       | Disambiguator                                                                                                                                                              | Likely root cause                                            |
| --- | -------------------------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| a   | `ERROR: ...` (setup, swtpm/PTY)                                | 1           | local-only — does NOT fire in CI                                                                                      | n/a — CI runner already validated swtpm                                                                                                                                    | local devcontainer setup drift                               |
| b   | `SBSA QEMU exited with code N`                                 | N           | **stuck-QEMU** (`N=124` → harness watchdog) **or stuck-EC** (`N=124` AND `ec-serial-output.log` shows EC stopped at `Starting uart service` with no further activity) **or stuck-SP via external pkill** (`N=137`) | check N AND `ec-serial-output.log`: `124` + EC log clean past `Starting uart service` only → SP made no progress → **stuck-EC** (SP can't init without responsive EC, e.g. `--fault-inject=ec-silent`); `124` + EC log shows steady traffic → **stuck-QEMU** (SP genuinely hung); `137` → external SIGKILL (e.g. `--fault-inject=sp-no-call`); `≠ 124, ≠ 137` → SBSA/SP crash | SP crash, EC stuck holding the link, harness watchdog, or external pkill race |
| c   | `EC: boot FAILED — 'Starting uart service' not found`          | 1           | **stuck-EC**                                                                                                          | `ec-serial-output.log` contains no boot trail at all → EC binary genuinely failed (MSRV regression, panic, missing symbols)                                                | EC build broken                                              |
| d   | `MCTP: PING FAILED -- MCTP_PING_FAIL <reason>`                 | 1           | **stuck-EC** if `<reason>` is `timeout` AND `ec-serial-output.log` shows EC booted past `Starting uart service`; else **stuck-SP** | grep `ec-serial-output.log` for `Starting uart service`. If present + `MCTP_PING_FAIL timeout` → EC booted but didn't reply mid-handshake. If `<reason>` is `framer_*` or `decode` → **stuck-SP** (encoder bug). Note: `--fault-inject=ec-silent` does **NOT** reach this signature in practice — see (b) above. | EC handler bug, MCTP framing drift, or PTY corruption         |
| e   | `MCTP: NEITHER MCTP_PING_OK nor MCTP_PING_FAIL seen ...`       | 1           | **stuck-SP**                                                                                                          | SP reached the post-MCTP verification path but the SBSA log contains neither marker. Rare in practice; usually a logging bug or aborted send.                                | SP early-boot hang or panic                                  |

### Disambiguating signature (d): stuck-SP vs stuck-EC

Both `MCTP_PING_FAIL timeout` (EC stops responding mid-handshake) and
`MCTP_PING_FAIL framer_*` (SP encoder/decoder bug) emit the same row-(d)
signature. The discriminator is `e2e-tests/Build/ec-serial-output.log`:

- **Present + clean boot trail (`Starting uart service`) + `MCTP_PING_FAIL timeout`**
  → EC booted, opened the PTY, but stopped replying mid-handshake. **stuck-EC**.
- **`MCTP_PING_FAIL framer_*` / `decode` / non-timeout reason**
  → SP-side framing bug. **stuck-SP**. EC log is irrelevant.

Note: empirically, if EC is frozen *before* the SP finishes early init
(e.g. `--fault-inject=ec-silent`), the SP never reaches `mctp_ping` at
all and the harness watchdog fires first → you will see signature
(b)/124, NOT (d). To distinguish that case from a genuinely stuck SBSA
QEMU, check `ec-serial-output.log` per the (b) row.

Note: `--fault-inject=sbsa-hang` silently overrides both `--sbsa-timeout`
(set to 2) and `--ec-timeout` (clamped to ≤2 if larger), to keep the
overall wall-time bounded for the watchdog test. The override is logged
on stderr at startup.

### Reproducing each signature with `--fault-inject`

A `--fault-inject={ec-silent|sp-no-call|sbsa-hang}` flag (default OFF)
injects a deterministic failure mode for triage. It is plumbed through
the `test-serial` Make target via the `FAULT_INJECT` variable.

```bash
# signature (b)/124 with stuck-EC fingerprint — EC frozen via SIGSTOP,
# SP makes no early-init progress, harness watchdog fires
HUSKY=0 make -C e2e-tests test-serial FAULT_INJECT=ec-silent

# signature (b)/137 — stuck-QEMU via external SIGKILL race-kill
HUSKY=0 make -C e2e-tests test-serial FAULT_INJECT=sp-no-call

# signature (b)/124 — stuck-QEMU via the timeout(1) watchdog (SBSA_TIMEOUT=2)
HUSKY=0 make -C e2e-tests test-serial FAULT_INJECT=sbsa-hang
```

All three injected modes currently surface as variants of signature (b),
discriminated by exit code N and `ec-serial-output.log` content.

Note: EC-stuck-pre-boot (signature `c`) cannot be injected from the
harness without breaking the EC build — deferred to a future phase.

### CI baseline wall-time

Track wall-time of the gating `build-test-bios` job from green runs on
`main`. Future regressions >2x baseline flag a performance review.

### Cross-references

- `scripts/test-serial.sh` — signature emitters are tagged with greppable
  anchor comments. Use `grep '# signature-emitter:' scripts/test-serial.sh`
  to find them. Anchors:
  - `pty-raw-enforce` — local-only PTY-raw setup error
  - `sbsa-qemu-launch` — emits `SBSA QEMU exited with code N` on non-zero exit
  - `mctp-ping-verify` — emits `MCTP: PING FAILED` / `MCTP: ping OK` /
    `MCTP: neither MCTP_PING_OK nor MCTP_PING_FAIL seen ...`
  - `fault-ec-silent`, `fault-sp-no-call` — fault-injection emitters
  The verbatim strings cited in the triage table above must match what
  those `echo` lines emit; CI alerting greps them as opaque tokens.
- See the `mod/secure-services/platform/src/mctp_ping.rs` source for the
  ping-pong contract enforced by `test-serial`. The `MctpPingError`
  `Display` impl is the source of truth for the `<reason>` strings in
  `MCTP_PING_FAIL <reason>`.
