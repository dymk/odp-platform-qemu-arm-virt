#!/usr/bin/env bash
# Unit tests for the pure functions in scripts/run-ucsi-windows-e2e.sh.
#
# SPDX-License-Identifier: MIT
#
# These exercise the library-only surface of the runner and static workflow
# contracts without network access or QEMU.
#
# No test framework: a couple of tiny assert helpers and a pass/fail counter.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD="$(cd "$SCRIPT_DIR/.." && pwd)/run-ucsi-windows-e2e.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/build-os.yml"
DOCKERFILE="$REPO_ROOT/.devcontainer/Dockerfile"
SMOKE_DIR="$REPO_ROOT/postbuild/os/ucsi-smoke"
SMOKE_MANIFEST="$SMOKE_DIR/Cargo.toml"
SMOKE_LOCK="$SMOKE_DIR/Cargo.lock"
SMOKE_SOURCE="$SMOKE_DIR/src/main.rs"

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

expect_contains() {
    local desc="$1" file="$2" pattern="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -Eq -- "$pattern" "$file"; then
        ok "$desc"
    else
        fail "$desc (pattern '$pattern' not found in $file)"
    fi
}

expect_not_contains() {
    local desc="$1" file="$2" pattern="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -Eq -- "$pattern" "$file"; then
        fail "$desc (unexpected pattern '$pattern' found in $file)"
    else
        ok "$desc"
    fi
}

