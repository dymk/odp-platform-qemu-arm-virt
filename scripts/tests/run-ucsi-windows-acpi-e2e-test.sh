#!/usr/bin/env bash
# UCSI adapter contracts for the Windows/ACPI E2E framework.
#
# SPDX-License-Identifier: MIT

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GENERIC="$REPO_ROOT/scripts/run-windows-acpi-e2e.sh"
LAUNCHER="$REPO_ROOT/scripts/run-ucsi-windows-acpi-e2e.sh"
ADAPTER="$REPO_ROOT/postbuild/os/windows-acpi-e2e/adapters/ucsi"
SMOKE="$ADAPTER/smoke"
SOURCE="$SMOKE/src/main.rs"
README="$ADAPTER/README.md"
EC_ASL="$REPO_ROOT/mod/uefi/platform/QemuArmVirtPkg/AcpiTables/ec.asl"
SCRATCH="$REPO_ROOT/postbuild/os/build/ucsi-adapter-tests-$$"

TESTS_RUN=0
TESTS_FAILED=0
mkdir -p "$SCRATCH"
trap 'rm -rf -- "$SCRATCH"' EXIT

ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  ok: %s\n' "$1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  NOT OK: %s\n' "$1" >&2
}

expect_pass() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

expect_contains() {
    local desc="$1" file="$2" pattern="$3"
    if grep -Eq -- "$pattern" "$file" 2>/dev/null; then ok "$desc"; else fail "$desc"; fi
}

expect_not_contains() {
    local desc="$1" file="$2" pattern="$3"
    if grep -Eiq -- "$pattern" "$file" 2>/dev/null; then fail "$desc"; else ok "$desc"; fi
}

expect_exact_file() {
    local desc="$1" file="$2" expected="$3"
    if [ -f "$file" ] && [ "$(cat "$file")" = "$expected" ]; then
        ok "$desc"
    else
        fail "$desc"
    fi
}

echo "== UCSI adapter schema =="
for required in smoke/Cargo.toml smoke/Cargo.lock smoke/rust-toolchain.toml \
    smoke/src/main.rs drivers.txt secure-uuid.txt README.md; do
    expect_pass "UCSI adapter has $required" test -f "$ADAPTER/$required"
done
expect_pass "UCSI adapter has no EC sidecar marker" test ! -e "$ADAPTER/needs-ec-sidecar"
expect_exact_file "UCSI service UUID is exact" "$ADAPTER/secure-uuid.txt" \
    "65467f50-827f-4e4f-8770-dbf4c3f77f45"
expect_exact_file "UCSI driver list is exact" "$ADAPTER/drivers.txt" \
    $'driver-pl061gpio-ARM64-Release\ndriver-qemui2c-ARM64-Release\ndriver-ectest_kmdf-ARM64-Release'

expect_pass "smoke manifest is isolated and exact" python3 - "$SMOKE/Cargo.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as manifest:
    data = tomllib.load(manifest)

assert data["package"]["rust-version"] == "1.90"
assert data.get("workspace") == {}
assert data["dependencies"] == {
    "ec-test-lib": {
        "git": "https://github.com/dymk/odp-platform-common.git",
        "rev": "53c3b6bce6d8f8c359ff0ded9884232d481ee7b1",
    },
    "windows-acpi-e2e-guest-support": {"path": "../../../guest-support"},
}
assert data.get("bin") == [{"name": "smoke", "path": "src/main.rs"}]
PY
expect_exact_file "smoke toolchain is Rust 1.90" "$SMOKE/rust-toolchain.toml" \
    $'[toolchain]\nchannel = "1.90.0"\nprofile = "minimal"'

echo "== UCSI smoke contract =="
expect_contains "smoke uses standardized guest run wrapper" "$SOURCE" \
    'windows_acpi_e2e_guest_support::run\(\|\|'
expect_contains "smoke constructs ACPI source zero" "$SOURCE" \
    'Acpi::new\(0\)'
expect_contains "smoke imports UCSI source behavior" "$SOURCE" \
    'UcsiSource'
