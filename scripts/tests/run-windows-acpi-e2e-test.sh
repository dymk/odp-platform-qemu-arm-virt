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

expect_contracts() {
    local file="$1" mode desc pattern
    while IFS=$'\t' read -r mode desc pattern; do
        [ -n "$mode" ] || continue
        case "$mode" in
            has) expect_contains "$desc" "$file" "$pattern" ;;
            lacks) expect_not_contains "$desc" "$file" "$pattern" ;;
        esac
    done
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
VALID_ADAPTER="$SCRATCH/valid-adapter"
make_adapter "$VALID_ADAPTER"
expect_pass "required adapter layout accepted" odp_e2e_load_adapter "$VALID_ADAPTER"
cp -a "$VALID_ADAPTER" "$SCRATCH/missing-smoke-bin"
python3 -c 'from pathlib import Path; import sys; p=Path(sys.argv[1]); s=p.read_text(); p.write_text(s[:s.index("[[bin]]")] + s[s.index("[workspace]"):])' "$SCRATCH/missing-smoke-bin/smoke/Cargo.toml"
expect_fail "adapter without explicit smoke bin rejected" odp_e2e_load_adapter "$SCRATCH/missing-smoke-bin"
for required in smoke/Cargo.toml smoke/Cargo.lock smoke/rust-toolchain.toml \
    smoke/src/main.rs drivers.txt secure-uuid.txt; do
    BROKEN="$SCRATCH/broken-${required//\//-}"
    cp -a "$VALID_ADAPTER" "$BROKEN"
    rm -f "$BROKEN/$required"
    expect_fail "missing $required rejected" odp_e2e_load_adapter "$BROKEN"
done
for uuid_case in \
    'noncanonical secure UUID|not-a-uuid' \
    'multiple secure UUIDs|12345678-1234-4abc-8def-1234567890ab\nabcdefab-cdef-4abc-8def-abcdefabcdef'; do
    desc="${uuid_case%%|*}"; BROKEN="$SCRATCH/uuid-${desc// /-}"
    cp -a "$VALID_ADAPTER" "$BROKEN"
    printf '%b\n' "${uuid_case#*|}" > "$BROKEN/secure-uuid.txt"
    expect_fail "$desc rejected" odp_e2e_load_adapter "$BROKEN"
done
touch "$VALID_ADAPTER/needs-ec-sidecar"
expect_pass "empty sidecar marker accepted" odp_e2e_load_adapter "$VALID_ADAPTER"
printf x > "$VALID_ADAPTER/needs-ec-sidecar"
expect_fail "nonempty sidecar marker rejected" odp_e2e_load_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/needs-ec-sidecar"
for path_case in \
    'absolute ACPI entry|acpi-entry.txt|/absolute/table.asl' \
    'parent-traversing ACPI entry|acpi-entry.txt|../outside/table.asl' \
    'missing ACPI entry|acpi-entry.txt|missing/table.asl' \
    'parent-traversing ACPI include|acpi-includes.txt|../outside'; do
    IFS='|' read -r desc control value <<< "$path_case"
    printf '%s\n' "$value" > "$VALID_ADAPTER/$control"
    expect_fail "$desc rejected" odp_e2e_load_adapter "$VALID_ADAPTER"
    rm -f "$VALID_ADAPTER/$control"