expect_order() {
    local desc="$1" file="$2" first="$3" second="$4"
    local first_line second_line
    TESTS_RUN=$((TESTS_RUN + 1))
    first_line="$(grep -nE -- "$first" "$file" | head -n1 | cut -d: -f1)"
    second_line="$(grep -nE -- "$second" "$file" | head -n1 | cut -d: -f1)"
    if [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ]; then
        ok "$desc"
    else
        fail "$desc (expected '$first' before '$second')"
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
#   SOURCE_ID OS_BUILD DRIVERS_REPO DRIVERS_RELEASE DRIVER_ASSET_IDENTITY \
#   WORKFLOW_REPO WORKFLOW_REF WORKFLOW_SHA WORKFLOW_HASH
base_args=(https://example/vos.iso 28000 org/drv latest driver-assets:abc dymk/qemu main \
    1111111111111111111111111111111111111111 deadbeef)
BASE_KEY="$(ucsi_compute_cache_key "${base_args[@]}")"
expect_ne "key is non-empty" "$BASE_KEY" ""
SAME_KEY="$(ucsi_compute_cache_key "${base_args[@]}")"
expect_eq "identical inputs -> identical key" "$BASE_KEY" "$SAME_KEY"
expect_fail "cache key rejects missing workflow SHA" ucsi_compute_cache_key \
    "${base_args[@]:0:7}" "${base_args[8]}"

# Flip each input in turn; the key must change every time.
declare -a labels=(source os_build drivers_repo drivers_release driver_assets workflow_repo workflow_ref workflow_sha workflow_hash)
declare -a mutated=(https://example/OTHER.iso 28001 org/OTHERdrv other-tag driver-assets:def dymk/OTHERqemu other-ref \
    2222222222222222222222222222222222222222 cafef00d)
for i in "${!labels[@]}"; do
    args=("${base_args[@]}")
    args[$i]="${mutated[$i]}"
    k="$(ucsi_compute_cache_key "${args[@]}")"
    expect_ne "key changes when ${labels[$i]} changes" "$BASE_KEY" "$k"
done

# --image identity must be the full file content digest, not metadata.
assert_have_fn ucsi_image_identity
IMAGE_TMP="$SCRIPT_DIR/.tmp-image-identity-$$"
mkdir -p "$IMAGE_TMP/a" "$IMAGE_TMP/b"
printf 'AAAA' > "$IMAGE_TMP/a/same.qcow2"
printf 'BBBB' > "$IMAGE_TMP/b/same.qcow2"
touch -t 202608081822.24 "$IMAGE_TMP/a/same.qcow2" "$IMAGE_TMP/b/same.qcow2"
image_a="$(ucsi_image_identity "$IMAGE_TMP/a/same.qcow2")"
image_b="$(ucsi_image_identity "$IMAGE_TMP/b/same.qcow2")"
expect_ne "same image metadata with different content -> different identity" "$image_a" "$image_b"
expect_eq "image identity is the full SHA-256" \
    "image:$(sha256sum "$IMAGE_TMP/a/same.qcow2" | awk '{print $1}')" "$image_a"
rm -rf "$IMAGE_TMP"

# =====================================================================
# (c) immutable driver asset manifest and identity
# =====================================================================
echo "== driver-assets =="
assert_have_fn ucsi_resolve_driver_asset_manifest
assert_have_fn ucsi_driver_asset_identity
assert_have_fn ucsi_driver_release_endpoint
expect_eq "default latest selects the rolling latest tag" \
    "repos/org/drivers/releases/tags/latest" \
    "$(ucsi_driver_release_endpoint org/drivers latest 2>/dev/null || true)"
expect_eq "explicit driver tag selects that exact release" \
    "repos/org/drivers/releases/tags/v2026.08.08" \
    "$(ucsi_driver_release_endpoint org/drivers v2026.08.08 2>/dev/null || true)"
DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
DRIVER_JSON="$(printf \
    '{"assets":[{"name":"driver-b.zip","id":22,"digest":"%s"},{"name":"unrelated.zip","id":99,"digest":"%s"},{"name":"driver-a.zip","id":11,"digest":"%s"}]}' \
    "$DIGEST_B" "$DIGEST_A" "$DIGEST_A")"
MANIFEST_AB="$(ucsi_resolve_driver_asset_manifest "$DRIVER_JSON" driver-a driver-b 2>/dev/null || true)"
MANIFEST_BA="$(ucsi_resolve_driver_asset_manifest "$DRIVER_JSON" driver-b driver-a 2>/dev/null || true)"
expect_eq "required asset ordering is normalized" "$MANIFEST_AB" "$MANIFEST_BA"
expect_eq "manifest contains sorted immutable asset records" \
    "[{\"name\":\"driver-a.zip\",\"id\":11,\"digest\":\"$DIGEST_A\"},{\"name\":\"driver-b.zip\",\"id\":22,\"digest\":\"$DIGEST_B\"}]" \
    "$MANIFEST_AB"
IDENTITY_AB="$(ucsi_driver_asset_identity "$MANIFEST_AB" 2>/dev/null || true)"
CHANGED_JSON="${DRIVER_JSON/$DIGEST_B/sha256:$(printf 'c%.0s' {1..64})}"
CHANGED_MANIFEST="$(ucsi_resolve_driver_asset_manifest "$CHANGED_JSON" driver-a driver-b 2>/dev/null || true)"
IDENTITY_CHANGED="$(ucsi_driver_asset_identity "$CHANGED_MANIFEST" 2>/dev/null || true)"
expect_ne "asset digest change alters immutable identity" "$IDENTITY_AB" "$IDENTITY_CHANGED"
expect_fail "missing required driver asset fails" \
    ucsi_resolve_driver_asset_manifest "$DRIVER_JSON" driver-a driver-missing
DIGESTLESS_JSON='{"assets":[{"name":"driver-a.zip","id":11,"digest":null}]}'
expect_fail "digestless required driver asset fails" \
    ucsi_resolve_driver_asset_manifest "$DIGESTLESS_JSON" driver-a

# =====================================================================
# (d) cached-image selection validates entries before reuse
# =====================================================================
echo "== select-cached-image =="
assert_have_fn ucsi_select_cached_image
CACHE_TMP="$SCRIPT_DIR/.tmp-cache-$$"
rm -rf "$CACHE_TMP"; mkdir -p "$CACHE_TMP"
KEY="abc123"
expect_fail "no image -> non-zero" ucsi_select_cached_image "$CACHE_TMP" "$KEY"
printf 'interrupted conversion' > "$CACHE_TMP/$KEY.qcow2"
expect_fail "invalid partial final image is not a cache hit" \
    ucsi_select_cached_image "$CACHE_TMP" "$KEY"
expect_pass "invalid partial final image is removed" test ! -e "$CACHE_TMP/$KEY.qcow2"
if command -v qemu-img >/dev/null 2>&1; then
    qemu-img create -q -f qcow2 "$CACHE_TMP/$KEY.qcow2" 1M
    selected="$(ucsi_select_cached_image "$CACHE_TMP" "$KEY")"
    expect_eq "valid qcow2 is selected" "$CACHE_TMP/$KEY.qcow2" "$selected"
fi
rm -rf "$CACHE_TMP"

# =====================================================================
# (e) atomic cache publication
# =====================================================================
echo "== atomic-publication =="
assert_have_fn ucsi_atomic_convert
if declare -F ucsi_atomic_convert >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
    ATOMIC_TMP="$SCRIPT_DIR/.tmp-atomic-$$"
    mkdir -p "$ATOMIC_TMP"
    qemu-img create -q -f qcow2 "$ATOMIC_TMP/source.qcow2" 1M
    printf 'invalid old cache' > "$ATOMIC_TMP/final.qcow2"
    expect_pass "qcow2 conversion publishes a validated final image" \
        ucsi_atomic_convert qcow2 "$ATOMIC_TMP/source.qcow2" "$ATOMIC_TMP/final.qcow2"
    expect_pass "published image passes qemu-img check" \
        qemu-img check -q "$ATOMIC_TMP/final.qcow2"
    expect_fail "successful publication leaves no sibling temporary image" \
        compgen -G "$ATOMIC_TMP/final.qcow2.tmp.*"

    mkdir -p "$ATOMIC_TMP/fake-bin"
    REAL_QEMU_IMG="$(command -v qemu-img)"
    cat > "$ATOMIC_TMP/fake-bin/qemu-img" <<EOF
#!/usr/bin/env bash
if [ "\$1" = convert ]; then
    printf partial > "\${@: -1}"
    exit 1
fi
exec "$REAL_QEMU_IMG" "\$@"
EOF
    chmod +x "$ATOMIC_TMP/fake-bin/qemu-img"
    rm -f "$ATOMIC_TMP/failed.qcow2"
    expect_fail "interrupted conversion fails" env PATH="$ATOMIC_TMP/fake-bin:$PATH" \
        bash -c 'UCSI_WINDOWS_E2E_SOURCE_ONLY=1 source "$1"; ucsi_atomic_convert qcow2 "$2" "$3"' \
        bash "$PROD" "$ATOMIC_TMP/source.qcow2" "$ATOMIC_TMP/failed.qcow2"
    expect_pass "interrupted conversion publishes no final image" \
        test ! -e "$ATOMIC_TMP/failed.qcow2"
    expect_fail "interrupted conversion removes sibling temporary image" \
        compgen -G "$ATOMIC_TMP/failed.qcow2.tmp.*"
    rm -rf "$ATOMIC_TMP"
fi

# =====================================================================
# (f) result parsing: exact PASS accepted; FAIL/missing/malformed rejected
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
# (g) workflow run-ID parsing from `gh workflow run` URL output
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
# (h) nonce matching: select only the exact workflow_dispatch title
# =====================================================================
echo "== dispatch-nonce =="
assert_have_fn ucsi_dispatch_run_title
assert_have_fn ucsi_select_nonce_run_id
NONCE='ucsi-1723130000000000000-1234-7'
WORKFLOW_SHA='1111111111111111111111111111111111111111'
TITLE="$(ucsi_dispatch_run_title "$NONCE" 2>/dev/null || true)"
expect_eq "dispatch title incorporates nonce" "build_os_image [$NONCE]" "$TITLE"
RUNS_JSON="$(printf \
    '[{"databaseId":11,"event":"workflow_dispatch","displayTitle":"other","headSha":"%s"},
{"databaseId":22,"event":"push","displayTitle":"%s","headSha":"%s"},
{"databaseId":33,"event":"workflow_dispatch","displayTitle":"%s","headSha":"%s"}]' \
    "$WORKFLOW_SHA" "$TITLE" "$WORKFLOW_SHA" "$TITLE" "$WORKFLOW_SHA")"
