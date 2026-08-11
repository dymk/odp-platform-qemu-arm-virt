#!/usr/bin/env bash
# Local contracts for the generic Windows/ACPI E2E framework.
#
# SPDX-License-Identifier: MIT

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD="$(cd "$SCRIPT_DIR/.." && pwd)/run-windows-acpi-e2e.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/qemu-ec-wrapper.sh"
UEFI_MAKEFILE="$REPO_ROOT/mod/uefi/Makefile"
BUILDER_BATCH="$REPO_ROOT/postbuild/os/windows-acpi-e2e/build-validationos.cmd"
FIXTURE="$REPO_ROOT/postbuild/os/windows-acpi-e2e/test-adapter"
GUEST_SUPPORT="$REPO_ROOT/postbuild/os/windows-acpi-e2e/guest-support"
WORKFLOW="$REPO_ROOT/.github/workflows/build-os.yml"
DOCKERFILE="$REPO_ROOT/.devcontainer/Dockerfile"
GENERIC_DRIVER_LIST="$REPO_ROOT/postbuild/os/prebuilt/driverlist.txt"
README="$REPO_ROOT/postbuild/os/README.md"
SCRATCH="$REPO_ROOT/postbuild/os/build/windows-acpi-e2e-tests-$$"

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

expect_fail() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi
}

expect_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        ok "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

expect_ne() {
    local desc="$1" left="$2" right="$3"
    if [ "$left" != "$right" ]; then ok "$desc"; else fail "$desc"; fi
}

expect_contains() {
    local desc="$1" file="$2" pattern="$3"
    if grep -Eq -- "$pattern" "$file"; then ok "$desc"; else fail "$desc"; fi
}

expect_not_contains() {
    local desc="$1" file="$2" pattern="$3"
    if grep -Eiq -- "$pattern" "$file"; then fail "$desc"; else ok "$desc"; fi
}

assert_have_fn() {
    if declare -F "$1" >/dev/null 2>&1; then
        ok "function defined: $1"
    else
        fail "function defined: $1"
    fi
}

make_adapter() {
    local root="$1" uuid="${2:-12345678-1234-4abc-8def-1234567890ab}"
    mkdir -p "$root/smoke/src"
    printf '[[bin]]\nname = "smoke"\npath = "src/main.rs"\n\n[workspace]\n\n[package]\nname = "fixture-smoke"\nversion = "0.1.0"\nedition = "2021"\n' \
        > "$root/smoke/Cargo.toml"
    : > "$root/smoke/Cargo.lock"
    printf '[toolchain]\nchannel = "1.90.0"\n' > "$root/smoke/rust-toolchain.toml"
    printf 'fn main() {}\n' > "$root/smoke/src/main.rs"
    printf 'driver-one\n' > "$root/drivers.txt"
    printf '%s\n' "$uuid" > "$root/secure-uuid.txt"
}

if [ -f "$PROD" ]; then
    # shellcheck source=/dev/null
    ODP_WINDOWS_ACPI_E2E_SOURCE_ONLY=1 source "$PROD"
fi

echo "== adapter and CLI schema =="
assert_have_fn odp_e2e_validate_adapter
VALID_ADAPTER="$SCRATCH/valid-adapter"
make_adapter "$VALID_ADAPTER"
expect_pass "required adapter layout accepted" odp_e2e_validate_adapter "$VALID_ADAPTER"
cp -a "$VALID_ADAPTER" "$SCRATCH/missing-smoke-bin"
python3 -c '
from pathlib import Path
path = Path(__import__("sys").argv[1])
text = path.read_text()
start = text.index("[[bin]]")
end = text.index("[workspace]")
path.write_text(text[:start] + text[end:])
' "$SCRATCH/missing-smoke-bin/smoke/Cargo.toml"
expect_fail "adapter without explicit smoke bin rejected" \
    odp_e2e_validate_adapter "$SCRATCH/missing-smoke-bin"
for required in smoke/Cargo.toml smoke/Cargo.lock smoke/rust-toolchain.toml \
    smoke/src/main.rs drivers.txt secure-uuid.txt; do
    BROKEN="$SCRATCH/broken-${required//\//-}"
    cp -a "$VALID_ADAPTER" "$BROKEN"
    rm -f "$BROKEN/$required"
    expect_fail "missing $required rejected" odp_e2e_validate_adapter "$BROKEN"
done
cp -a "$VALID_ADAPTER" "$SCRATCH/bad-uuid"
printf 'not-a-uuid\n' > "$SCRATCH/bad-uuid/secure-uuid.txt"
expect_fail "noncanonical secure UUID rejected" odp_e2e_validate_adapter "$SCRATCH/bad-uuid"
cp -a "$VALID_ADAPTER" "$SCRATCH/two-uuids"
printf '12345678-1234-4abc-8def-1234567890ab\nabcdefab-cdef-4abc-8def-abcdefabcdef\n' \
    > "$SCRATCH/two-uuids/secure-uuid.txt"
