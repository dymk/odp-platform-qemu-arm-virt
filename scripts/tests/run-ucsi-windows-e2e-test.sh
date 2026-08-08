#!/usr/bin/env bash
# Unit tests for the pure functions in scripts/run-ucsi-windows-e2e.sh.
#
# SPDX-License-Identifier: MIT
#
# These exercise the library-only surface of the runner (sourced with
# UCSI_WINDOWS_E2E_SOURCE_ONLY=1) with no external processes, network, or
# QEMU. They cover build-gate validation, the deterministic image cache key,
# cached-image selection precedence, guest-result parsing, workflow run-ID
# extraction, and relative overlay backing-path computation.
#
# No test framework: a couple of tiny assert helpers and a pass/fail counter.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD="$(cd "$SCRIPT_DIR/.." && pwd)/run-ucsi-windows-e2e.sh"

TESTS_RUN=0
TESTS_FAILED=0

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  NOT OK: $*" >&2
}

ok() {
    echo "  ok: $*"
}

# assert_have_fn NAME — the named function must be defined (guards RED runs
# against an absent/partial implementation with a clear message).
assert_have_fn() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if declare -F "$1" >/dev/null 2>&1; then
        ok "function defined: $1"
    else
        fail "function not defined: $1"
        return 1
    fi
}

# expect_pass DESC -- cmd... : command must exit 0
expect_pass() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        ok "$desc"
    else
        fail "$desc (expected exit 0, got $?)"
    fi
}

# expect_fail DESC -- cmd... : command must exit non-zero
expect_fail() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        fail "$desc (expected non-zero exit, got 0)"
    else
        ok "$desc"
    fi
}

# expect_eq DESC EXPECTED ACTUAL
expect_eq() {
    local desc="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        ok "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

# expect_ne DESC A B : the two values must differ
expect_ne() {
    local desc="$1" a="$2" b="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$a" != "$b" ]; then
        ok "$desc"
    else
        fail "$desc (expected values to differ, both '$a')"
    fi
}

# ----- source the implementation (library-only) -----
if [ -f "$PROD" ]; then
    # shellcheck source=/dev/null
    UCSI_WINDOWS_E2E_SOURCE_ONLY=1 source "$PROD"
else
    echo "RED: production script not found at $PROD" >&2
fi

# =====================================================================
# (a) build gate: 26100 rejected, 28000 accepted, non-integer rejected
# =====================================================================
echo "== build-gate =="
assert_have_fn ucsi_validate_os_build
expect_fail "build 26100 rejected"        ucsi_validate_os_build 26100
expect_pass "build 28000 accepted"        ucsi_validate_os_build 28000
expect_pass "build 30000 accepted"        ucsi_validate_os_build 30000
expect_fail "build 27999 rejected"        ucsi_validate_os_build 27999
expect_fail "non-integer 'abc' rejected"  ucsi_validate_os_build abc
expect_fail "float '28000.1' rejected"    ucsi_validate_os_build 28000.1
expect_fail "empty rejected"              ucsi_validate_os_build ""

