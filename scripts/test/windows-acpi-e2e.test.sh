#!/usr/bin/env bash
# Behavioral tests for the Windows ACPI runner.
#
# SPDX-License-Identifier: MIT

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODP_WINDOWS_ACPI_E2E_SOURCE_ONLY=1
# shellcheck source=../run-windows-acpi-e2e.sh
source "$SCRIPT_DIR/../run-windows-acpi-e2e.sh"

WORK_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$WORK_DIR"' EXIT
FAILURES=0
CASE=0
UUID=65467f50-827f-4e4f-8770-dbf4c3f77f45

expect() {
    local description="$1" want="$2" got
    shift 2
    ("$@") > "$WORK_DIR/case.log" 2>&1
    got=$?
    CASE=$((CASE + 1))
    if [ "$got" = "$want" ]; then
        echo "ok $CASE - $description"
    else
        echo "not ok $CASE - $description (want rc=$want, got rc=$got)"
        cat "$WORK_DIR/case.log"
        FAILURES=$((FAILURES + 1))
    fi
}

contract() {
    ODP_E2E_PAYLOAD_DIR="$WORK_DIR/payload"
    mkdir -p "$ODP_E2E_PAYLOAD_DIR/adapters/ucsi/smoke"
    printf '%s\n' driver-pl061gpio-ARM64-Release \
        driver-qemui2c-ARM64-Release driver-ectest_kmdf-ARM64-Release \
        > "$ODP_E2E_PAYLOAD_DIR/adapters/ucsi/drivers.txt"
    printf '%s\n' "$UUID" > "$ODP_E2E_PAYLOAD_DIR/adapters/ucsi/secure-uuid.txt"
}

selection() {
    contract
    odp_e2e_select_service "$1" || return 1
    [ "$ODP_E2E_SERVICE" = "$1" ]
}
expect "thermal selection remains supported" 0 selection thermal
expect "UCSI selection loads its contracts" 0 selection ucsi
expect "unknown selection rejected" 1 selection battery
expect "empty selection rejected" 1 selection ''

invalid_contract() {
    contract
    printf '%s\n' "$2" >> "$ODP_E2E_PAYLOAD_DIR/adapters/ucsi/$1"
    odp_e2e_select_service ucsi
}
expect "duplicate driver rejected" 1 invalid_contract drivers.txt driver-qemui2c-ARM64-Release
expect "wrong architecture rejected" 1 invalid_contract drivers.txt driver-HIDTime-x64-Release
expect "multiple UUIDs rejected" 1 invalid_contract secure-uuid.txt "$UUID"