expect_fail "multiple secure UUIDs rejected" odp_e2e_validate_adapter "$SCRATCH/two-uuids"
touch "$VALID_ADAPTER/needs-ec-sidecar"
expect_pass "empty sidecar marker accepted" odp_e2e_validate_adapter "$VALID_ADAPTER"
printf x > "$VALID_ADAPTER/needs-ec-sidecar"
expect_fail "nonempty sidecar marker rejected" odp_e2e_validate_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/needs-ec-sidecar"
printf '/absolute/table.asl\n' > "$VALID_ADAPTER/acpi-entry.txt"
expect_fail "absolute ACPI entry rejected" odp_e2e_validate_adapter "$VALID_ADAPTER"
printf '../outside/table.asl\n' > "$VALID_ADAPTER/acpi-entry.txt"
expect_fail "parent-traversing ACPI entry rejected" odp_e2e_validate_adapter "$VALID_ADAPTER"
printf 'missing/table.asl\n' > "$VALID_ADAPTER/acpi-entry.txt"
expect_fail "missing ACPI entry rejected" odp_e2e_validate_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/acpi-entry.txt"
printf '../outside\n' > "$VALID_ADAPTER/acpi-includes.txt"
expect_fail "parent-traversing ACPI include rejected" odp_e2e_validate_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/acpi-includes.txt"
mkdir -p "$SCRATCH/symlink-target"
printf 'DefinitionBlock() {}\n' > "$SCRATCH/symlink-target/table.asl"
ln -s "$SCRATCH/symlink-target/table.asl" "$REPO_ROOT/postbuild/os/build/symlink-entry-$$.asl"
printf 'postbuild/os/build/symlink-entry-%s.asl\n' "$$" > "$VALID_ADAPTER/acpi-entry.txt"
expect_fail "symlinked ACPI entry rejected" odp_e2e_validate_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/acpi-entry.txt" "$REPO_ROOT/postbuild/os/build/symlink-entry-$$.asl"
ln -s "$SCRATCH/symlink-target" "$REPO_ROOT/postbuild/os/build/symlink-include-$$"
printf 'postbuild/os/build/symlink-include-%s\n' "$$" > "$VALID_ADAPTER/acpi-includes.txt"
expect_fail "symlinked ACPI include rejected" odp_e2e_validate_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/acpi-includes.txt" "$REPO_ROOT/postbuild/os/build/symlink-include-$$"
printf 'mod/uefi/platform/QemuArmVirtPkg/AcpiTables/ec.asl\n' \
    > "$SCRATCH/symlink-entry-list"
ln -s "$SCRATCH/symlink-entry-list" "$VALID_ADAPTER/acpi-entry.txt"
expect_fail "symlinked ACPI entry list rejected" odp_e2e_validate_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/acpi-entry.txt"
printf 'mod/uefi/platform/QemuArmVirtPkg/AcpiTables\n' \
    > "$SCRATCH/symlink-include-list"
ln -s "$SCRATCH/symlink-include-list" "$VALID_ADAPTER/acpi-includes.txt"
expect_fail "symlinked ACPI include list rejected" odp_e2e_validate_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/acpi-includes.txt"

assert_have_fn odp_e2e_validate_sources
expect_pass "URL source accepted" odp_e2e_validate_sources "https://example.invalid/ValidationOS.iso" "" ""
expect_pass "local ISO source accepted" odp_e2e_validate_sources "" "$SCRATCH/ValidationOS.iso" ""
expect_pass "prepared image source accepted" odp_e2e_validate_sources "" "" "$SCRATCH/os.qcow2"
expect_fail "no source rejected" odp_e2e_validate_sources "" "" ""
expect_fail "URL plus ISO rejected" odp_e2e_validate_sources "https://example.invalid/vos.iso" "$SCRATCH/vos.iso" ""
expect_fail "URL plus image rejected" odp_e2e_validate_sources "https://example.invalid/vos.iso" "" "$SCRATCH/os.qcow2"
expect_fail "ISO plus image rejected" odp_e2e_validate_sources "" "$SCRATCH/vos.iso" "$SCRATCH/os.qcow2"

assert_have_fn odp_e2e_validate_os_build
expect_fail "build 26100 rejected for final E2E" odp_e2e_validate_os_build 26100
expect_fail "build 27999 rejected" odp_e2e_validate_os_build 27999
expect_pass "build 28000 accepted" odp_e2e_validate_os_build 28000
expect_fail "non-integer build rejected" odp_e2e_validate_os_build 28000.1
expect_fail "CLI refuses public build 26100 before construction" \
    bash "$PROD" --adapter "$FIXTURE" --image "$SCRATCH/os.qcow2" \
    --validation-os-build 26100

HELP="$SCRATCH/help.txt"
bash "$PROD" --help > "$HELP" 2>&1 || true
expect_contains "help requires adapter" "$HELP" '--adapter DIR'
expect_contains "help exposes URL input" "$HELP" '--validation-os-url URL'
expect_contains "help exposes local ISO input" "$HELP" '--validation-os-iso PATH'
expect_contains "help exposes prepared image input" "$HELP" '--image PATH'
expect_contains "help exposes build floor" "$HELP" '28000'
expect_contains "help exposes cache option" "$HELP" '--cache-dir DIR'
expect_contains "help exposes driver release option" "$HELP" '--drivers-release TAG'
expect_contains "help exposes force option" "$HELP" '--force'
expect_contains "help exposes timeout options" "$HELP" '--builder-timeout'
expect_contains "help exposes keep option" "$HELP" '--keep'
expect_not_contains "help has no service-specific knobs" "$HELP" 'ucsi|thermal|service'
expect_not_contains "help has no workflow dispatch language" "$HELP" 'dispatch|workflow-repo|workflow-ref'