matched_id="$(ucsi_select_nonce_run_id "$RUNS_JSON" "$NONCE" "$WORKFLOW_SHA" 2>/dev/null || true)"
expect_eq "selects exact nonce-titled workflow_dispatch run" "33" "$matched_id"
expect_fail "rejects JSON with no matching nonce" ucsi_select_nonce_run_id \
    "$(printf '[{"databaseId":44,"event":"workflow_dispatch","displayTitle":"build_os_image [other]","headSha":"%s"}]' "$WORKFLOW_SHA")" \
    "$NONCE" "$WORKFLOW_SHA"
expect_fail "rejects nonce title on non-dispatch event" ucsi_select_nonce_run_id \
    "$(printf '[{"databaseId":55,"event":"push","displayTitle":"%s","headSha":"%s"}]' "$TITLE" "$WORKFLOW_SHA")" \
    "$NONCE" "$WORKFLOW_SHA"
expect_fail "rejects matching nonce from a different source SHA" ucsi_select_nonce_run_id \
    "$(printf '[{"databaseId":66,"event":"workflow_dispatch","displayTitle":"%s","headSha":"2222222222222222222222222222222222222222"}]' "$TITLE")" \
    "$NONCE" "$WORKFLOW_SHA"

# =====================================================================
# (i) relative overlay backing path: never an absolute host-only path
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
# (j) input validation
# =====================================================================
echo "== input-validation =="
assert_have_fn ucsi_validate_repo_name
expect_pass "owner/repo accepted" ucsi_validate_repo_name OpenDevicePartnership/odp-windows-drivers
expect_pass "repository punctuation accepted" ucsi_validate_repo_name dymk/repo.name_2
expect_fail "repository without owner rejected" ucsi_validate_repo_name repo
expect_fail "repository shell syntax rejected" ucsi_validate_repo_name 'owner/repo;Write-Host-pwned'
expect_fail "repository expression syntax rejected" ucsi_validate_repo_name 'owner/${{bad}}'

