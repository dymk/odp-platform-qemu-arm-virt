#!/usr/bin/env bash
# Thermal adapter contracts for the Windows/ACPI E2E framework.
#
# SPDX-License-Identifier: MIT

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTER="$REPO_ROOT/postbuild/os/windows-acpi-e2e/adapters/thermal"
SMOKE="$ADAPTER/smoke"
SOURCE="$SMOKE/src/main.rs"
EC_ASL="$REPO_ROOT/mod/uefi/platform/QemuArmVirtPkg/AcpiTables/ec.asl"
README="$REPO_ROOT/postbuild/os/README.md"

TESTS_RUN=0
TESTS_FAILED=0

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
    local desc="$1" pattern="$2"
    shift 2
    if grep -Eiq -- "$pattern" "$@" 2>/dev/null; then fail "$desc"; else ok "$desc"; fi
}

expect_exact_file() {
    local desc="$1" file="$2" expected="$3"
    if [ -f "$file" ] && [ "$(cat "$file")" = "$expected" ]; then
        ok "$desc"
    else
        fail "$desc"
    fi
}

echo "== thermal adapter schema =="
for required in smoke/Cargo.toml smoke/Cargo.lock smoke/rust-toolchain.toml \
    smoke/src/main.rs drivers.txt secure-uuid.txt needs-ec-sidecar; do
    expect_pass "thermal adapter has $required" test -f "$ADAPTER/$required"
done
expect_pass "EC sidecar marker is empty" bash -c \
    'test -f "$1" && test ! -s "$1"' _ "$ADAPTER/needs-ec-sidecar"
expect_exact_file "thermal service UUID is exact" "$ADAPTER/secure-uuid.txt" \
    "31f56da7-593c-4d72-a4b3-8fc7171ac073"
expect_exact_file "thermal driver list is exact" "$ADAPTER/drivers.txt" \
    $'driver-pl061gpio-ARM64-Release\ndriver-qemui2c-ARM64-Release\ndriver-ectest_kmdf-ARM64-Release'

expect_pass "smoke manifest is isolated and exact" python3 - "$SMOKE/Cargo.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as manifest:
    data = tomllib.load(manifest)

assert data["package"]["rust-version"] == "1.90"
assert data.get("workspace") == {}
assert data["dependencies"] == {
    "windows-acpi-e2e-guest-support": {"path": "../../../guest-support"}
}
assert data.get("bin") == [{"name": "smoke", "path": "src/main.rs"}]
PY
expect_exact_file "smoke toolchain is Rust 1.90" "$SMOKE/rust-toolchain.toml" \
    $'[toolchain]\nchannel = "1.90.0"\nprofile = "minimal"'

echo "== thermal smoke contract =="
expect_contains "smoke uses guest run wrapper" "$SOURCE" \
    'windows_acpi_e2e_guest_support::run\(\|\|'
expect_contains "smoke evaluates SKIN temperature" "$SOURCE" \
    'evaluate_u32\(r"\\+_SB\.SKIN\._TMP"\)'
expect_contains "smoke accepts the required inclusive range" "$SOURCE" \
    '\(2900\.\.=3200\)\.contains\(&temperature\)'
expect_contains "smoke reports an out-of-range temperature" "$SOURCE" \
    'outside 2900\.\.=3200 deciKelvin'
expect_contains "unit test accepts minimum" "$SOURCE" 'accepts_minimum_temperature'
expect_contains "unit test accepts maximum" "$SOURCE" 'accepts_maximum_temperature'
expect_contains "unit test rejects below minimum" "$SOURCE" 'rejects_temperature_below_minimum'
expect_contains "unit test rejects above maximum" "$SOURCE" 'rejects_temperature_above_maximum'

echo "== thermal ACPI and documentation =="
expect_contains "FF-A ACPI include is enabled" "$EC_ASL" \
    '^[[:space:]]*#include "ffa\.asl"'
expect_contains "thermal ACPI include is enabled" "$EC_ASL" \
    '^[[:space:]]*#include "thermal\.asl"'
expect_contains "battery ACPI include remains disabled" "$EC_ASL" \
    '^[[:space:]]*//#include "battery\.asl"'
expect_contains "RTC ACPI include remains disabled" "$EC_ASL" \
    '^[[:space:]]*//#include "rtc\.asl"'
expect_not_contains "thermal changes contain no UCSI symbols" 'ucsi' \
    "$ADAPTER/drivers.txt" "$ADAPTER/secure-uuid.txt" "$SOURCE" "$EC_ASL"
expect_contains "README has thermal adapter command" "$README" \
    '--adapter postbuild/os/windows-acpi-e2e/adapters/thermal'

echo
printf 'ran %d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