echo "== cache and local acquisition =="
assert_have_fn odp_e2e_file_identity
printf iso-a > "$SCRATCH/a.iso"
printf iso-b > "$SCRATCH/b.iso"
expect_eq "ISO identity is content SHA-256" \
    "sha256:$(sha256sum "$SCRATCH/a.iso" | awk '{print $1}')" \
    "$(odp_e2e_file_identity "$SCRATCH/a.iso" 2>/dev/null || true)"
expect_ne "different ISO content changes identity" \
    "$(odp_e2e_file_identity "$SCRATCH/a.iso" 2>/dev/null || true)" \
    "$(odp_e2e_file_identity "$SCRATCH/b.iso" 2>/dev/null || true)"

assert_have_fn odp_e2e_compute_image_cache_key
base_key="$(odp_e2e_compute_image_cache_key iso:aaa 28000 drivers:bbb inputs:ccc firmware:ddd 2>/dev/null || true)"
expect_ne "cache key is nonempty" "" "$base_key"
for changed in iso:xxx 28001 drivers:xxx inputs:xxx firmware:xxx; do
    args=(iso:aaa 28000 drivers:bbb inputs:ccc firmware:ddd)
    case "$changed" in
        iso:*) args[0]="$changed" ;;
        28001) args[1]="$changed" ;;
        drivers:*) args[2]="$changed" ;;
        inputs:*) args[3]="$changed" ;;
        firmware:*) args[4]="$changed" ;;
    esac
    expect_ne "cache key changes for $changed" "$base_key" \
        "$(odp_e2e_compute_image_cache_key "${args[@]}" 2>/dev/null || true)"
done

assert_have_fn odp_e2e_hash_inputs
printf one > "$SCRATCH/input-a"
printf two > "$SCRATCH/input-b"
input_hash="$(odp_e2e_hash_inputs "$SCRATCH/input-a" "$SCRATCH/input-b" 2>/dev/null || true)"
printf changed > "$SCRATCH/input-b"
expect_ne "local source change invalidates input hash" "$input_hash" \
    "$(odp_e2e_hash_inputs "$SCRATCH/input-a" "$SCRATCH/input-b" 2>/dev/null || true)"
expect_fail "missing local cache input rejected" odp_e2e_hash_inputs "$SCRATCH/missing"
ODP_E2E_REPO_ROOT="$REPO_ROOT"
COLLECTED_INPUTS="$SCRATCH/collected-inputs.txt"
CACHE_ADAPTER="$SCRATCH/cache-adapter"
cp -a "$FIXTURE" "$CACHE_ADAPTER"
printf 'pub const VALUE: u32 = 1;\n' > "$CACHE_ADAPTER/smoke/src/cache-fixture.rs"
odp_e2e_collect_input_files "$CACHE_ADAPTER" > "$COLLECTED_INPUTS"
expect_contains "cache inputs include guest support implementation" "$COLLECTED_INPUTS" \
    'windows-acpi-e2e/guest-support/src/lib\.rs'
expect_contains "cache inputs include guest support lockfile" "$COLLECTED_INPUTS" \
    'windows-acpi-e2e/guest-support/Cargo\.lock'
expect_contains "cache inputs include all adapter smoke sources" "$COLLECTED_INPUTS" \
    'cache-adapter/smoke/src/cache-fixture\.rs'

CUSTOM_ACPI="$SCRATCH/custom-acpi"
CUSTOM_INCLUDE="$SCRATCH/custom-include"
mkdir -p "$CUSTOM_ACPI" "$CUSTOM_INCLUDE/nested"
printf 'DefinitionBlock() {}\n' > "$CUSTOM_ACPI/custom.asl"
printf '#define CUSTOM_VALUE 1\n' > "$CUSTOM_INCLUDE/custom.inc"
printf '#define NESTED_VALUE 1\n' > "$CUSTOM_INCLUDE/nested/nested.asi"
printf '%s\n' "${CUSTOM_ACPI#"$REPO_ROOT/"}"'/custom.asl' \
    > "$CACHE_ADAPTER/acpi-entry.txt"
printf '%s\n' "${CUSTOM_INCLUDE#"$REPO_ROOT/"}" \
    > "$CACHE_ADAPTER/acpi-includes.txt"
odp_e2e_collect_input_files "$CACHE_ADAPTER" > "$COLLECTED_INPUTS"
expect_contains "cache inputs include resolved custom ACPI entry" "$COLLECTED_INPUTS" \
    'custom-acpi/custom\.asl'
expect_contains "cache inputs include listed ACPI include sources recursively" \
    "$COLLECTED_INPUTS" 'custom-include/nested/nested\.asi'
custom_hash="$(odp_e2e_hash_inputs $(cat "$COLLECTED_INPUTS") 2>/dev/null || true)"
printf 'DefinitionBlock() { Name (CHANGED, One) }\n' > "$CUSTOM_ACPI/custom.asl"
odp_e2e_collect_input_files "$CACHE_ADAPTER" > "$COLLECTED_INPUTS"
changed_entry_hash="$(odp_e2e_hash_inputs $(cat "$COLLECTED_INPUTS") 2>/dev/null || true)"
expect_ne "custom ACPI entry change invalidates input identity" \
    "$custom_hash" "$changed_entry_hash"
printf 'DefinitionBlock() {}\n' > "$CUSTOM_ACPI/custom.asl"
printf '#define CUSTOM_VALUE 2\n' > "$CUSTOM_INCLUDE/custom.inc"
odp_e2e_collect_input_files "$CACHE_ADAPTER" > "$COLLECTED_INPUTS"
changed_include_hash="$(odp_e2e_hash_inputs $(cat "$COLLECTED_INPUTS") 2>/dev/null || true)"
expect_ne "custom ACPI include change invalidates input identity" \
    "$custom_hash" "$changed_include_hash"