done
mkdir -p "$SCRATCH/symlink-target"
printf 'DefinitionBlock() {}\n' > "$SCRATCH/symlink-target/table.asl"
ln -s "$SCRATCH/symlink-target/table.asl" "$REPO_ROOT/postbuild/os/build/symlink-entry-$$.asl"
printf 'postbuild/os/build/symlink-entry-%s.asl\n' "$$" > "$VALID_ADAPTER/acpi-entry.txt"
expect_fail "symlinked ACPI entry rejected" odp_e2e_load_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/acpi-entry.txt" "$REPO_ROOT/postbuild/os/build/symlink-entry-$$.asl"
ln -s "$SCRATCH/symlink-target" "$REPO_ROOT/postbuild/os/build/symlink-include-$$"
printf 'postbuild/os/build/symlink-include-%s\n' "$$" > "$VALID_ADAPTER/acpi-includes.txt"
expect_fail "symlinked ACPI include rejected" odp_e2e_load_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/acpi-includes.txt" "$REPO_ROOT/postbuild/os/build/symlink-include-$$"
printf 'mod/uefi/platform/QemuArmVirtPkg/AcpiTables/ec.asl\n' > "$SCRATCH/symlink-entry-list"
ln -s "$SCRATCH/symlink-entry-list" "$VALID_ADAPTER/acpi-entry.txt"
expect_fail "symlinked ACPI entry list rejected" odp_e2e_load_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/acpi-entry.txt"
printf 'mod/uefi/platform/QemuArmVirtPkg/AcpiTables\n' > "$SCRATCH/symlink-include-list"
ln -s "$SCRATCH/symlink-include-list" "$VALID_ADAPTER/acpi-includes.txt"
expect_fail "symlinked ACPI include list rejected" odp_e2e_load_adapter "$VALID_ADAPTER"
rm -f "$VALID_ADAPTER/acpi-includes.txt"

for source_case in \
    "no source| " \
    "URL plus ISO|--validation-os-url https://example.invalid/vos.iso --validation-os-iso $SCRATCH/vos.iso" \
    "URL plus image|--validation-os-url https://example.invalid/vos.iso --image $SCRATCH/os.qcow2" \
    "ISO plus image|--validation-os-iso $SCRATCH/vos.iso --image $SCRATCH/os.qcow2"; do
    desc="${source_case%%|*}"
    read -r -a source_args <<< "${source_case#*|}"
    SOURCE_ERROR="$SCRATCH/source-${desc// /-}.txt"
    bash "$PROD" --adapter "$VALID_ADAPTER" --validation-os-build 28000 \
        "${source_args[@]}" > "$SOURCE_ERROR" 2>&1 || true
    expect_contains "$desc rejected by the CLI" "$SOURCE_ERROR" \
        'specify exactly one of --validation-os-url, --validation-os-iso, or --image'
done

expect_fail "build 26100 rejected for final E2E" odp_e2e_validate_os_build 26100
expect_fail "build 27999 rejected" odp_e2e_validate_os_build 27999
expect_pass "build 28000 accepted" odp_e2e_validate_os_build 28000
expect_fail "non-integer build rejected" odp_e2e_validate_os_build 28000.1
expect_fail "CLI refuses public build 26100 before construction" bash "$PROD" --adapter "$FIXTURE" --image "$SCRATCH/os.qcow2" --validation-os-build 26100

HELP="$SCRATCH/help.txt"
bash "$PROD" --help > "$HELP" 2>&1 || true
expect_contracts "$HELP" <<'EOF'
has	help requires adapter	--adapter DIR
has	help exposes URL input	--validation-os-url URL
has	help exposes local ISO input	--validation-os-iso PATH
has	help exposes prepared image input	--image PATH
has	help exposes build floor	28000
has	help exposes cache option	--cache-dir DIR
has	help exposes driver release option	--drivers-release TAG
has	help exposes force option	--force
has	help exposes timeout options	--builder-timeout
has	help exposes keep option	--keep
lacks	help has no service-specific knobs	ucsi|thermal|service
lacks	help has no workflow dispatch language	dispatch|workflow-repo|workflow-ref
EOF

echo "== cache and local acquisition =="
printf iso-a > "$SCRATCH/a.iso"
printf iso-b > "$SCRATCH/b.iso"
expect_eq "ISO identity is content SHA-256" \
    "sha256:$(sha256sum "$SCRATCH/a.iso" | awk '{print $1}')" \
    "$(odp_e2e_file_identity "$SCRATCH/a.iso" 2>/dev/null || true)"
expect_ne "different ISO content changes identity" \
    "$(odp_e2e_file_identity "$SCRATCH/a.iso" 2>/dev/null || true)" \
    "$(odp_e2e_file_identity "$SCRATCH/b.iso" 2>/dev/null || true)"

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
    expect_ne "cache key changes for $changed" "$base_key" "$(odp_e2e_compute_image_cache_key "${args[@]}" 2>/dev/null || true)"
done