assert_have_fn ucsi_validate_safe_token
expect_pass "release tag accepted" ucsi_validate_safe_token v2026.08.08
expect_pass "dispatch nonce accepted" ucsi_validate_safe_token "$NONCE"
expect_fail "empty token rejected" ucsi_validate_safe_token ""
expect_fail "token whitespace rejected" ucsi_validate_safe_token "unsafe value"
expect_fail "token PowerShell syntax rejected" ucsi_validate_safe_token '$(Get-ChildItem)'

# =====================================================================
# (k) firmware stamp and reuse decision
# =====================================================================
echo "== firmware-cache =="
assert_have_fn ucsi_compose_firmware_stamp
STAMP="$(ucsi_compose_firmware_stamp arm-sha secure-sha patina-sha 2>/dev/null || true)"
expect_eq "firmware stamp includes every firmware repository SHA" \
    "armvirt=arm-sha secure-services=secure-sha patina-qemu=patina-sha" "$STAMP"

assert_have_fn ucsi_can_reuse_firmware
expect_pass "clean matching firmware can be reused" ucsi_can_reuse_firmware 0 0 1 1
expect_fail "forced firmware cannot be reused" ucsi_can_reuse_firmware 1 0 1 1
expect_fail "dirty firmware cannot be reused" ucsi_can_reuse_firmware 0 1 1 1
expect_fail "missing artifacts cannot be reused" ucsi_can_reuse_firmware 0 0 0 1
expect_fail "mismatched stamp cannot be reused" ucsi_can_reuse_firmware 0 0 1 0

# =====================================================================
# (l) cache containment
# =====================================================================
echo "== cache-containment =="
assert_have_fn ucsi_path_within_repo
PATH_TMP="$SCRIPT_DIR/.tmp-paths-$$"
ROOT="$PATH_TMP/repo"
mkdir -p "$ROOT/cache" "$PATH_TMP/repo-sibling" "$PATH_TMP/outside"
expect_pass "cache inside repository accepted" ucsi_path_within_repo "$ROOT/cache" "$ROOT"
expect_pass "repository root accepted" ucsi_path_within_repo "$ROOT" "$ROOT"
expect_fail "sibling cache rejected" ucsi_path_within_repo "$PATH_TMP/repo-sibling" "$ROOT"
expect_fail "prefix-trick cache rejected" ucsi_path_within_repo "$ROOT-not-really/cache" "$ROOT"
expect_fail "outside cache rejected" ucsi_path_within_repo "$PATH_TMP/outside" "$ROOT"
rm -rf "$PATH_TMP"