ACPI_CACHE="$SCRATCH/acpi-cache"
ACPI_BUILD_COUNT="$SCRATCH/acpi-build-count"
printf 0 > "$ACPI_BUILD_COUNT"
original_odp_e2e_dc="$(declare -f odp_e2e_dc)"
odp_e2e_dc() {
    local output="${6}" host_output count
    host_output="$REPO_ROOT${output#"/workspaces/$(basename "$REPO_ROOT")"}"
    count="$(cat "$ACPI_BUILD_COUNT")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$ACPI_BUILD_COUNT"
    mkdir -p "$host_output"
    printf 'ACPI build %s\n' "$count" > "$host_output/ACPITABL.dat"
}
printf '#define CUSTOM_VALUE 1\n' > "$CUSTOM_INCLUDE/custom.inc"
odp_e2e_collect_input_files "$CACHE_ADAPTER" > "$COLLECTED_INPUTS"
custom_hash="$(odp_e2e_hash_inputs $(cat "$COLLECTED_INPUTS") 2>/dev/null || true)"
odp_e2e_build_acpi "$ACPI_CACHE" "$custom_hash" "$CACHE_ADAPTER" \
    > "$SCRATCH/acpi-first-path"
printf '#define CUSTOM_VALUE 3\n' > "$CUSTOM_INCLUDE/custom.inc"
odp_e2e_collect_input_files "$CACHE_ADAPTER" > "$COLLECTED_INPUTS"
changed_include_hash="$(odp_e2e_hash_inputs $(cat "$COLLECTED_INPUTS") 2>/dev/null || true)"
odp_e2e_build_acpi "$ACPI_CACHE" "$changed_include_hash" "$CACHE_ADAPTER" \
    > "$SCRATCH/acpi-second-path"
expect_ne "changed custom ACPI source does not reuse stale cache path" \
    "$(cat "$SCRATCH/acpi-first-path")" "$(cat "$SCRATCH/acpi-second-path")"
expect_eq "changed custom ACPI source triggers a fresh compile" 2 \
    "$(cat "$ACPI_BUILD_COUNT")"
eval "$original_odp_e2e_dc"

assert_have_fn odp_e2e_atomic_download
printf payload > "$SCRATCH/source.iso"
expect_pass "local curl download publishes atomically" \
    odp_e2e_atomic_download "file://$SCRATCH/source.iso" "$SCRATCH/downloaded.iso"
expect_eq "downloaded bytes match source" \
    "$(sha256sum "$SCRATCH/source.iso" | awk '{print $1}')" \
    "$(sha256sum "$SCRATCH/downloaded.iso" | awk '{print $1}')"
expect_fail "failed download returns nonzero" \
    odp_e2e_atomic_download "file://$SCRATCH/missing.iso" "$SCRATCH/failed.iso"
expect_pass "failed download publishes no final file" test ! -e "$SCRATCH/failed.iso"
expect_fail "failed download leaves no temporary sibling" compgen -G "$SCRATCH/failed.iso.tmp.*"

assert_have_fn odp_e2e_resolve_iso
URL_CACHE="$SCRATCH/url-cache"
printf rolling-v1 > "$SCRATCH/rolling.iso"
url_build_28000="$(odp_e2e_resolve_iso "$URL_CACHE" \
    "file://$SCRATCH/rolling.iso" "" 28000 0 2>/dev/null || true)"
url_build_28001="$(odp_e2e_resolve_iso "$URL_CACHE" \
    "file://$SCRATCH/rolling.iso" "" 28001 0 2>/dev/null || true)"
expect_ne "rolling URL cache is build-scoped" "$url_build_28000" "$url_build_28001"
printf rolling-v2 > "$SCRATCH/rolling.iso"
url_cached="$(odp_e2e_resolve_iso "$URL_CACHE" \
    "file://$SCRATCH/rolling.iso" "" 28000 0 2>/dev/null || true)"
expect_eq "rolling URL cache remains stable without force" rolling-v1 \
    "$(cat "$url_cached" 2>/dev/null || true)"
url_forced="$(odp_e2e_resolve_iso "$URL_CACHE" \
    "file://$SCRATCH/rolling.iso" "" 28000 1 2>/dev/null || true)"
expect_eq "force refreshes build-scoped ISO cache" rolling-v2 \
    "$(cat "$url_forced" 2>/dev/null || true)"

assert_have_fn odp_e2e_atomic_publish_directory
mkdir -p "$SCRATCH/extracted-stage"
printf wim > "$SCRATCH/extracted-stage/ValidationOS.wim"
expect_pass "directory publication is atomic" \
    odp_e2e_atomic_publish_directory "$SCRATCH/extracted-stage" "$SCRATCH/extracted"
expect_pass "published directory contains staged file" \
    test -f "$SCRATCH/extracted/ValidationOS.wim"
expect_fail "directory publication refuses incomplete replacement" \
    odp_e2e_atomic_publish_directory "$SCRATCH/missing-stage" "$SCRATCH/extracted"
expect_pass "failed replacement preserves prior publication" \
    test -f "$SCRATCH/extracted/ValidationOS.wim"