printf one > "$SCRATCH/input-a"
printf two > "$SCRATCH/input-b"
input_hash="$(odp_e2e_hash_inputs "$SCRATCH/input-a" "$SCRATCH/input-b" 2>/dev/null || true)"
printf changed > "$SCRATCH/input-b"
expect_ne "local source change invalidates input hash" "$input_hash" "$(odp_e2e_hash_inputs "$SCRATCH/input-a" "$SCRATCH/input-b" 2>/dev/null || true)"
expect_fail "missing local cache input rejected" odp_e2e_hash_inputs "$SCRATCH/missing"
ODP_E2E_REPO_ROOT="$REPO_ROOT"
COLLECTED_INPUTS="$SCRATCH/collected-inputs.txt"
CACHE_ADAPTER="$SCRATCH/cache-adapter"
cp -a "$FIXTURE" "$CACHE_ADAPTER"
printf 'pub const VALUE: u32 = 1;\n' > "$CACHE_ADAPTER/smoke/src/cache-fixture.rs"
odp_e2e_load_adapter "$CACHE_ADAPTER"
odp_e2e_collect_input_files > "$COLLECTED_INPUTS"
expect_contracts "$COLLECTED_INPUTS" <<'EOF'
has	cache inputs include guest support implementation	windows-acpi-e2e/guest-support/src/lib\.rs
has	cache inputs include guest support lockfile	windows-acpi-e2e/guest-support/Cargo\.lock
has	cache inputs include all adapter smoke sources	cache-adapter/smoke/src/cache-fixture\.rs
EOF

CUSTOM_ACPI="$SCRATCH/custom-acpi"
CUSTOM_INCLUDE="$SCRATCH/custom-include"
mkdir -p "$CUSTOM_ACPI" "$CUSTOM_INCLUDE/nested"
printf 'DefinitionBlock() {}\n' > "$CUSTOM_ACPI/custom.asl"
printf '#define CUSTOM_VALUE 1\n' > "$CUSTOM_INCLUDE/custom.inc"
printf '#define NESTED_VALUE 1\n' > "$CUSTOM_INCLUDE/nested/nested.asi"
printf '%s\n' "${CUSTOM_ACPI#"$REPO_ROOT/"}"'/custom.asl' > "$CACHE_ADAPTER/acpi-entry.txt"
printf '%s\n' "${CUSTOM_INCLUDE#"$REPO_ROOT/"}" > "$CACHE_ADAPTER/acpi-includes.txt"
odp_e2e_load_adapter "$CACHE_ADAPTER"
odp_e2e_collect_input_files > "$COLLECTED_INPUTS"
expect_eq "canonical adapter records UUID" 12345678-1234-4abc-8def-1234567890ab "$ODP_E2E_ADAPTER_UUID"
expect_eq "canonical adapter resolves ACPI entry once" "$(realpath -e "$CUSTOM_ACPI/custom.asl")" "$ODP_E2E_ADAPTER_ACPI_ENTRY"
expect_eq "canonical adapter resolves include directories once" "$(realpath -e "$CUSTOM_INCLUDE")" "${ODP_E2E_ADAPTER_ACPI_INCLUDES[0]}"
expect_contracts "$COLLECTED_INPUTS" <<'EOF'
has	cache inputs retain adapter ACPI control files	acpi-entry\.txt$
has	cache inputs include resolved custom ACPI entry	custom-acpi/custom\.asl
has	cache inputs include listed ACPI include sources recursively	custom-include/nested/nested\.asi
EOF
custom_hash="$(odp_e2e_hash_inputs $(cat "$COLLECTED_INPUTS") 2>/dev/null || true)"
printf 'DefinitionBlock() { Name (CHANGED, One) }\n' > "$CUSTOM_ACPI/custom.asl"
odp_e2e_load_adapter "$CACHE_ADAPTER"
odp_e2e_collect_input_files > "$COLLECTED_INPUTS"
changed_entry_hash="$(odp_e2e_hash_inputs $(cat "$COLLECTED_INPUTS") 2>/dev/null || true)"
expect_ne "custom ACPI entry change invalidates input identity" "$custom_hash" "$changed_entry_hash"
printf 'DefinitionBlock() {}\n' > "$CUSTOM_ACPI/custom.asl"
printf '#define CUSTOM_VALUE 2\n' > "$CUSTOM_INCLUDE/custom.inc"
odp_e2e_load_adapter "$CACHE_ADAPTER"
odp_e2e_collect_input_files > "$COLLECTED_INPUTS"
changed_include_hash="$(odp_e2e_hash_inputs $(cat "$COLLECTED_INPUTS") 2>/dev/null || true)"
expect_ne "custom ACPI include change invalidates input identity" "$custom_hash" "$changed_include_hash"