result_fixture() {
    contract
    ODP_E2E_SERVICE="$1"
    ODP_E2E_SECURE_UUID="$UUID"
    printf '%s\r\n' "$ODP_E2E_PASS_LINE" > "$WORK_DIR/result.txt"
    printf '0\n' > "$WORK_DIR/qemu-status.txt"
    if [ "$1" = thermal ]; then
        printf '%s\r\n' '[test] PASS L1: thermal read' \
            '[test] SUMMARY C:\odp-e2e\thermal.test: 1 passed, 0 failed (total 1)' \
            > "$WORK_DIR/service.log"
        printf 'Starting uart service\n' > "$WORK_DIR/runtime.log"
    else
        printf 'UCSI SUMMARY: 4 passed, 0 failed\r\n' > "$WORK_DIR/service.log"
        printf 'TRACE msg_loop: request: MsgSendDirectReq2(DirectMessage { source_id: 0, destination_id: 32770, uuid: %s, payload: DirectMessagePayload([0]) })\n' \
            "$UUID" > "$WORK_DIR/runtime.log"
    fi
}
verify_fixture() {
    odp_e2e_verify_result "$WORK_DIR/result.txt" "$WORK_DIR/service.log" \
        "$WORK_DIR/runtime.log" "$WORK_DIR/qemu-status.txt"
}
result_case() {
    result_fixture "$1" || return 1
    case "$2" in
        valid) ;;
        no-pass) rm "$WORK_DIR/result.txt" ;;
        no-summary) rm "$WORK_DIR/service.log" ;;
        fail) printf 'FAIL: Windows ACPI E2E\n' > "$WORK_DIR/result.txt" ;;
        truncated) printf 'UCSI SUMMARY: 3 passed, 0 failed\n' > "$WORK_DIR/service.log" ;;
        false-pass) printf '\nFAIL: assertion failed\n' >> "$WORK_DIR/service.log" ;;
        nonzero) printf '1\n' > "$WORK_DIR/qemu-status.txt" ;;
        no-runtime) rm "$WORK_DIR/runtime.log" ;;
        static) printf 'EC_SVC_UCSI %s\n' "$UUID" > "$WORK_DIR/runtime.log" ;;
        response) printf 'msg_loop: response: MsgSendDirectResp2 uuid: %s\n' "$UUID" > "$WORK_DIR/runtime.log" ;;
        wrong-uuid) printf 'msg_loop: request: MsgSendDirectReq2(DirectMessage { uuid: 00000000-0000-0000-0000-000000000000, payload: [] })\n' > "$WORK_DIR/runtime.log" ;;
        incomplete-thermal) printf '[test] PASS L1: thermal read\n' > "$WORK_DIR/service.log" ;;
    esac
    verify_fixture
}
expect "complete UCSI result and request trace accepted without EC" 0 result_case ucsi valid
expect "missing common result rejected" 1 result_case ucsi no-pass
expect "missing UCSI output rejected" 1 result_case ucsi no-summary
expect "common failure result rejected" 1 result_case ucsi fail
expect "truncated UCSI summary rejected" 1 result_case ucsi truncated
expect "failure output cannot accompany success" 1 result_case ucsi false-pass
expect "nonzero QEMU exit rejected" 1 result_case ucsi nonzero
expect "absent secure request rejected" 1 result_case ucsi no-runtime
expect "static UUID is not execution evidence" 1 result_case ucsi static
expect "response UUID is not request evidence" 1 result_case ucsi response
expect "unrelated secure service request rejected" 1 result_case ucsi wrong-uuid
expect "unchanged full thermal output accepted" 0 result_case thermal valid
expect "thermal still requires live EC marker" 1 result_case thermal no-runtime
expect "thermal still requires exact summary" 1 result_case thermal incomplete-thermal

execution_fixture() {
    local service="$1"
    result_fixture "$service"
    ODP_E2E_REPO_ROOT="$WORK_DIR/repo"
    rm -rf -- "$WORK_DIR/repo"
    ODP_E2E_SECURE_MANIFEST="$ODP_E2E_REPO_ROOT/manifest.dts"
    ODP_E2E_CACHE_DIR="$ODP_E2E_REPO_ROOT/cache"
    RUN_DIR="$ODP_E2E_CACHE_DIR/runs/$service"
    mkdir -p "$RUN_DIR" "$ODP_E2E_CACHE_DIR/validated" \
        "$ODP_E2E_REPO_ROOT/mod/uefi/patina-qemu"
    WINDOWS_ACPI_E2E_BASE_IMAGE="$ODP_E2E_REPO_ROOT/base.vhdx"
    printf 'immutable base\n' > "$WINDOWS_ACPI_E2E_BASE_IMAGE"
    printf 'build=28000\ncli=C:\\ectest\\ec-test-cli.exe\n' \
        > "$ODP_E2E_CACHE_DIR/validated/$(sha256sum "$WINDOWS_ACPI_E2E_BASE_IMAGE" | awk '{print $1}')"
    cat > "$ODP_E2E_SECURE_MANIFEST" <<'EOF'
uuid = <0xa76df531 0x724d3c59 0xc78fb3a4 0x73c01a17>,
       <0x507f4665 0x4f4e7f82 0xf4db7087 0x457ff7c3>;
id = <0x8002>;
messaging-method = <0x603>;
EOF
    cat > "$ODP_E2E_REPO_ROOT/Makefile" <<'EOF'
.PHONY: ec uefi
ec uefi:
	@echo $@ >> builds
EOF
    cat > "$ODP_E2E_REPO_ROOT/mod/uefi/Makefile" <<EOF
EC_I2C_SOCK ?= /tmp/default-i2c
EC_GPIO_SOCK ?= /tmp/default-gpio
EC_UART_SOCK ?= /tmp/default-uart
ODP_E2E_EC_PTY ?=
run:
	@mkdir -p "\$(dir \$(ODP_E2E_SERIAL0_LOG))"; : > "\$(ODP_E2E_SERIAL0_LOG)"
	@env REAL_QEMU="$WORK_DIR/qemu-spy" EC_I2C_SOCK=\$(EC_I2C_SOCK) EC_GPIO_SOCK=\$(EC_GPIO_SOCK) EC_UART_SOCK=\$(EC_UART_SOCK) \\
	  \$(if \$(ODP_E2E_EC_PTY),ODP_E2E_EC_PTY=\$(ODP_E2E_EC_PTY),) \\
	  QEMU_DISPLAY=\$(QEMU_DISPLAY) ODP_E2E_QEMU_PID_FILE=\$(ODP_E2E_QEMU_PID_FILE) \\
	  ODP_E2E_SERIAL0_LOG=\$(ODP_E2E_SERIAL0_LOG) \\
	  "$SCRIPT_DIR/../qemu-ec-wrapper.sh" -serial stdio -serial file:\$(CURDIR)/patina-qemu/secure_mm.log
EOF
    cat > "$WORK_DIR/qemu-spy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SPY_DIR/qemu.args"
env > "$SPY_DIR/qemu.env"
uart=0
while [ "$#" -gt 0 ]; do
    if [ "$1" = -serial ]; then
        case "$2" in
            file:*)
                log="${2#file:}"
                : > "$log"
                if [ "${QEMU_EMIT_TRACE:-1}" = 1 ] && [ "$uart" = "${QEMU_TRACE_UART:-0}" ]; then
                    cat "$SPY_DIR/runtime.log" >> "$log"
                fi
                ;;
        esac
        uart=$((uart + 1))
        shift 2
    else
        shift
    fi