expect_contains "smoke imports typed power direction" "$SOURCE" \
    'PowerDirection'
expect_contains "smoke requires VERSION 0x0120" "$SOURCE" \
    'UcsiVersion\(0x0120\)'
expect_contains "smoke requires one connector" "$SOURCE" \
    'num_connectors != 1'
expect_contains "smoke requires USB Power Delivery" "$SOURCE" \
    'usb_power_delivery\(\)'
expect_contains "smoke requires USB PD bcd 0x0300" "$SOURCE" \
    'bcd_usb_pd_spec != 0x0300'
expect_contains "smoke requires DRP mode" "$SOURCE" '\.drp\(\)'
expect_contains "smoke requires USB2 mode" "$SOURCE" '\.usb2\(\)'
expect_contains "smoke requires USB3 mode" "$SOURCE" '\.usb3\(\)'
expect_contains "smoke requires provider capability" "$SOURCE" '\.provider\(\)'
expect_contains "smoke requires consumer capability" "$SOURCE" '\.consumer\(\)'
expect_contains "smoke requires connected status" "$SOURCE" '!status\.connect_status'
expect_contains "smoke requires USB partner" "$SOURCE" 'partner_flags\.usb\(\)'
expect_contains "smoke requires sink power direction" "$SOURCE" \
    'connected\.power_direction != PowerDirection::Sink'
expect_not_contains "smoke does not implement result output" "$SOURCE" \
    'result\.txt|OpenOptions|std::fs|write\('
expect_not_contains "smoke does not implement shutdown" "$SOURCE" \
    'shutdown|Command::new|std::process'

echo "== UCSI launcher and generic integration =="
expect_pass "launcher parses as shell" bash -n "$LAUNCHER"
if [ -f "$LAUNCHER" ]; then
    mkdir -p "$SCRATCH/repo/scripts"
    cp "$LAUNCHER" "$SCRATCH/repo/scripts/run-ucsi-windows-acpi-e2e.sh"
    cat > "$SCRATCH/repo/scripts/run-windows-acpi-e2e.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$ODP_E2E_ARGV_LOG"
SH
    chmod +x "$SCRATCH/repo/scripts/"*.sh
    ARGV_LOG="$SCRATCH/argv"
    ODP_E2E_ARGV_LOG="$ARGV_LOG" \
        "$SCRATCH/repo/scripts/run-ucsi-windows-acpi-e2e.sh" \
        --image "image with spaces.qcow2" --keep "" >/dev/null 2>&1
    expect_pass "launcher preserves path and argv exactly" \
        python3 - "$ARGV_LOG" "$SCRATCH/repo" <<'PY'
import sys
from pathlib import Path

actual = Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
expected = [
    b"--adapter",
    str(Path(sys.argv[2]) / "postbuild/os/windows-acpi-e2e/adapters/ucsi").encode(),
    b"--image",
    b"image with spaces.qcow2",
    b"--keep",
    b"",
]
assert actual == expected, (actual, expected)
PY
else
    fail "launcher preserves path and argv exactly"
fi

if [ -f "$GENERIC" ]; then
    # shellcheck source=/dev/null
    ODP_WINDOWS_ACPI_E2E_SOURCE_ONLY=1 source "$GENERIC"
fi
expect_pass "generic validator accepts UCSI adapter" odp_e2e_validate_adapter "$ADAPTER"

echo "== UCSI platform and documentation =="
expect_contains "focused ACPI table exposes UCSI method" "$EC_ASL" \
    'Method\(USND, 1, Serialized\)'
expect_contains "focused ACPI table uses UCSI UUID" "$EC_ASL" \
    '65467f50-827f-4e4f-8770-dbf4c3f77f45'
expect_contains "UCSI README uses thin launcher" "$README" \
    'scripts/run-ucsi-windows-acpi-e2e\.sh'
expect_contains "UCSI README states Windows build floor" "$README" '28000'
expect_contains "UCSI README states dependency stack" "$README" \
    'generic harness.*#143.*#162'

echo
printf 'ran %d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