assert_have_fn odp_e2e_remove_owned_tree
mkdir -p "$SCRATCH/read-only/tree"
printf data > "$SCRATCH/read-only/tree/file"
chmod -R a-w "$SCRATCH/read-only"
expect_pass "owned read-only extraction trees can be cleaned" \
    odp_e2e_remove_owned_tree "$SCRATCH/read-only"
expect_pass "read-only extraction cleanup removes the tree" test ! -e "$SCRATCH/read-only"

assert_have_fn odp_e2e_atomic_convert
printf 'not a qcow2 image' > "$SCRATCH/bad.qcow2"
expect_fail "failed image conversion returns nonzero" \
    odp_e2e_atomic_convert qcow2 "$SCRATCH/bad.qcow2" "$SCRATCH/converted.qcow2"
expect_pass "failed image conversion publishes no final image" \
    test ! -e "$SCRATCH/converted.qcow2"

echo "== immutable driver and cargo-xwin contracts =="
assert_have_fn odp_e2e_driver_release_url
expect_eq "latest selects the rolling latest tag" \
    "https://api.github.com/repos/org/drivers/releases/tags/latest" \
    "$(odp_e2e_driver_release_url org/drivers latest 2>/dev/null || true)"
expect_eq "explicit release selects its tag" \
    "https://api.github.com/repos/org/drivers/releases/tags/v1.2.3" \
    "$(odp_e2e_driver_release_url org/drivers v1.2.3 2>/dev/null || true)"
assert_have_fn odp_e2e_resolve_driver_asset_manifest
DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
RELEASE_JSON="$(printf \
    '{"assets":[{"name":"driver-one.zip","id":2,"digest":"%s"},{"name":"driver-two.zip","id":1,"digest":"%s"}]}' \
    "$DIGEST_B" "$DIGEST_A")"
manifest="$(odp_e2e_resolve_driver_asset_manifest "$RELEASE_JSON" \
    driver-one driver-two 2>/dev/null || true)"
expect_contains "manifest records immutable asset IDs" <(printf '%s\n' "$manifest") '"id":1'
expect_contains "manifest records immutable SHA-256 digests" <(printf '%s\n' "$manifest") '"digest":"sha256:[a-f0-9]{64}"'
expect_fail "digestless driver asset rejected" odp_e2e_resolve_driver_asset_manifest \
    '{"assets":[{"name":"driver-one.zip","id":1,"digest":null}]}' driver-one
expect_contains "driver ZIP extraction is noninteractive" "$PROD" 'unzip -oq .*< */dev/null'
expect_contains "driver cache records immutable manifest" "$PROD" 'manifest\.json'
expect_not_contains "authenticated driver requests are not replaced by redaction text" \
    "$PROD" 'Authorization: \*+'
expect_contains "authenticated driver requests use the configured token" "$PROD" \
    'Authorization: Bearer \$\{(GH_TOKEN|GITHUB_TOKEN)\}'

assert_have_fn odp_e2e_ensure_rust_190
expect_pass "Rust 1.90 toolchain is ensured" odp_e2e_ensure_rust_190
assert_have_fn odp_e2e_cargo_xwin_version_matches
expect_pass "exact cargo-xwin 0.23.0 accepted" \
    odp_e2e_cargo_xwin_version_matches "cargo-xwin 0.23.0"
expect_fail "other cargo-xwin version rejected" \
    odp_e2e_cargo_xwin_version_matches "cargo-xwin 0.22.1"
expect_contains "cargo-xwin install is pinned and locked" "$PROD" \
    'cargo \+1\.90\.0 install cargo-xwin --version 0\.23\.0 --locked --root'
expect_contains "adapter smoke release build uses cargo-xwin" "$PROD" \
    'cargo \+1\.90\.0 xwin build --locked --release --target aarch64-pc-windows-msvc'
expect_not_contains "runner never invokes plain Windows cargo build" "$PROD" \
    'cargo \+1\.90\.0 build .*aarch64-pc-windows-msvc'
expect_contains "fixture declares the smoke executable contract" \
    "$FIXTURE/smoke/Cargo.toml" '^\[\[bin\]\]$'
expect_contains "fixture executable is named smoke" \
    "$FIXTURE/smoke/Cargo.toml" '^name = "smoke"$'