# =====================================================================
# (m) overlay cleanup and guestfish command selection
# =====================================================================
echo "== failure-preservation =="
assert_have_fn ucsi_should_delete_overlay
expect_fail "failed run preserves overlay" ucsi_should_delete_overlay 0 0
expect_pass "verified success deletes overlay" ucsi_should_delete_overlay 1 0
expect_fail "explicit keep preserves successful overlay" ucsi_should_delete_overlay 1 1

echo "== guestfish-selection =="
assert_have_fn ucsi_guestfish_command_for_euid
expect_eq "root uses guestfish directly" "guestfish" \
    "$(ucsi_guestfish_command_for_euid 0 2>/dev/null || true)"
expect_eq "non-root uses passwordless sudo" "sudo -n guestfish" \
    "$(ucsi_guestfish_command_for_euid 1000 2>/dev/null || true)"

# =====================================================================
# (n) workflow, smoke crate, and devcontainer contracts
# =====================================================================
echo "== static-contracts =="
expect_contains "workflow declares dispatch nonce" "$WORKFLOW" '^[[:space:]]+dispatch_nonce:'
expect_contains "workflow run-name incorporates nonce" "$WORKFLOW" '^run-name:.*dispatch_nonce'
expect_contains "workflow passes ValidationOS URL through env" "$WORKFLOW" 'VALIDATION_OS_URL:.*inputs\.validation_os_url'
expect_contains "PowerShell reads ValidationOS URL from env" "$WORKFLOW" '\$env:VALIDATION_OS_URL'
expect_not_contains "workflow does not log the ValidationOS URL" "$WORKFLOW" \
    'Write-Host.*\$isoUrl'
expect_contains "workflow passes drivers repo through env" "$WORKFLOW" 'DRIVERS_REPO:.*inputs\.drivers_repo'
expect_contains "PowerShell reads drivers repo from env" "$WORKFLOW" '\$env:DRIVERS_REPO'
expect_contains "workflow declares drivers release" "$WORKFLOW" '^[[:space:]]+drivers_release:'
expect_contains "workflow passes drivers release through env" "$WORKFLOW" 'DRIVERS_RELEASE:.*inputs\.drivers_release'
expect_contains "PowerShell reads drivers release from env" "$WORKFLOW" '\$env:DRIVERS_RELEASE'
expect_contains "workflow resolves latest as the exact rolling tag" "$WORKFLOW" \
    'releases/tags/\$\(\$env:DRIVERS_RELEASE\)'
expect_contains "workflow accepts immutable driver manifest" "$WORKFLOW" '^[[:space:]]+driver_asset_manifest:'
expect_contains "workflow parses driver manifest as JSON data" "$WORKFLOW" \
    '\$env:DRIVER_ASSET_MANIFEST.*ConvertFrom-Json|ConvertFrom-Json.*\$env:DRIVER_ASSET_MANIFEST'
expect_contains "workflow downloads exact driver asset IDs" "$WORKFLOW" \
    'releases/assets/\$\(\$asset\.id\)'
expect_contains "workflow verifies driver SHA-256" "$WORKFLOW" 'Get-FileHash.*SHA256'
expect_not_contains "workflow has no smoke repo input" "$WORKFLOW" '^[[:space:]]+smoke_repo:'
expect_not_contains "workflow has no smoke release input" "$WORKFLOW" '^[[:space:]]+smoke_release:'
expect_not_contains "workflow does not download ec-test-tui release" "$WORKFLOW" \
    'ec-test-apps-ARM64|ec-test-tui\.exe|gh release download.*SMOKE'