ACPI_CACHE="$SCRATCH/acpi-cache"
ACPI_BUILD_COUNT="$SCRATCH/acpi-build-count"
printf 0 > "$ACPI_BUILD_COUNT"
original_odp_e2e_dc="$(declare -f odp_e2e_dc)"
odp_e2e_dc() {
    local output="${6}" host_output count
    printf '%s\n' "$@" > "$SCRATCH/acpi-build-args"
    host_output="$REPO_ROOT${output#"/workspaces/$(basename "$REPO_ROOT")"}"
    count="$(cat "$ACPI_BUILD_COUNT")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$ACPI_BUILD_COUNT"
    mkdir -p "$host_output"
    printf 'ACPI build %s\n' "$count" > "$host_output/ACPITABL.dat"
}
printf '#define CUSTOM_VALUE 1\n' > "$CUSTOM_INCLUDE/custom.inc"
odp_e2e_load_adapter "$CACHE_ADAPTER"
odp_e2e_collect_input_files > "$COLLECTED_INPUTS"
custom_hash="$(odp_e2e_hash_inputs $(cat "$COLLECTED_INPUTS") 2>/dev/null || true)"
odp_e2e_build_acpi "$ACPI_CACHE" "$custom_hash" "$ODP_E2E_ADAPTER_ACPI_ENTRY" "${ODP_E2E_ADAPTER_ACPI_INCLUDES[@]}" > "$SCRATCH/acpi-first-path"
printf '#define CUSTOM_VALUE 3\n' > "$CUSTOM_INCLUDE/custom.inc"
printf 'missing/table.asl\n' > "$CACHE_ADAPTER/acpi-entry.txt"
printf '../outside\n' > "$CACHE_ADAPTER/acpi-includes.txt"
odp_e2e_collect_input_files > "$COLLECTED_INPUTS"
changed_include_hash="$(odp_e2e_hash_inputs $(cat "$COLLECTED_INPUTS") 2>/dev/null || true)"
odp_e2e_build_acpi "$ACPI_CACHE" "$changed_include_hash" "$ODP_E2E_ADAPTER_ACPI_ENTRY" "${ODP_E2E_ADAPTER_ACPI_INCLUDES[@]}" > "$SCRATCH/acpi-second-path"
expect_ne "changed custom ACPI source does not reuse stale cache path" "$(cat "$SCRATCH/acpi-first-path")" "$(cat "$SCRATCH/acpi-second-path")"
expect_eq "changed custom ACPI source triggers a fresh compile" 2 "$(cat "$ACPI_BUILD_COUNT")"
expect_contains "ACPI build uses the canonical entry after control-file mutation" "$SCRATCH/acpi-build-args" '/custom-acpi/custom\.asl$'
expect_contains "ACPI build uses canonical includes after control-file mutation" "$SCRATCH/acpi-build-args" '/custom-include$'
eval "$original_odp_e2e_dc"

printf payload > "$SCRATCH/source.iso"
expect_pass "local curl download publishes atomically" odp_e2e_atomic_download "file://$SCRATCH/source.iso" "$SCRATCH/downloaded.iso"
expect_eq "downloaded bytes match source" "$(sha256sum "$SCRATCH/source.iso" | awk '{print $1}')" "$(sha256sum "$SCRATCH/downloaded.iso" | awk '{print $1}')"
expect_fail "failed download returns nonzero" odp_e2e_atomic_download "file://$SCRATCH/missing.iso" "$SCRATCH/failed.iso"
expect_pass "failed download publishes no final file" test ! -e "$SCRATCH/failed.iso"
expect_fail "failed download leaves no temporary sibling" compgen -G "$SCRATCH/failed.iso.tmp.*"