echo "== target disk and builder contracts =="
assert_have_fn odp_e2e_create_target_image
if command -v guestfish >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
    TARGET="$SCRATCH/target.qcow2"
    export SUPERMIN_KERNEL="${SUPERMIN_KERNEL:-$REPO_ROOT/postbuild/os/build/windows-acpi-e2e-cache/libguestfs/kernels/$(uname -r)/vmlinuz-$(uname -r)}"
    export SUPERMIN_MODULES="${SUPERMIN_MODULES:-/lib/modules/$(uname -r)}"
    expect_pass "target GPT image creation succeeds rootlessly" \
        odp_e2e_create_target_image "$TARGET" 512M
    PARTS="$SCRATCH/parts.txt"
    guestfish --ro -a "$TARGET" run : part-list /dev/sda > "$PARTS" 2>/dev/null || true
    expect_contains "target has EFI partition" "$PARTS" 'part_num: 1'
    expect_contains "target has MSR partition" "$PARTS" 'part_num: 2'
    expect_contains "target has OS partition" "$PARTS" 'part_num: 3'
    expect_pass "EFI marker exists" \
        guestfish --ro -a "$TARGET" run : mount /dev/sda1 / : exists /ODP_ESP.TAG
    expect_pass "OS marker exists" \
        guestfish --ro -a "$TARGET" run : mount /dev/sda3 / : exists /ODP_OS.TAG

    assert_have_fn odp_e2e_remove_e2e_result
    IMPORTED_BASE="$SCRATCH/imported-base.qcow2"
    IMPORTED_OVERLAY="$SCRATCH/imported-overlay.qcow2"
    guestfish -a "$TARGET" run : mount /dev/sda3 / \
        : mkdir-p /odp-e2e \
        : write /odp-e2e/result.txt "$ODP_E2E_PASS_LINE"
    expect_pass "prepared image imports into a pristine cached base" \
        odp_e2e_atomic_convert qcow2 "$TARGET" "$IMPORTED_BASE"
    expect_pass "imported image gets a disposable overlay" \
        odp_e2e_make_overlay "$IMPORTED_OVERLAY" "$IMPORTED_BASE" qcow2
    expect_pass "final preparation removes stale PASS" \
        odp_e2e_remove_e2e_result "$IMPORTED_OVERLAY"
    expect_eq "stale PASS is absent from disposable overlay" false \
        "$(guestfish --ro -a "$IMPORTED_OVERLAY" run : mount-ro /dev/sda3 / \
            : is-file /odp-e2e/result.txt 2>/dev/null || true)"
    expect_eq "stale PASS remains in cached base" true \
        "$(guestfish --ro -a "$IMPORTED_BASE" run : mount-ro /dev/sda3 / \
            : is-file /odp-e2e/result.txt 2>/dev/null || true)"
fi

assert_have_fn odp_e2e_check_builder_result
printf 'PASS: local image build\r\n' > "$SCRATCH/builder-pass.txt"
printf 'FAIL: errorlevel=1\r\n' > "$SCRATCH/builder-fail.txt"
expect_pass "exact builder PASS accepted" odp_e2e_check_builder_result "$SCRATCH/builder-pass.txt"
expect_fail "builder FAIL rejected" odp_e2e_check_builder_result "$SCRATCH/builder-fail.txt"
expect_pass "generic builder batch exists" test -f "$BUILDER_BATCH"
expect_contains "builder uses generic root" "$BUILDER_BATCH" 'C:\\odp-e2e-builder'
expect_contains "batch applies ValidationOS WIM" "$BUILDER_BATCH" \
    'ValidationOS\.wim.*Apply-Image|Apply-Image.*ValidationOS\.wim'
expect_contains "batch injects unsigned drivers" "$BUILDER_BATCH" '/Add-Driver.*/ForceUnsigned'
expect_contains "batch locates target by marker" "$BUILDER_BATCH" 'ODP_OS\.TAG'
expect_contains "batch locates ESP by marker" "$BUILDER_BATCH" 'ODP_ESP\.TAG'
expect_contains "batch manually copies EFI boot files" "$BUILDER_BATCH" 'Windows\\Boot\\EFI'
expect_contains "batch uses fixed osloader GUID" "$BUILDER_BATCH" \
    '\{01234567-89ab-cdef-0123-456789abcdef\}'
expect_contains "batch creates BCD with builder bcdedit" "$BUILDER_BATCH" \
    'C:\\Windows\\System32\\bcdedit\.exe'
expect_contains "batch writes exact PASS marker" "$BUILDER_BATCH" \
    '> *"%ROOT%\\build-result\.txt" +echo PASS: local image build'

echo "== generic wrapper seam =="
CAPTURE="$SCRATCH/qemu-args.txt"
FAKE_QEMU="$SCRATCH/fake-qemu"
cat > "$FAKE_QEMU" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$QEMU_CAPTURE"
[ -z "${QEMU_CHILD_PID:-}" ] || printf '%s\n' "$$" > "$QEMU_CHILD_PID"
EOF
chmod +x "$FAKE_QEMU"
expect_pass "normal wrapper invocation remains unchanged" \
    env -u ODP_E2E_BUILDER_TARGET REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" \
    EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_not_contains "normal invocation has no target NVMe" "$CAPTURE" 'ODPTARGET|odp-e2e-builder-target'
expect_pass "explicit builder target appends second NVMe" \
    env ODP_E2E_BUILDER_TARGET="/workspaces/repo/target.qcow2" \
    REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" EC_I2C_SOCK= EC_GPIO_SOCK= \
    QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_contains "target drive uses explicit qcow2 path" "$CAPTURE" \
    'file=/workspaces/repo/target\.qcow2,format=qcow2'
expect_contains "target is attached as NVMe" "$CAPTURE" \
    'nvme,drive=odp-e2e-builder-target,serial=ODPTARGET001'
expect_fail "explicit empty builder target is rejected" \
    env ODP_E2E_BUILDER_TARGET= REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" \
    EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_contains "UEFI forwards optional builder target" "$UEFI_MAKEFILE" \
    'ODP_E2E_BUILDER_TARGET=\$\(ODP_E2E_BUILDER_TARGET\)'
PID_FILE="$SCRATCH/qemu.pid"
CHILD_PID="$SCRATCH/qemu-child.pid"
expect_pass "wrapper records exact QEMU PID" \
    env ODP_E2E_QEMU_PID_FILE="$PID_FILE" REAL_QEMU="$FAKE_QEMU" \
    QEMU_CAPTURE="$CAPTURE" QEMU_CHILD_PID="$CHILD_PID" \
    EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_eq "recorded PID belongs to exec'd QEMU process" \
    "$(cat "$CHILD_PID" 2>/dev/null || true)" "$(cat "$PID_FILE" 2>/dev/null || true)"