expect_contains "workflow installs pinned Rust 1.88" "$WORKFLOW" \
    'rustup toolchain install 1\.88\.0'
expect_contains "workflow builds dedicated smoke crate locked" "$WORKFLOW" \
    'cargo \+1\.88\.0 build --locked --release --target aarch64-pc-windows-msvc'
expect_contains "workflow copies dedicated smoke binary" "$WORKFLOW" \
    "ucsi-smoke[/\\\\]target[/\\\\]aarch64-pc-windows-msvc[/\\\\]release[/\\\\]ucsi-smoke\\.exe"
expect_not_contains "PowerShell does not quote expressions into source" "$WORKFLOW" \
    "= '[^']*\\$\\{\\{[[:space:]]*inputs\\.(validation_os_url|drivers_repo|drivers_release|driver_asset_manifest|dispatch_nonce)"

expect_contains "smoke crate is isolated from parent workspaces" "$SMOKE_MANIFEST" '^\[workspace\]'
expect_contains "smoke crate pins exact platform-common revision" "$SMOKE_MANIFEST" \
    'git = "https://github\.com/dymk/odp-platform-common\.git".*rev = "53c3b6bce6d8f8c359ff0ded9884232d481ee7b1"'
expect_contains "smoke crate pins Rust 1.88" "$SMOKE_DIR/rust-toolchain.toml" 'channel = "1\.88\.0"'
expect_pass "smoke crate commits a lockfile" test -f "$SMOKE_LOCK"
expect_contains "Windows smoke uses ACPI transport" "$SMOKE_SOURCE" 'ec_test_lib::acpi::Acpi'
expect_contains "Windows smoke validates UCSI VERSION 0x0120" "$SMOKE_SOURCE" \
    'UcsiVersion\(0x0120\)'
expect_contains "Windows smoke checks connector capability 1" "$SMOKE_SOURCE" \
    'get_connector_capability\(1\)'
expect_contains "Windows smoke checks connector status 1" "$SMOKE_SOURCE" \
    'get_connector_status\(1\)'
expect_contains "Windows smoke writes exact PASS result" "$SMOKE_SOURCE" \
    'PASS: UCSI ACPI/FF-A E2E\\n'
expect_contains "Windows smoke writes exact result path" "$SMOKE_SOURCE" \
    'C:\\ucsi-e2e-result\.txt'
expect_contains "Windows smoke shuts down after five seconds" "$SMOKE_SOURCE" \
    '\["/s", "/f", "/t", "5"\]'

expect_contains "devcontainer pins vncdotool" "$DOCKERFILE" 'vncdotool==1\.3\.0'
expect_contains "devcontainer pins Pillow" "$DOCKERFILE" 'Pillow==12\.3\.0'
assert_have_fn ucsi_require_devcontainer_tools
expect_contains "runner starts or refreshes devcontainer" "$PROD" \
    'make -C "\$UCSI_REPO_ROOT" builder-image'
expect_order "devcontainer lifecycle precedes in-container dependency checks" "$PROD" \
    'ucsi_ensure_devcontainer' 'ucsi_require_devcontainer_tools'
expect_contains "port probe executes inside devcontainer" "$PROD" \
    'ucsi_dc .*dev/tcp/127\.0\.0\.1'
expect_not_contains "port probe does not inspect host namespace" "$PROD" \
    '^[[:space:]]*! timeout 1 bash -c ": > /dev/tcp/127\.0\.0\.1/\$port"'
expect_not_contains "dispatch polling does not sleep" "$PROD" '^[[:space:]]*sleep[[:space:]]'
expect_not_contains "dispatch fallback does not select latest branch run" "$PROD" \
    'gh run list.*--branch.*--limit 1'
expect_contains "smoke typing failure is guarded" "$PROD" \
    'if ! ucsi_type_smoke_command'
expect_not_contains "runner help has no smoke repo option" "$PROD" 'smoke-repo'
expect_not_contains "runner help has no smoke release option" "$PROD" 'smoke-release'
expect_contains "runner exposes drivers release option" "$PROD" 'drivers-release'

# =====================================================================
echo
echo "ran $TESTS_RUN checks, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ]