URL_CACHE="$SCRATCH/url-cache"
printf rolling-v1 > "$SCRATCH/rolling.iso"
url_build_28000="$(odp_e2e_resolve_iso "$URL_CACHE" "file://$SCRATCH/rolling.iso" "" 28000 0 2>/dev/null || true)"
url_build_28001="$(odp_e2e_resolve_iso "$URL_CACHE" "file://$SCRATCH/rolling.iso" "" 28001 0 2>/dev/null || true)"
expect_ne "rolling URL cache is build-scoped" "$url_build_28000" "$url_build_28001"
printf rolling-v2 > "$SCRATCH/rolling.iso"
url_cached="$(odp_e2e_resolve_iso "$URL_CACHE" "file://$SCRATCH/rolling.iso" "" 28000 0 2>/dev/null || true)"
expect_eq "rolling URL cache remains stable without force" rolling-v1 "$(cat "$url_cached" 2>/dev/null || true)"
url_forced="$(odp_e2e_resolve_iso "$URL_CACHE" "file://$SCRATCH/rolling.iso" "" 28000 1 2>/dev/null || true)"
expect_eq "force refreshes build-scoped ISO cache" rolling-v2 "$(cat "$url_forced" 2>/dev/null || true)"

mkdir -p "$SCRATCH/extracted-stage"
printf wim > "$SCRATCH/extracted-stage/ValidationOS.wim"
expect_pass "directory publication is atomic" odp_e2e_atomic_publish_directory "$SCRATCH/extracted-stage" "$SCRATCH/extracted"
expect_pass "published directory contains staged file" test -f "$SCRATCH/extracted/ValidationOS.wim"
expect_fail "directory publication refuses incomplete replacement" odp_e2e_atomic_publish_directory "$SCRATCH/missing-stage" "$SCRATCH/extracted"
expect_pass "failed replacement preserves prior publication" test -f "$SCRATCH/extracted/ValidationOS.wim"

mkdir -p "$SCRATCH/read-only/tree"
printf data > "$SCRATCH/read-only/tree/file"
chmod -R a-w "$SCRATCH/read-only"
expect_pass "owned read-only extraction trees can be cleaned" odp_e2e_remove_owned_tree "$SCRATCH/read-only"
expect_pass "read-only extraction cleanup removes the tree" test ! -e "$SCRATCH/read-only"

printf 'not a qcow2 image' > "$SCRATCH/bad.qcow2"
expect_fail "failed image conversion returns nonzero" odp_e2e_atomic_convert qcow2 "$SCRATCH/bad.qcow2" "$SCRATCH/converted.qcow2"
expect_pass "failed image conversion publishes no final image" test ! -e "$SCRATCH/converted.qcow2"

echo "== immutable driver and cargo-xwin contracts =="
DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
RELEASE_JSON="$(printf '{"assets":[{"name":"driver-one.zip","id":2,"digest":"%s"},{"name":"driver-two.zip","id":1,"digest":"%s"}]}' "$DIGEST_B" "$DIGEST_A")"
manifest="$(odp_e2e_resolve_driver_asset_manifest "$RELEASE_JSON" driver-one driver-two 2>/dev/null || true)"
expect_contains "manifest records immutable asset IDs" <(printf '%s\n' "$manifest") '"id":1'
expect_contains "manifest records immutable SHA-256 digests" <(printf '%s\n' "$manifest") '"digest":"sha256:[a-f0-9]{64}"'
expect_fail "digestless driver asset rejected" odp_e2e_resolve_driver_asset_manifest \
    '{"assets":[{"name":"driver-one.zip","id":1,"digest":null}]}' driver-one
expect_contracts "$PROD" <<'EOF'
has	driver ZIP extraction is noninteractive	unzip -oq .*< */dev/null
has	driver cache records immutable manifest	manifest\.json
EOF
expect_not_contains "authenticated driver requests are not replaced by redaction text" \
    "$PROD" 'Authorization: \*+'
expect_contains "authenticated driver requests use the configured token" "$PROD" \
    'Authorization: Bearer \$\{(GH_TOKEN|GITHUB_TOKEN)\}'

echo "== target disk and builder contracts =="
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