expect_contains "UEFI forwards optional owned PID file" "$UEFI_MAKEFILE" \
    'ODP_E2E_QEMU_PID_FILE=\$\(ODP_E2E_QEMU_PID_FILE\)'
expect_pass "explicit EC PTY appends the serial bridge" \
    env ODP_E2E_EC_PTY=/dev/pts/42 REAL_QEMU="$FAKE_QEMU" \
    QEMU_CAPTURE="$CAPTURE" EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none \
    "$WRAPPER" -machine virt
expect_contains "EC PTY is attached as a serial chardev" "$CAPTURE" \
    'serial,id=odp-e2e-ec-link,path=/dev/pts/42'
expect_fail "explicit empty EC PTY is rejected" \
    env ODP_E2E_EC_PTY= REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" \
    EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_contains "UEFI forwards optional EC PTY" "$UEFI_MAKEFILE" \
    'ODP_E2E_EC_PTY=\$\(ODP_E2E_EC_PTY\)'

expect_pass "wrapper forwards explicit run-local EC sockets" \
    env REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" \
    EC_I2C_SOCK=/workspaces/repo/run/ec-i2c.sock \
    EC_GPIO_SOCK=/workspaces/repo/run/ec-gpio.sock QEMU_DISPLAY=none \
    "$WRAPPER" -machine virt
expect_contains "wrapper receives run-local I2C socket" "$CAPTURE" \
    'path=/workspaces/repo/run/ec-i2c\.sock'
expect_contains "wrapper receives run-local GPIO socket" "$CAPTURE" \
    'path=/workspaces/repo/run/ec-gpio\.sock'

echo "== optional EC sidecar =="
assert_have_fn odp_e2e_adapter_needs_ec_sidecar
assert_have_fn odp_e2e_ec_socket_paths
rm -f "$VALID_ADAPTER/needs-ec-sidecar"
expect_fail "adapter without marker skips sidecar" odp_e2e_adapter_needs_ec_sidecar "$VALID_ADAPTER"
: > "$VALID_ADAPTER/needs-ec-sidecar"
expect_pass "adapter marker selects sidecar" odp_e2e_adapter_needs_ec_sidecar "$VALID_ADAPTER"
EXPECTED_EC_I2C="/workspaces/$(basename "$REPO_ROOT")${SCRATCH#"$REPO_ROOT"}/sidecar-run/ec-i2c.sock"
EXPECTED_EC_GPIO="/workspaces/$(basename "$REPO_ROOT")${SCRATCH#"$REPO_ROOT"}/sidecar-run/ec-gpio.sock"
mapfile -t EC_SOCKET_PATHS < <(odp_e2e_ec_socket_paths "$SCRATCH/sidecar-run" 2>/dev/null || true)
expect_eq "sidecar I2C socket is run-local" \
    "$EXPECTED_EC_I2C" "${EC_SOCKET_PATHS[0]-}"
expect_eq "sidecar GPIO socket is run-local" \
    "$EXPECTED_EC_GPIO" "${EC_SOCKET_PATHS[1]-}"
mkdir -p "$SCRATCH/fake-bin" "$SCRATCH/sidecar-run"
cat > "$SCRATCH/fake-bin/make" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MAKE_CAPTURE"
EOF
chmod +x "$SCRATCH/fake-bin/make"
PATH="$SCRATCH/fake-bin:$PATH" MAKE_CAPTURE="$SCRATCH/sidecar-make-args" \
    odp_e2e_boot_qemu "$SCRATCH/image.qcow2" "" "$SCRATCH/sidecar-boot.log" 5 \
    "$SCRATCH/sidecar-run" "" "$EXPECTED_EC_I2C" "$EXPECTED_EC_GPIO"
expect_contains "host QEMU receives sidecar I2C socket" "$SCRATCH/sidecar-make-args" \
    "^EC_I2C_SOCK=${EXPECTED_EC_I2C}$"
expect_contains "host QEMU receives sidecar GPIO socket" "$SCRATCH/sidecar-make-args" \
    "^EC_GPIO_SOCK=${EXPECTED_EC_GPIO}$"
PATH="$SCRATCH/fake-bin:$PATH" MAKE_CAPTURE="$SCRATCH/plain-make-args" \
    odp_e2e_boot_qemu "$SCRATCH/image.qcow2" "" "$SCRATCH/plain-boot.log" 5 \
    "$SCRATCH/sidecar-run" "" "" ""
expect_contains "host QEMU disables I2C socket without sidecar" "$SCRATCH/plain-make-args" \
    '^EC_I2C_SOCK=$'
expect_contains "host QEMU disables GPIO socket without sidecar" "$SCRATCH/plain-make-args" \
    '^EC_GPIO_SOCK=$'
expect_contains "runner gives sidecar and host the same socket pair" "$PROD" \
    'odp_e2e_start_ec_sidecar "\$run_dir" "\$ec_i2c_sock" "\$ec_gpio_sock"'
expect_contains "sidecar build uses existing dev-qemu platform" "$PROD" \
    'mod/ec/platform/dev-qemu'
expect_contains "sidecar build bypasses the broken submodule HEAD dependency" "$PROD" \
    'odp_e2e_dc -w mod/ec/platform/dev-qemu -- cargo build --release --locked'
expect_contains "sidecar exposes the established PTY transport" "$PROD" \
    '-serial pty'