# =====================================================================
# (b) deterministic cache key: changes when each required input changes
# =====================================================================
echo "== cache-key =="
assert_have_fn ucsi_compute_cache_key
# Canonical positional order:
#   SOURCE_ID OS_BUILD DRIVERS_REPO SMOKE_REPO SMOKE_RELEASE \
#   WORKFLOW_REPO WORKFLOW_REF WORKFLOW_HASH
base_args=(https://example/vos.iso 28000 org/drv dymk/common latest dymk/qemu main deadbeef)
BASE_KEY="$(ucsi_compute_cache_key "${base_args[@]}")"
expect_ne "key is non-empty" "$BASE_KEY" ""
SAME_KEY="$(ucsi_compute_cache_key "${base_args[@]}")"
expect_eq "identical inputs -> identical key" "$BASE_KEY" "$SAME_KEY"

# Flip each input in turn; the key must change every time.
declare -a labels=(source os_build drivers_repo smoke_repo smoke_release workflow_repo workflow_ref workflow_hash)
declare -a mutated=(https://example/OTHER.iso 28001 org/OTHERdrv dymk/OTHER other-tag dymk/OTHERqemu other-ref cafef00d)
for i in "${!labels[@]}"; do
    args=("${base_args[@]}")
    args[$i]="${mutated[$i]}"
    k="$(ucsi_compute_cache_key "${args[@]}")"
    expect_ne "key changes when ${labels[$i]} changes" "$BASE_KEY" "$k"
done

# =====================================================================
# (c) cached-image selection: prefer QCOW2 > VHDX, none when absent
# =====================================================================
echo "== select-cached-image =="
assert_have_fn ucsi_select_cached_image
CACHE_TMP="$SCRIPT_DIR/.tmp-cache-$$"
rm -rf "$CACHE_TMP"; mkdir -p "$CACHE_TMP"
KEY="abc123"
# neither present
expect_fail "no image -> non-zero" ucsi_select_cached_image "$CACHE_TMP" "$KEY"
# only vhdx present -> returns vhdx
: > "$CACHE_TMP/$KEY.vhdx"
sel_vhdx="$(ucsi_select_cached_image "$CACHE_TMP" "$KEY")"
expect_eq "only vhdx -> selects vhdx" "$CACHE_TMP/$KEY.vhdx" "$sel_vhdx"
# both present -> prefers qcow2
: > "$CACHE_TMP/$KEY.qcow2"
sel_both="$(ucsi_select_cached_image "$CACHE_TMP" "$KEY")"
expect_eq "both -> prefers qcow2" "$CACHE_TMP/$KEY.qcow2" "$sel_both"
rm -rf "$CACHE_TMP"

# =====================================================================
# (d) result parsing: exact PASS accepted; FAIL/missing/malformed rejected
# =====================================================================
echo "== result-parse =="
assert_have_fn ucsi_check_result_file
RES_TMP="$SCRIPT_DIR/.tmp-res-$$"
rm -rf "$RES_TMP"; mkdir -p "$RES_TMP"
printf 'PASS: UCSI ACPI/FF-A E2E\n' > "$RES_TMP/pass.txt"
expect_pass "exact PASS accepted"  ucsi_check_result_file "$RES_TMP/pass.txt"
# Leading log noise but the exact line present on its own line.
printf 'boot noise\r\nPASS: UCSI ACPI/FF-A E2E\r\n' > "$RES_TMP/pass_crlf.txt"
expect_pass "PASS line among CRLF noise accepted" ucsi_check_result_file "$RES_TMP/pass_crlf.txt"
printf 'FAIL: get_capability: something\n' > "$RES_TMP/fail.txt"
expect_fail "FAIL rejected"        ucsi_check_result_file "$RES_TMP/fail.txt"
printf 'PASS: UCSI ACPI/FF-A E2E extra junk\n' > "$RES_TMP/malformed.txt"
expect_fail "malformed (trailing junk) rejected" ucsi_check_result_file "$RES_TMP/malformed.txt"
printf 'pass: ucsi acpi/ff-a e2e\n' > "$RES_TMP/case.txt"
expect_fail "wrong-case rejected"  ucsi_check_result_file "$RES_TMP/case.txt"
: > "$RES_TMP/empty.txt"
expect_fail "empty rejected"       ucsi_check_result_file "$RES_TMP/empty.txt"
expect_fail "missing file rejected" ucsi_check_result_file "$RES_TMP/nope.txt"
rm -rf "$RES_TMP"

# =====================================================================
# (e) workflow run-ID parsing from `gh workflow run` URL output
# =====================================================================
echo "== run-id-parse =="
assert_have_fn ucsi_parse_run_id
good_out=$'Created workflow_dispatch event for build-os.yml at main\n\nTo see runs for this workflow, try: gh run list --workflow=build-os.yml\nhttps://github.com/dymk/odp-platform-qemu-arm-virt/actions/runs/16543219876'
rid="$(ucsi_parse_run_id "$good_out")"
expect_eq "parses numeric run id" "16543219876" "$rid"
expect_pass "valid URL output -> exit 0" ucsi_parse_run_id "$good_out"
expect_fail "no URL -> non-zero" ucsi_parse_run_id "some unrelated text with no run url"
expect_fail "empty -> non-zero"  ucsi_parse_run_id ""

# =====================================================================
# (f) relative overlay backing path: never an absolute host-only path
# =====================================================================
echo "== relative-backing-path =="
assert_have_fn ucsi_relative_backing_path
# Mirror the real layout: the pristine base lives in the cache dir and the
# disposable overlay lives in a run subdir *under* that same cache dir.
BP_CACHE="$SCRIPT_DIR/.tmp-cache-bp-$$"
BASE="$BP_CACHE/basekey.qcow2"
OVERLAY="$BP_CACHE/run-1/overlay.qcow2"
mkdir -p "$(dirname "$OVERLAY")"
rel="$(ucsi_relative_backing_path "$OVERLAY" "$BASE")"
# Must be a relative path, never an absolute host-only path.
case "$rel" in
    /*) fail "relative backing path must not be absolute (got '$rel')"; TESTS_RUN=$((TESTS_RUN+1)) ;;
    *)  ok "relative backing path is not absolute"; TESTS_RUN=$((TESTS_RUN+1)) ;;
esac
# Must not embed the absolute cache directory path as a prefix.
if printf '%s' "$rel" | grep -qF "$BP_CACHE"; then
    fail "relative backing path must not embed absolute cache path (got '$rel')"
    TESTS_RUN=$((TESTS_RUN+1))
else
    ok "relative backing path does not embed absolute cache path"
    TESTS_RUN=$((TESTS_RUN+1))
fi
expect_eq "relative path is the expected '../basekey.qcow2'" "../basekey.qcow2" "$rel"
# The relative path, resolved from the overlay dir, must point back at BASE.
resolved="$(cd "$(dirname "$OVERLAY")" && realpath -m "$rel")"
expect_eq "relative path resolves back to base" "$(realpath -m "$BASE")" "$resolved"
rm -rf "$BP_CACHE"

# =====================================================================
echo
echo "ran $TESTS_RUN checks, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ]