builder_result_contract() (
    local result="$1"
    odp_e2e_create_target_image() { :; }
    odp_e2e_make_overlay() { :; }
    odp_e2e_inject_builder_payload() { :; }
    odp_e2e_write_shell_registry() { :; }
    odp_e2e_set_winlogon_shell() { :; }
    odp_e2e_boot_qemu() { :; }
    odp_e2e_extract_builder_result() {
        printf '%b' "$result" > "$2/build-result.txt"
    }
    odp_e2e_validate_target_payload() { :; }
    odp_e2e_publish_built_base() { :; }
    odp_e2e_build_local_base "$SCRATCH/builder-cache" key extracted drivers acpi smoke final 1
)
expect_pass "exact CRLF builder PASS accepted" builder_result_contract 'PASS: local image build\r\n'
expect_fail "builder FAIL rejected" builder_result_contract 'FAIL: errorlevel=1\r\n'
expect_contracts "$BUILDER_BATCH" <<'EOF'
has	builder uses generic root	C:\\odp-e2e-builder
has	batch applies ValidationOS WIM	ValidationOS\.wim.*Apply-Image|Apply-Image.*ValidationOS\.wim
has	batch injects unsigned drivers	/Add-Driver.*/ForceUnsigned
has	batch locates target by marker	ODP_OS\.TAG
has	batch locates ESP by marker	ODP_ESP\.TAG
has	batch manually copies EFI boot files	Windows\\Boot\\EFI
has	batch uses fixed osloader GUID	\{01234567-89ab-cdef-0123-456789abcdef\}
has	batch creates BCD with builder bcdedit	C:\\Windows\\System32\\bcdedit\.exe
has	batch writes exact PASS marker	> *"%ROOT%\\build-result\.txt" +echo PASS: local image build
EOF

echo "== generic wrapper seam =="
CAPTURE="$SCRATCH/qemu-args.txt"
FAKE_QEMU="$SCRATCH/fake-qemu"
cat > "$FAKE_QEMU" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$QEMU_CAPTURE"
[ -z "${QEMU_CHILD_PID:-}" ] || printf '%s\n' "$$" > "$QEMU_CHILD_PID"
EOF
chmod +x "$FAKE_QEMU"
expect_pass "normal wrapper invocation remains unchanged" env -u ODP_E2E_BUILDER_TARGET REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_not_contains "normal invocation has no target NVMe" "$CAPTURE" 'ODPTARGET|odp-e2e-builder-target'
expect_pass "explicit builder target appends second NVMe" env ODP_E2E_BUILDER_TARGET="/workspaces/repo/target.qcow2" REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_contains "target drive uses explicit qcow2 path" "$CAPTURE" 'file=/workspaces/repo/target\.qcow2,format=qcow2'
expect_contains "target is attached as NVMe" "$CAPTURE" 'nvme,drive=odp-e2e-builder-target,serial=ODPTARGET001'
expect_fail "explicit empty builder target is rejected" env ODP_E2E_BUILDER_TARGET= REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
PID_FILE="$SCRATCH/qemu.pid"
CHILD_PID="$SCRATCH/qemu-child.pid"
expect_pass "wrapper records exact QEMU PID" env ODP_E2E_QEMU_PID_FILE="$PID_FILE" REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" QEMU_CHILD_PID="$CHILD_PID" EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_eq "recorded PID belongs to exec'd QEMU process" "$(cat "$CHILD_PID" 2>/dev/null || true)" "$(cat "$PID_FILE" 2>/dev/null || true)"
expect_pass "explicit EC PTY appends the serial bridge" env ODP_E2E_EC_PTY=/dev/pts/42 REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_contains "EC PTY is attached as a serial chardev" "$CAPTURE" 'serial,id=odp-e2e-ec-link,path=/dev/pts/42'
expect_fail "explicit empty EC PTY is rejected" env ODP_E2E_EC_PTY= REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_contracts "$UEFI_MAKEFILE" <<'EOF'
has	UEFI forwards optional builder target	ODP_E2E_BUILDER_TARGET=\$\(ODP_E2E_BUILDER_TARGET\)
has	UEFI forwards optional owned PID file	ODP_E2E_QEMU_PID_FILE=\$\(ODP_E2E_QEMU_PID_FILE\)
has	UEFI forwards optional EC PTY	ODP_E2E_EC_PTY=\$\(ODP_E2E_EC_PTY\)
EOF