expect_contains "host attaches the sidecar as its additional serial link" "$WRAPPER" \
    '-serial "chardev:odp-e2e-ec-link"'
expect_contains "sidecar preserves its log" "$PROD" 'ec-sidecar\.log'
expect_not_contains "runner never kills by process name" "$PROD" \
    '(^|[^A-Za-z])(pkill|killall)([^A-Za-z]|$)'

echo "== result, security, and repository separation =="
assert_have_fn odp_e2e_verify_e2e_result
printf 'PASS: Windows ACPI E2E\r\n' > "$SCRATCH/result.txt"
printf 'boot 12345678-1234-4abc-8def-1234567890ab secure world\n' > "$SCRATCH/boot.log"
expect_pass "exact PASS plus adapter UUID accepted" \
    odp_e2e_verify_e2e_result "$SCRATCH/result.txt" "$SCRATCH/boot.log" \
    12345678-1234-4abc-8def-1234567890ab
printf 'FAIL: smoke\r\n' > "$SCRATCH/result.txt"
expect_fail "FAIL plus UUID rejected" \
    odp_e2e_verify_e2e_result "$SCRATCH/result.txt" "$SCRATCH/boot.log" \
    12345678-1234-4abc-8def-1234567890ab
printf 'PASS: Windows ACPI E2E\r\n' > "$SCRATCH/result.txt"
: > "$SCRATCH/boot.log"
expect_fail "PASS without adapter UUID rejected" \
    odp_e2e_verify_e2e_result "$SCRATCH/result.txt" "$SCRATCH/boot.log" \
    12345678-1234-4abc-8def-1234567890ab
expect_contains "runner uses standardized guest binary path" "$PROD" \
    'odp-e2e[/\\]+smoke\.exe'
expect_contains "runner uses standardized result path" "$PROD" \
    'odp-e2e[/\\]+result\.txt'
expect_contains "runner edits Winlogon offline" "$PROD" 'virt-win-reg'
expect_contains "runner prepares rootless guestfish" "$PROD" 'odp_e2e_prepare_guestfish'
expect_contains "runner boots headless" "$PROD" 'QEMU_DISPLAY=none'
expect_not_contains "runner never uses sudo" "$PROD" '(^|[^A-Za-z])sudo([^A-Za-z]|$)'
expect_not_contains "runner has no workflow CLI" "$PROD" \
    'gh workflow|gh run (watch|download|list|view)|workflow_dispatch'
assert_have_fn odp_e2e_cache_tree_safe
mkdir -p "$SCRATCH/cache-root/cache/libguestfs" "$SCRATCH/cache-root/outside"
expect_pass "ordinary cache tree is accepted" \
    odp_e2e_cache_tree_safe "$SCRATCH/cache-root/cache" "$SCRATCH/cache-root"
ln -s "$SCRATCH/cache-root/outside" "$SCRATCH/cache-root/cache/libguestfs/escaped"
expect_fail "symlink inside cache tree is rejected" \
    odp_e2e_cache_tree_safe "$SCRATCH/cache-root/cache" "$SCRATCH/cache-root"
rm "$SCRATCH/cache-root/cache/libguestfs/escaped"
ln -s "$SCRATCH/cache-root/outside" "$SCRATCH/cache-root/symlink-cache"
expect_fail "symlinked cache root is rejected" \
    odp_e2e_cache_tree_safe "$SCRATCH/cache-root/symlink-cache" "$SCRATCH/cache-root"
assert_have_fn odp_e2e_should_delete_run_dir
expect_fail "failed run directory is preserved" odp_e2e_should_delete_run_dir 0 0
expect_pass "successful run directory is deleted by default" odp_e2e_should_delete_run_dir 1 0
expect_fail "keep flag preserves successful run directory" odp_e2e_should_delete_run_dir 1 1
expect_not_contains "generic production files contain no service strings" \
    <(cat "$PROD" "$BUILDER_BATCH" "$GUEST_SUPPORT/src/lib.rs" "$FIXTURE/smoke/src/main.rs" 2>/dev/null) \
    'ucsi|thermal'
expect_not_contains "generic workflow remains unchanged" "$WORKFLOW" \
    'windows-acpi-e2e|validation_os_url|drivers_release|driver_asset_manifest'
expect_not_contains "devcontainer generic driver list remains unchanged" "$DOCKERFILE" \
    'windows-acpi-e2e|cargo-xwin'
expect_not_contains "generic driver list remains service-neutral" "$GENERIC_DRIVER_LIST" \
    'ectest'

echo "== committed generic fixture and documentation =="
expect_pass "fixture Cargo manifest exists" test -f "$FIXTURE/smoke/Cargo.toml"
expect_pass "fixture lockfile exists" test -f "$FIXTURE/smoke/Cargo.lock"
expect_contains "fixture crate remains isolated" "$FIXTURE/smoke/Cargo.toml" '^\[workspace\]'
expect_contains "fixture remains Rust 1.90" "$FIXTURE/smoke/rust-toolchain.toml" \
    'channel = "1\.90\.0"'
expect_contains "fixture uses guest support" "$FIXTURE/smoke/Cargo.toml" \
    'windows-acpi-e2e-guest-support'
expect_contains "README documents adapter directory" "$README" 'adapter'
expect_contains "README documents standard success line" "$README" 'PASS: Windows ACPI E2E'
expect_contains "README documents sidecar marker" "$README" 'needs-ec-sidecar'

echo
printf 'ran %d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