done
exit "${QEMU_EXIT:-0}"
EOF
    chmod +x "$WORK_DIR/qemu-spy"
    SPY_DIR="$WORK_DIR"
    export SPY_DIR
    : > "$WORK_DIR/guestfish.calls"
    : > "$WORK_DIR/cargo.calls"
    rm -f "$WORK_DIR/qemu.args" "$WORK_DIR/qemu.env" \
        "$WORK_DIR/ec-started" "$WORK_DIR/ec-pty" "$ODP_E2E_REPO_ROOT/builds"
    DRIVER_STORE_LIST=$'pl061gpio.inf_arm64_1111\nqemui2c.inf_arm64_2222\nectest.inf_arm64_3333\nhidtime.inf_arm64_4444'
    qemu-img() {
        case "$1" in
            info) printf '{"format":"vhdx"}\n' ;;
            create) printf 'overlay\n' > "${!#}" ;;
            *) return 1 ;;
        esac
    }
    guestfish() {
        printf '%s\n' "$@" >> "$WORK_DIR/guestfish.calls"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                ls) printf '%s\n' "$DRIVER_STORE_LIST"; return ;;
                is-file) printf '%s\n' "${DRIVER_FILE_PRESENT:-true}"; return ;;
                upload) [ -f "$2" ] || return 1; shift 2 ;;
                download)
                    case "$2" in
                        /odp-e2e/result.txt) cp "$WORK_DIR/result.txt" "$3" || return 1 ;;
                        /odp-e2e/*.log) cp "$WORK_DIR/service.log" "$3" || return 1 ;;
                        *.sys) printf '%s\n' "${DRIVER_MACHINE:-ARM64}" > "$3" ;;
                        *.inf) printf '[Version]\nSignature="$WINDOWS NT$"\n' > "$3" ;;
                        *) return 1 ;;
                    esac
                    shift 2
                    ;;
            esac
            shift
        done
    }
    virt-win-reg() { cat > "$WORK_DIR/startup.reg"; }
    iasl() {
        [ "$1" = -tc ] && [ "$2" = -p ] || return 1
        printf 'current AML\n' > "$3.aml"
    }
    cargo() {
        printf '%s\n' "$*" >> "$WORK_DIR/cargo.calls"
        case "$1" in
            xwin)
                echo "building current smoke"
                [ "${SMOKE_BUILD_FAIL:-0}" = 0 ] || return 1
                mkdir -p "$WORK_DIR/target/aarch64-pc-windows-msvc/release"
                printf '%s\n' "${SMOKE_MACHINE:-ARM64}" \
                    > "$WORK_DIR/target/aarch64-pc-windows-msvc/release/smoke.exe"
                ;;
            metadata) printf '{"target_directory":"%s/target"}\n' "$WORK_DIR" ;;
            *) return 1 ;;
        esac
    }
    llvm-readobj() {
        [ "$1" = --file-headers ] || return 1
        printf 'Format: COFF-%s\n  Machine: IMAGE_FILE_MACHINE_%s (0xAA64)\n' \
            "$(cat "$2")" "$(cat "$2")"
        printf 'ImageOptionalHeader {\n}\n'
    }
    start_ec_qemu() {
        : > "$WORK_DIR/ec-started"
        printf 'Starting uart service\n' > "$4"
    }
    discover_ec_pty() { : > "$WORK_DIR/ec-pty"; printf '/dev/pts/123\n'; }
    cp "$SCRIPT_DIR/../../postbuild/os/windows-acpi-e2e/run.cmd" "$ODP_E2E_PAYLOAD_DIR/run.cmd"
    printf 'thermal test\n' > "$ODP_E2E_PAYLOAD_DIR/thermal.test"
    odp_e2e_select_service "$service"
}
execute_fixture() {
    odp_e2e_execute "$RUN_DIR" "$ODP_E2E_CACHE_DIR" owner/repo latest 5
}
no_ec_run() {
    execution_fixture ucsi || return 1
    export EC_I2C_SOCK=/tmp/inherited-i2c EC_GPIO_SOCK=/tmp/inherited-gpio
    export EC_UART_SOCK=/tmp/inherited-uart ODP_E2E_EC_PTY="${1-/dev/pts/999}"
    execute_fixture || return 1
    [ "$(cat "$ODP_E2E_REPO_ROOT/builds")" = uefi ] || return 1
    [ ! -e "$WORK_DIR/ec-started" ] && [ ! -e "$WORK_DIR/ec-pty" ] || return 1
    ! grep -Eq '^ODP_E2E_EC_PTY=|^EC_(I2C|GPIO|UART)_SOCK=.+' "$WORK_DIR/qemu.env" || return 1
    ! grep -Eq 'ec-i2c-controller|gpio0|ec-uart|odp-e2e-ec-link' "$WORK_DIR/qemu.args" || return 1
    [ "$(head -n 4 "$WORK_DIR/qemu.args")" = \
        $'-serial\n'"file:$RUN_DIR/serial0.log"$'\n-serial\n'"file:$ODP_E2E_REPO_ROOT/mod/uefi/patina-qemu/secure_mm.log" ] || return 1
    grep -qx 'EC_I2C_SOCK=' "$WORK_DIR/qemu.env" \
        && grep -qx 'EC_GPIO_SOCK=' "$WORK_DIR/qemu.env" \
        && grep -qx 'EC_UART_SOCK=' "$WORK_DIR/qemu.env" \
        && grep -qF "$UUID" "$RUN_DIR/boot.log" \
        && cmp "$WORK_DIR/runtime.log" "$RUN_DIR/serial0.log" \
        && [ -f "$RUN_DIR/secure_mm.log" ] && [ ! -s "$RUN_DIR/secure_mm.log" ] \
        && grep -qxF "xwin build --locked --release --target aarch64-pc-windows-msvc --manifest-path $ODP_E2E_PAYLOAD_DIR/adapters/ucsi/smoke/Cargo.toml" "$WORK_DIR/cargo.calls" \
        && grep -qx '/odp-e2e/smoke.exe' "$WORK_DIR/guestfish.calls" \
        && grep -q 'EC_UART_SOCK=' "$RUN_DIR/qemu-command.txt" \
        && grep -q 'run.cmd ucsi' "$WORK_DIR/startup.reg"
}
expect "UCSI accepts UART0 request with only UEFI and no EC wiring or PTY" 0 no_ec_run
expect "inherited empty PTY is removed, not forwarded to wrapper" 0 no_ec_run ''

wrong_uart_request() {
    execution_fixture ucsi || return 1
    export QEMU_TRACE_UART=1
    execute_fixture && return 1
    cmp "$WORK_DIR/runtime.log" "$RUN_DIR/secure_mm.log" \
        && [ ! -s "$RUN_DIR/serial0.log" ] \
        && ! grep -qF "$UUID" "$RUN_DIR/boot.log"
}
expect "UART1-only request cannot satisfy UCSI runtime proof" 0 wrong_uart_request

thermal_run() {
    execution_fixture thermal || return 1
    execute_fixture || return 1
    [ "$(cat "$ODP_E2E_REPO_ROOT/builds")" = $'ec\nuefi' ] \
        && [ -f "$WORK_DIR/ec-started" ] && [ -f "$WORK_DIR/ec-pty" ] \
        && grep -q 'serial,id=odp-e2e-ec-link,path=/dev/pts/123' "$WORK_DIR/qemu.args" \
        && ! grep -q xwin "$WORK_DIR/cargo.calls"
}
expect "default thermal keeps EC build, sidecar and PTY" 0 thermal_run

cached_base_missing_driver() {
    execution_fixture ucsi || return 1
    DRIVER_STORE_LIST=hidtime.inf_arm64_4444
    execute_fixture && return 1
    [ ! -f "$WORK_DIR/qemu.args" ] && grep -q FileRepository "$WORK_DIR/guestfish.calls"
}
expect "thermal validation marker cannot skip UCSI driver inventory" 0 cached_base_missing_driver

bad_driver_binary() {
    execution_fixture ucsi || return 1
    DRIVER_MACHINE=AMD64
    execute_fixture && return 1
    [ ! -f "$WORK_DIR/qemu.args" ]
}
expect "ARM64 package folder cannot disguise an x64 driver" 0 bad_driver_binary

bad_smoke_binary() {
    execution_fixture ucsi || return 1
    SMOKE_MACHINE=AMD64
    execute_fixture && return 1
    [ ! -f "$WORK_DIR/qemu.args" ] && grep -q AMD64 "$RUN_DIR/smoke-pe.txt"
}
expect "non-ARM64 smoke cannot launch" 0 bad_smoke_binary

failed_smoke_build() {
    execution_fixture ucsi || return 1
    mkdir -p "$WORK_DIR/target/aarch64-pc-windows-msvc/release"
    printf 'old executable\n' > "$WORK_DIR/target/aarch64-pc-windows-msvc/release/smoke.exe"
    SMOKE_BUILD_FAIL=1
    execute_fixture && return 1
    [ ! -f "$WORK_DIR/qemu.args" ] \
        && ! grep -q '/odp-e2e/smoke.exe' "$WORK_DIR/guestfish.calls" \
        && grep -q 'building current smoke' "$RUN_DIR/smoke-build.log"
}
expect "failed current smoke build cannot launch or inject stale executable" 0 failed_smoke_build

inherited_make_pty() {
    execution_fixture ucsi || return 1
    export MAKEFLAGS='-- ODP_E2E_EC_PTY=/dev/pts/999'
    execute_fixture && return 1
    [ ! -f "$WORK_DIR/qemu.args" ]
}
expect "inherited Make PTY override cannot enable EC" 0 inherited_make_pty

inherited_makefile_pty() {
    execution_fixture ucsi || return 1
    printf 'ODP_E2E_EC_PTY=/dev/pts/999\n' > "$WORK_DIR/extra.mk"
    export MAKEFILES="$WORK_DIR/extra.mk"
    execute_fixture && return 1
    [ ! -f "$WORK_DIR/qemu.args" ]
}
expect "inherited Make include cannot silently restore EC PTY" 0 inherited_makefile_pty

preflight() {
    ODP_E2E_SERVICE="$1"
    command() {
        if [ "$1" = -v ]; then
            printf '%s\n' "$2" >> "$WORK_DIR/tools"
            case "$2" in defmt-print|qemu-system-riscv32) return 1 ;; esac
            return 0
        fi
        builtin command "$@"
    }
    : > "$WORK_DIR/tools"
    odp_e2e_require_tools
}
expect "UCSI preflight does not require RISC-V QEMU or defmt" 0 preflight ucsi
expect "thermal preflight still requires EC tools" 1 preflight thermal

long_cache_run() {
    local service="$1" long_cache
    execution_fixture "$service" || return 1
    long_cache="$ODP_E2E_REPO_ROOT/$(printf '%0100d' 0)"
    mv "$ODP_E2E_CACHE_DIR" "$long_cache"
    WINDOWS_ACPI_E2E_CACHE_DIR="$long_cache"
    WINDOWS_ACPI_E2E_SERVICE="$service"
    IN_DEVCONTAINER=1
    command() {
        [ "$1" != -v ] || return 0
        builtin command "$@"
    }
    libguestfs-test-tool() { return 0; }
    odp_e2e_main
}
expect "UCSI main skips EC UNIX socket path validation" 0 long_cache_run ucsi
expect "thermal main retains EC UNIX socket path validation" 1 long_cache_run thermal

manifest_contract() {
    execution_fixture ucsi || return 1
    odp_e2e_verify_secure_manifest "$ODP_E2E_SECURE_MANIFEST" || return 1
    printf '65467f50-827f-4e4f-8770-dbf4c3f77f46\n' \
        > "$ODP_E2E_PAYLOAD_DIR/adapters/ucsi/secure-uuid.txt"
    odp_e2e_select_service ucsi || return 1
    odp_e2e_verify_secure_manifest "$ODP_E2E_SECURE_MANIFEST" && return 1
    return 0
}
expect "manifest routing uses the adapter UUID rather than a duplicate constant" 0 manifest_contract

missing_result_extraction() {
    execution_fixture ucsi || return 1
    rm "$WORK_DIR/result.txt"
    odp_e2e_extract_results ignored-overlay "$RUN_DIR" && return 1
    [ -s "$RUN_DIR/ucsi.log" ]
}
expect "missing PASS file still extracts guest failure diagnostics" 0 missing_result_extraction

stale_request_run() {
    execution_fixture ucsi || return 1
    cp "$WORK_DIR/runtime.log" "$RUN_DIR/serial0.log"
    cp "$WORK_DIR/runtime.log" "$ODP_E2E_REPO_ROOT/mod/uefi/patina-qemu/secure_mm.log"
    export QEMU_EMIT_TRACE=0
    execute_fixture && return 1
    [ ! -s "$RUN_DIR/serial0.log" ] && [ ! -s "$RUN_DIR/secure_mm.log" ] \
        && [ -f "$RUN_DIR/result.txt" ]
}
expect "previous-run secure request cannot satisfy current-run proof" 0 stale_request_run

retain_artifacts() {
    local outcome="$1" evidence
    execution_fixture ucsi || return 1
    [ "$outcome" != failure ] || export QEMU_EXIT=1
    if execute_fixture; then
        [ "$outcome" = success ] || return 1
    else
        [ "$outcome" = failure ] || return 1
    fi
    evidence="$ODP_E2E_CACHE_DIR/evidence"
    odp_e2e_finish_run "$RUN_DIR" "$evidence" "$outcome" || return 1
    [ -f "$evidence/ucsi/ucsi.log" ] && [ -f "$evidence/ucsi/smoke-build.log" ] \
        && [ -f "$evidence/ucsi/smoke.exe.sha256" ] \
        && [ -f "$evidence/ucsi/driver-inventory.txt" ] \
        && [ -f "$evidence/ucsi/qemu-command.txt" ] \
        && cmp "$WORK_DIR/runtime.log" "$evidence/ucsi/serial0.log" \
        && [ -f "$evidence/ucsi/secure_mm.log" ] || return 1
    if [ "$outcome" = success ]; then
        [ ! -e "$RUN_DIR" ]
    else
        [ -f "$RUN_DIR/overlay.qcow2" ]
    fi
}
expect "success retains UCSI evidence and removes disposable run" 0 retain_artifacts success
expect "failure retains UCSI evidence and disposable overlay" 0 retain_artifacts failure

failed_evidence_copy() {
    execution_fixture ucsi || return 1
    execute_fixture || return 1
    cp() { return 1; }
    odp_e2e_finish_run "$RUN_DIR" "$ODP_E2E_CACHE_DIR/evidence" success && return 1
    [ -f "$RUN_DIR/overlay.qcow2" ]
}
expect "failed evidence copy must not discard the disposable run" 0 failed_evidence_copy

echo "1..$CASE"
if [ "$FAILURES" -ne 0 ]; then
    echo "FAILED: $FAILURES case(s)" >&2
    exit 1
fi
echo "All $CASE Windows ACPI runner cases passed"