expect_pass "wrapper forwards explicit run-local EC sockets" env REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" EC_I2C_SOCK=/workspaces/repo/run/ec-i2c.sock EC_GPIO_SOCK=/workspaces/repo/run/ec-gpio.sock QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_contains "wrapper receives run-local I2C socket" "$CAPTURE" 'path=/workspaces/repo/run/ec-i2c\.sock'
expect_contains "wrapper receives run-local GPIO socket" "$CAPTURE" 'path=/workspaces/repo/run/ec-gpio\.sock'

echo "== optional EC sidecar =="
rm -f "$VALID_ADAPTER/needs-ec-sidecar"
odp_e2e_load_adapter "$VALID_ADAPTER"
expect_eq "adapter without marker skips sidecar" 0 "$ODP_E2E_ADAPTER_NEEDS_EC_SIDECAR"
: > "$VALID_ADAPTER/needs-ec-sidecar"
odp_e2e_load_adapter "$VALID_ADAPTER"
expect_eq "adapter marker selects sidecar" 1 "$ODP_E2E_ADAPTER_NEEDS_EC_SIDECAR"
EXPECTED_EC_I2C="/workspaces/$(basename "$REPO_ROOT")${SCRATCH#"$REPO_ROOT"}/sidecar-run/ec-i2c.sock"
EXPECTED_EC_GPIO="/workspaces/$(basename "$REPO_ROOT")${SCRATCH#"$REPO_ROOT"}/sidecar-run/ec-gpio.sock"
mapfile -t EC_SOCKET_PATHS < <(odp_e2e_ec_socket_paths "$SCRATCH/sidecar-run" 2>/dev/null || true)
expect_eq "sidecar I2C socket is run-local" "$EXPECTED_EC_I2C" "${EC_SOCKET_PATHS[0]-}"
expect_eq "sidecar GPIO socket is run-local" "$EXPECTED_EC_GPIO" "${EC_SOCKET_PATHS[1]-}"
mkdir -p "$SCRATCH/fake-bin" "$SCRATCH/sidecar-run"
cat > "$SCRATCH/fake-bin/make" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MAKE_CAPTURE"
EOF
chmod +x "$SCRATCH/fake-bin/make"
PATH="$SCRATCH/fake-bin:$PATH" MAKE_CAPTURE="$SCRATCH/sidecar-make-args" odp_e2e_boot_qemu "$SCRATCH/image.qcow2" "" "$SCRATCH/sidecar-boot.log" 5 "$SCRATCH/sidecar-run" "" "$EXPECTED_EC_I2C" "$EXPECTED_EC_GPIO"
expect_contains "host QEMU receives sidecar I2C socket" "$SCRATCH/sidecar-make-args" "^EC_I2C_SOCK=${EXPECTED_EC_I2C}$"
expect_contains "host QEMU receives sidecar GPIO socket" "$SCRATCH/sidecar-make-args" "^EC_GPIO_SOCK=${EXPECTED_EC_GPIO}$"
PATH="$SCRATCH/fake-bin:$PATH" MAKE_CAPTURE="$SCRATCH/plain-make-args" odp_e2e_boot_qemu "$SCRATCH/image.qcow2" "" "$SCRATCH/plain-boot.log" 5 "$SCRATCH/sidecar-run" "" "" ""
expect_contains "host QEMU disables I2C socket without sidecar" "$SCRATCH/plain-make-args" '^EC_I2C_SOCK=$'
expect_contains "host QEMU disables GPIO socket without sidecar" "$SCRATCH/plain-make-args" '^EC_GPIO_SOCK=$'
expect_contracts "$PROD" <<'EOF'
has	runner gives sidecar and host the same socket pair	odp_e2e_start_ec_sidecar "\$run_dir" "\$ec_i2c_sock" "\$ec_gpio_sock"
lacks	runner never kills by process name	(^|[^A-Za-z])(pkill|killall)([^A-Za-z]|$)
EOF

echo "== result, security, and repository separation =="
printf 'PASS: Windows ACPI E2E\r\n' > "$SCRATCH/result.txt"
printf 'boot 12345678-1234-4abc-8def-1234567890ab secure world\n' > "$SCRATCH/boot.log"
expect_pass "exact PASS plus adapter UUID accepted" odp_e2e_verify_e2e_result "$SCRATCH/result.txt" "$SCRATCH/boot.log" 12345678-1234-4abc-8def-1234567890ab
printf 'FAIL: smoke\r\n' > "$SCRATCH/result.txt"
expect_fail "FAIL plus UUID rejected" odp_e2e_verify_e2e_result "$SCRATCH/result.txt" "$SCRATCH/boot.log" 12345678-1234-4abc-8def-1234567890ab
printf 'PASS: Windows ACPI E2E\r\n' > "$SCRATCH/result.txt"
: > "$SCRATCH/boot.log"
expect_fail "PASS without adapter UUID rejected" odp_e2e_verify_e2e_result "$SCRATCH/result.txt" "$SCRATCH/boot.log" 12345678-1234-4abc-8def-1234567890ab

e2e_lifecycle_contract() (
    local mode="$1" keep="$2" cache="$SCRATCH/lifecycle-$1-$2"
    local status=0 result_line='FAIL: smoke\r\n' run
    [ "$mode" != pass ] || result_line='PASS: Windows ACPI E2E\r\n'
    rm -rf "$cache"
    odp_e2e_prepare_run_overlay() { : > "$2"; }
    odp_e2e_boot_qemu() {
        printf 'boot 12345678-1234-4abc-8def-1234567890ab secure world\n' > "$3"
        printf '0\n' > "$5/qemu-status.txt"
    }
    odp_e2e_extract_e2e_result() { printf '%b' "$result_line" > "$2"; }
    odp_e2e_run_e2e "$cache" base 1 "$keep" 0 \
        12345678-1234-4abc-8def-1234567890ab >/dev/null 2>&1 || status=$?
    run="$(find "$cache/runs" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    case "$mode:$keep" in
        pass:0) [ "$status" -eq 0 ] && [ -z "$run" ] ;;
        pass:1) [ "$status" -eq 0 ] && [ -n "$run" ] ;;
        fail:0)
            [ "$status" -ne 0 ] \
                && [ -n "$run" ] \
                && [ -f "$(find "$cache/evidence" -name result.txt -print -quit)" ] \
                && [ -f "$(find "$cache/evidence" -name boot.log -print -quit)" ]
            ;;
    esac
)
expect_pass "successful run directory is deleted by default" e2e_lifecycle_contract pass 0
expect_pass "keep flag preserves successful run directory" e2e_lifecycle_contract pass 1
expect_pass "failed run preserves artifacts and copied evidence" e2e_lifecycle_contract fail 0

expect_contracts "$PROD" <<'EOF'
lacks	runner never uses sudo	(^|[^A-Za-z])sudo([^A-Za-z]|$)
lacks	runner has no workflow CLI	gh workflow|gh run (watch|download|list|view)|workflow_dispatch
EOF
mkdir -p "$SCRATCH/cache-root/cache/libguestfs" "$SCRATCH/cache-root/outside"
expect_pass "ordinary cache tree is accepted" odp_e2e_cache_tree_safe "$SCRATCH/cache-root/cache" "$SCRATCH/cache-root"
ln -s "$SCRATCH/cache-root/outside" "$SCRATCH/cache-root/cache/libguestfs/escaped"
expect_fail "symlink inside cache tree is rejected" odp_e2e_cache_tree_safe "$SCRATCH/cache-root/cache" "$SCRATCH/cache-root"
rm "$SCRATCH/cache-root/cache/libguestfs/escaped"
ln -s "$SCRATCH/cache-root/outside" "$SCRATCH/cache-root/symlink-cache"
expect_fail "symlinked cache root is rejected" odp_e2e_cache_tree_safe "$SCRATCH/cache-root/symlink-cache" "$SCRATCH/cache-root"
echo "== committed generic fixture and documentation =="
expect_pass "committed fixture satisfies adapter contract" odp_e2e_load_adapter "$FIXTURE"

echo
printf 'ran %d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
