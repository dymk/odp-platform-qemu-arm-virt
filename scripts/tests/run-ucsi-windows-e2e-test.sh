#!/usr/bin/env bash
# Local-only contracts for scripts/run-ucsi-windows-e2e.sh.
#
# SPDX-License-Identifier: MIT

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD="$(cd "$SCRIPT_DIR/.." && pwd)/run-ucsi-windows-e2e.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/qemu-ec-wrapper.sh"
UEFI_MAKEFILE="$REPO_ROOT/mod/uefi/Makefile"
BUILDER_BATCH="$REPO_ROOT/postbuild/os/build-ucsi-validationos.cmd"
DRIVER_LIST="$REPO_ROOT/postbuild/os/ucsi-driverlist.txt"
GENERIC_DRIVER_LIST="$REPO_ROOT/postbuild/os/prebuilt/driverlist.txt"
WORKFLOW="$REPO_ROOT/.github/workflows/build-os.yml"
DOCKERFILE="$REPO_ROOT/.devcontainer/Dockerfile"
README="$REPO_ROOT/postbuild/os/README.md"
SMOKE_DIR="$REPO_ROOT/postbuild/os/ucsi-smoke"

TESTS_RUN=0
TESTS_FAILED=0
SCRATCH="$REPO_ROOT/postbuild/os/build/ucsi-runner-tests-$$"
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
    if grep -Eq -- "$pattern" "$file"; then fail "$desc"; else ok "$desc"; fi
}

assert_have_fn() {
    if declare -F "$1" >/dev/null 2>&1; then
        ok "function defined: $1"
    else
        fail "function defined: $1"
    fi
}

if [ -f "$PROD" ]; then
    # shellcheck source=/dev/null
    UCSI_WINDOWS_E2E_SOURCE_ONLY=1 source "$PROD"
fi

echo "== local CLI =="
assert_have_fn ucsi_validate_sources
expect_pass "URL source accepted" ucsi_validate_sources "https://example.invalid/ValidationOS.iso" "" ""
expect_pass "local ISO source accepted" ucsi_validate_sources "" "$SCRATCH/ValidationOS.iso" ""
expect_pass "prepared image source accepted" ucsi_validate_sources "" "" "$SCRATCH/os.qcow2"
expect_fail "no source rejected" ucsi_validate_sources "" "" ""
expect_fail "URL plus ISO rejected" ucsi_validate_sources "https://example.invalid/vos.iso" "$SCRATCH/vos.iso" ""
expect_fail "URL plus image rejected" ucsi_validate_sources "https://example.invalid/vos.iso" "" "$SCRATCH/os.qcow2"
expect_fail "ISO plus image rejected" ucsi_validate_sources "" "$SCRATCH/vos.iso" "$SCRATCH/os.qcow2"

assert_have_fn ucsi_validate_os_build
expect_fail "build 26100 rejected for final E2E" ucsi_validate_os_build 26100
expect_fail "build 27999 rejected" ucsi_validate_os_build 27999
expect_pass "build 28000 accepted" ucsi_validate_os_build 28000
expect_fail "non-integer build rejected" ucsi_validate_os_build 28000.1

HELP="$SCRATCH/help.txt"
bash "$PROD" --help > "$HELP" 2>&1 || true
expect_contains "help exposes local ISO input" "$HELP" '--validation-os-iso PATH'
expect_contains "help documents prepared image contract" "$HELP" 'drivers.*ACPI.*smoke|ACPI.*drivers.*smoke'
expect_not_contains "help has no workflow repository option" "$HELP" 'workflow-repo|workflow-ref'
expect_not_contains "help has no workflow dispatch language" "$HELP" 'dispatch|artifact download'

echo "== local cache identity =="
assert_have_fn ucsi_file_identity
printf 'iso-a' > "$SCRATCH/a.iso"
printf 'iso-b' > "$SCRATCH/b.iso"
expect_eq "ISO identity is content SHA-256" \
    "sha256:$(sha256sum "$SCRATCH/a.iso" | awk '{print $1}')" \
    "$(ucsi_file_identity "$SCRATCH/a.iso" 2>/dev/null || true)"
expect_ne "different ISO content changes identity" \
    "$(ucsi_file_identity "$SCRATCH/a.iso" 2>/dev/null || true)" \
    "$(ucsi_file_identity "$SCRATCH/b.iso" 2>/dev/null || true)"

assert_have_fn ucsi_compute_image_cache_key
base_key="$(ucsi_compute_image_cache_key iso:aaa 28000 drivers:bbb inputs:ccc firmware:ddd 2>/dev/null || true)"
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
        "$(ucsi_compute_image_cache_key "${args[@]}" 2>/dev/null || true)"
done

assert_have_fn ucsi_hash_inputs
printf one > "$SCRATCH/input-a"
printf two > "$SCRATCH/input-b"
input_hash="$(ucsi_hash_inputs "$SCRATCH/input-a" "$SCRATCH/input-b" 2>/dev/null || true)"
printf changed > "$SCRATCH/input-b"
expect_ne "local source change invalidates input hash" "$input_hash" \
    "$(ucsi_hash_inputs "$SCRATCH/input-a" "$SCRATCH/input-b" 2>/dev/null || true)"
expect_fail "missing local cache input is rejected" ucsi_hash_inputs "$SCRATCH/missing"

echo "== atomic local acquisition =="
assert_have_fn ucsi_atomic_download
printf payload > "$SCRATCH/source.iso"
expect_pass "local curl download publishes atomically" \
    ucsi_atomic_download "file://$SCRATCH/source.iso" "$SCRATCH/downloaded.iso"
expect_eq "downloaded bytes match source" \
    "$(sha256sum "$SCRATCH/source.iso" | awk '{print $1}')" \
    "$(sha256sum "$SCRATCH/downloaded.iso" | awk '{print $1}')"
expect_fail "failed download returns nonzero" \
    ucsi_atomic_download "file://$SCRATCH/missing.iso" "$SCRATCH/failed.iso"
expect_pass "failed download publishes no final file" test ! -e "$SCRATCH/failed.iso"
expect_fail "atomic download leaves no temporary sibling" \
    compgen -G "$SCRATCH/failed.iso.tmp.*"

assert_have_fn ucsi_resolve_iso
URL_CACHE="$SCRATCH/url-cache"
printf 'rolling-v1' > "$SCRATCH/rolling.iso"
url_build_28000="$(ucsi_resolve_iso "$URL_CACHE" \
    "file://$SCRATCH/rolling.iso" "" 28000 0 2>/dev/null || true)"
url_build_28001="$(ucsi_resolve_iso "$URL_CACHE" \
    "file://$SCRATCH/rolling.iso" "" 28001 0 2>/dev/null || true)"
expect_ne "same rolling ISO URL uses a distinct cache path for each declared build" \
    "$url_build_28000" "$url_build_28001"
printf 'rolling-v2' > "$SCRATCH/rolling.iso"
url_cached="$(ucsi_resolve_iso "$URL_CACHE" \
    "file://$SCRATCH/rolling.iso" "" 28000 0 2>/dev/null || true)"
expect_eq "rolling ISO cache remains stable without force" \
    "rolling-v1" "$(cat "$url_cached" 2>/dev/null || true)"
url_forced="$(ucsi_resolve_iso "$URL_CACHE" \
    "file://$SCRATCH/rolling.iso" "" 28000 1 2>/dev/null || true)"
expect_eq "force-image refreshes the build-scoped rolling ISO cache" \
    "rolling-v2" "$(cat "$url_forced" 2>/dev/null || true)"

assert_have_fn ucsi_atomic_publish_directory
mkdir -p "$SCRATCH/extracted-stage"
printf wim > "$SCRATCH/extracted-stage/ValidationOS.wim"
expect_pass "directory publication is atomic" \
    ucsi_atomic_publish_directory "$SCRATCH/extracted-stage" "$SCRATCH/extracted"
expect_pass "published directory contains staged file" \
    test -f "$SCRATCH/extracted/ValidationOS.wim"
expect_fail "directory publication refuses incomplete replacement" \
    ucsi_atomic_publish_directory "$SCRATCH/missing-stage" "$SCRATCH/extracted"
expect_pass "failed replacement preserves prior publication" \
    test -f "$SCRATCH/extracted/ValidationOS.wim"
assert_have_fn ucsi_remove_owned_tree
mkdir -p "$SCRATCH/read-only/tree"
printf data > "$SCRATCH/read-only/tree/file"
chmod -R a-w "$SCRATCH/read-only"
expect_pass "owned read-only extraction trees can be cleaned" \
    ucsi_remove_owned_tree "$SCRATCH/read-only"
expect_pass "read-only extraction cleanup removes the tree" \
    test ! -e "$SCRATCH/read-only"

assert_have_fn ucsi_atomic_convert
printf 'not a qcow2 image' > "$SCRATCH/bad.qcow2"
expect_fail "failed image conversion returns nonzero" \
    ucsi_atomic_convert qcow2 "$SCRATCH/bad.qcow2" "$SCRATCH/converted.qcow2"
expect_pass "failed image conversion publishes no final image" \
    test ! -e "$SCRATCH/converted.qcow2"

echo "== immutable driver assets =="
assert_have_fn ucsi_driver_release_url
expect_eq "latest selects the rolling latest tag" \
    "https://api.github.com/repos/org/drivers/releases/tags/latest" \
    "$(ucsi_driver_release_url org/drivers latest 2>/dev/null || true)"
expect_eq "explicit release selects its tag" \
    "https://api.github.com/repos/org/drivers/releases/tags/v1.2.3" \
    "$(ucsi_driver_release_url org/drivers v1.2.3 2>/dev/null || true)"
assert_have_fn ucsi_resolve_driver_asset_manifest
DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
DIGEST_C="sha256:$(printf 'c%.0s' {1..64})"
RELEASE_JSON="$(printf \
    '{"assets":[{"name":"driver-qemui2c-ARM64-Release.zip","id":2,"digest":"%s"},{"name":"driver-ectest_kmdf-ARM64-Release.zip","id":3,"digest":"%s"},{"name":"driver-pl061gpio-ARM64-Release.zip","id":1,"digest":"%s"}]}' \
    "$DIGEST_B" "$DIGEST_C" "$DIGEST_A")"
manifest="$(ucsi_resolve_driver_asset_manifest "$RELEASE_JSON" \
    driver-pl061gpio-ARM64-Release driver-qemui2c-ARM64-Release \
    driver-ectest_kmdf-ARM64-Release 2>/dev/null || true)"
expect_contains "manifest records immutable asset IDs" <(printf '%s\n' "$manifest") '"id":1'
expect_contains "manifest records immutable SHA-256 digests" <(printf '%s\n' "$manifest") '"digest":"sha256:[a-f0-9]{64}"'
expect_fail "digestless driver asset rejected" ucsi_resolve_driver_asset_manifest \
    '{"assets":[{"name":"driver-pl061gpio-ARM64-Release.zip","id":1,"digest":null}]}' \
    driver-pl061gpio-ARM64-Release
expect_contains "driver ZIP extraction is noninteractive" "$PROD" \
    'unzip -oq .*< */dev/null'
expect_contains "driver cache records its immutable manifest" "$PROD" \
    'manifest\.json'

echo "== cargo-xwin contract =="
assert_have_fn ucsi_ensure_rust_190
expect_pass "Rust 1.90 toolchain is ensured before cargo-xwin" ucsi_ensure_rust_190
assert_have_fn ucsi_cargo_xwin_version_matches
expect_pass "exact cargo-xwin 0.23.0 accepted" \
    ucsi_cargo_xwin_version_matches "cargo-xwin 0.23.0"
expect_fail "other cargo-xwin version rejected" \
    ucsi_cargo_xwin_version_matches "cargo-xwin 0.22.1"
expect_contains "cargo-xwin install is pinned and locked" "$PROD" \
    'cargo \+1\.90\.0 install cargo-xwin --version 0\.23\.0 --locked --root'
expect_contains "Windows smoke release build uses cargo-xwin" "$PROD" \
    'cargo \+1\.90\.0 xwin build --locked --release --target aarch64-pc-windows-msvc'
expect_contains "failed cargo-xwin build cannot reuse a stale executable" "$PROD" \
    'cargo \+1\.90\.0 xwin build .*aarch64-pc-windows-msvc.*\|\|'
expect_not_contains "runner never invokes plain Windows cargo build" "$PROD" \
    'cargo \+1\.90\.0 build .*aarch64-pc-windows-msvc'

echo "== target disk helper =="
assert_have_fn ucsi_create_target_image
if command -v guestfish >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
    TARGET="$SCRATCH/target.qcow2"
    export SUPERMIN_KERNEL="${SUPERMIN_KERNEL:-$REPO_ROOT/postbuild/os/build/ucsi-windows-e2e-cache/libguestfs/kernels/$(uname -r)/vmlinuz-$(uname -r)}"
    export SUPERMIN_MODULES="${SUPERMIN_MODULES:-/lib/modules/$(uname -r)}"
    expect_pass "target GPT image creation succeeds rootlessly" \
        ucsi_create_target_image "$TARGET" 512M
    PARTS="$SCRATCH/parts.txt"
    guestfish --ro -a "$TARGET" run : part-list /dev/sda > "$PARTS" 2>/dev/null || true
    expect_contains "target has EFI partition" "$PARTS" 'part_num: 1'
    expect_contains "target has MSR partition" "$PARTS" 'part_num: 2'
    expect_contains "target has OS partition" "$PARTS" 'part_num: 3'
    expect_pass "EFI marker exists" \
        guestfish --ro -a "$TARGET" run : mount /dev/sda1 / : exists /ODP_ESP.TAG
    expect_pass "OS marker exists" \
        guestfish --ro -a "$TARGET" run : mount /dev/sda3 / : exists /ODP_OS.TAG

    assert_have_fn ucsi_remove_e2e_result
    IMPORTED="$SCRATCH/imported-prepared.qcow2"
    IMPORTED_BASE="$SCRATCH/imported-base.qcow2"
    IMPORTED_OVERLAY="$SCRATCH/imported-overlay.qcow2"
    guestfish -a "$TARGET" run : mount /dev/sda3 / \
        : write /ucsi-e2e-result.txt "$UCSI_PASS_LINE"
    expect_pass "prepared image imports into a pristine cached base" \
        ucsi_atomic_convert qcow2 "$TARGET" "$IMPORTED_BASE"
    expect_pass "imported prepared image gets a disposable overlay" \
        ucsi_make_overlay "$IMPORTED_OVERLAY" "$IMPORTED_BASE" qcow2
    expect_eq "imported prepared image overlay initially exposes stale PASS" true \
        "$(guestfish --ro -a "$IMPORTED_OVERLAY" run : mount-ro /dev/sda3 / \
            : is-file /ucsi-e2e-result.txt 2>/dev/null || true)"
    expect_pass "final E2E preparation removes stale PASS from imported overlay" \
        ucsi_remove_e2e_result "$IMPORTED_OVERLAY"
    expect_eq "stale PASS is absent from disposable overlay" false \
        "$(guestfish --ro -a "$IMPORTED_OVERLAY" run : mount-ro /dev/sda3 / \
            : is-file /ucsi-e2e-result.txt 2>/dev/null || true)"
    expect_eq "stale PASS remains untouched in imported cached base" true \
        "$(guestfish --ro -a "$IMPORTED_BASE" run : mount-ro /dev/sda3 / \
            : is-file /ucsi-e2e-result.txt 2>/dev/null || true)"
    expect_pass "missing E2E result is accepted" \
        ucsi_remove_e2e_result "$IMPORTED_OVERLAY"
    printf 'not an image' > "$IMPORTED"
    expect_fail "E2E result cleanup failure is reported before boot" \
        ucsi_remove_e2e_result "$IMPORTED"
    expect_contains "run overlay preparation requires stale-result cleanup" \
        <(declare -f ucsi_prepare_run_overlay) \
        'ucsi_remove_e2e_result "\$overlay".*\|\| return'
else
    echo "  SKIP: guestfish/qemu-img unavailable"
fi

echo "== builder result and batch contract =="
assert_have_fn ucsi_check_builder_result
printf 'PASS: local image build\r\n' > "$SCRATCH/builder-pass.txt"
printf 'FAIL: errorlevel=1\r\n' > "$SCRATCH/builder-fail.txt"
expect_pass "exact builder PASS accepted" \
    ucsi_check_builder_result "$SCRATCH/builder-pass.txt"
expect_fail "builder FAIL rejected" \
    ucsi_check_builder_result "$SCRATCH/builder-fail.txt"
printf 'PASS: local image build extra\r\n' > "$SCRATCH/builder-bad.txt"
expect_fail "malformed builder PASS rejected" \
    ucsi_check_builder_result "$SCRATCH/builder-bad.txt"

expect_pass "committed Windows builder batch exists" test -f "$BUILDER_BATCH"
expect_contains "batch applies local ValidationOS WIM" "$BUILDER_BATCH" \
    'ValidationOS\.wim.*Apply-Image|Apply-Image.*ValidationOS\.wim'
expect_contains "batch uses injected ARM64 DISM" "$BUILDER_BATCH" \
    'C:\\ucsi-builder\\dism\\dism\.exe|%ROOT%\\dism\\dism\.exe'
expect_contains "batch injects unsigned drivers" "$BUILDER_BATCH" \
    '/Add-Driver.*/ForceUnsigned'
expect_contains "batch locates target by marker" "$BUILDER_BATCH" 'ODP_OS\.TAG'
expect_contains "batch locates ESP by marker" "$BUILDER_BATCH" 'ODP_ESP\.TAG'
expect_contains "batch mounts unlettered marker volume" "$BUILDER_BATCH" 'mountvol'
expect_not_contains "batch does not require diskpart" "$BUILDER_BATCH" '(^|[^A-Za-z])diskpart([^A-Za-z]|$)'
expect_not_contains "batch does not require bcdboot" "$BUILDER_BATCH" '(^|[^A-Za-z])bcdboot([^A-Za-z]|$)'
expect_contains "batch manually copies EFI boot files" "$BUILDER_BATCH" 'Windows\\Boot\\EFI'
expect_contains "batch uses fixed osloader GUID" "$BUILDER_BATCH" \
    '\{01234567-89ab-cdef-0123-456789abcdef\}'
expect_contains "batch creates BCD with builder bcdedit" "$BUILDER_BATCH" \
    'C:\\Windows\\System32\\bcdedit\.exe'
expect_contains "batch writes exact PASS marker" "$BUILDER_BATCH" \
    '> *"%ROOT%\\build-result\.txt" +echo PASS: local image build'
expect_contains "batch writes detailed build log" "$BUILDER_BATCH" \
    'C:\\ucsi-builder\\build\.log|%ROOT%\\build\.log'

assert_have_fn ucsi_publish_built_base
if command -v qemu-img >/dev/null 2>&1; then
    PUBLISH_RUN="$SCRATCH/publish-failure-run"
    PUBLISH_FINAL="$SCRATCH/published.qcow2"
    mkdir -p "$PUBLISH_RUN"
    printf 'builder evidence' > "$PUBLISH_RUN/builder-boot.log"
    qemu-img create -q -f qcow2 "$PUBLISH_RUN/target.qcow2" 8M
    mkdir -p "$PUBLISH_FINAL/target.qcow2"
    expect_fail "failed atomic base publish returns nonzero" \
        ucsi_publish_built_base "$PUBLISH_RUN/target.qcow2" \
            "$PUBLISH_FINAL" "$PUBLISH_RUN"
    expect_pass "failed atomic base publish preserves builder evidence directory" \
        test -f "$PUBLISH_RUN/builder-boot.log"

    INVALID_RUN="$SCRATCH/publish-invalid-run"
    mkdir -p "$INVALID_RUN"
    printf 'builder evidence' > "$INVALID_RUN/builder-boot.log"
    printf 'not qcow2' > "$INVALID_RUN/target.qcow2"
    expect_fail "invalid builder target is rejected before publication" \
        ucsi_publish_built_base "$INVALID_RUN/target.qcow2" \
            "$SCRATCH/invalid-published.qcow2" "$INVALID_RUN"
    expect_pass "target validation failure preserves builder evidence directory" \
        test -f "$INVALID_RUN/builder-boot.log"

    SUCCESS_RUN="$SCRATCH/publish-success-run"
    mkdir -p "$SUCCESS_RUN"
    printf 'builder evidence' > "$SUCCESS_RUN/builder-boot.log"
    qemu-img create -q -f qcow2 "$SUCCESS_RUN/target.qcow2" 8M
    expect_pass "validated builder target publishes atomically" \
        ucsi_publish_built_base "$SUCCESS_RUN/target.qcow2" \
            "$SCRATCH/success-published.qcow2" "$SUCCESS_RUN"
    expect_pass "builder evidence directory is removed only after successful publish" \
        test ! -e "$SUCCESS_RUN"
fi

echo "== optional builder target wrapper =="
CAPTURE="$SCRATCH/qemu-args.txt"
FAKE_QEMU="$SCRATCH/fake-qemu"
cat > "$FAKE_QEMU" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$QEMU_CAPTURE"
[ -z "${QEMU_CHILD_PID:-}" ] || printf '%s\n' "$$" > "$QEMU_CHILD_PID"
EOF
chmod +x "$FAKE_QEMU"
expect_pass "normal wrapper invocation remains unchanged" \
    env -u UCSI_BUILDER_TARGET REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" \
    EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_not_contains "normal invocation has no target NVMe" "$CAPTURE" 'ODPTARGET|UCSI'
expect_pass "explicit builder target appends second NVMe" \
    env UCSI_BUILDER_TARGET="/workspaces/repo/target.qcow2" \
    REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" EC_I2C_SOCK= EC_GPIO_SOCK= \
    QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_contains "target drive uses explicit qcow2 path" "$CAPTURE" \
    'file=/workspaces/repo/target\.qcow2,format=qcow2'
expect_contains "target is attached as NVMe" "$CAPTURE" \
    'nvme,drive=ucsi-builder-target,serial=ODPTARGET001'
expect_fail "explicit empty builder target is rejected" \
    env UCSI_BUILDER_TARGET= REAL_QEMU="$FAKE_QEMU" QEMU_CAPTURE="$CAPTURE" \
    EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_contains "UEFI run forwards the optional builder target into devcontainer" \
    "$UEFI_MAKEFILE" 'UCSI_BUILDER_TARGET=\$\(UCSI_BUILDER_TARGET\)'
PID_FILE="$SCRATCH/qemu.pid"
CHILD_PID="$SCRATCH/qemu-child.pid"
expect_pass "wrapper records the exact QEMU PID when requested" \
    env UCSI_QEMU_PID_FILE="$PID_FILE" REAL_QEMU="$FAKE_QEMU" \
    QEMU_CAPTURE="$CAPTURE" QEMU_CHILD_PID="$CHILD_PID" \
    EC_I2C_SOCK= EC_GPIO_SOCK= QEMU_DISPLAY=none "$WRAPPER" -machine virt
expect_eq "recorded PID belongs to the exec'd QEMU process" \
    "$(cat "$CHILD_PID" 2>/dev/null || true)" "$(cat "$PID_FILE" 2>/dev/null || true)"
expect_contains "UEFI run forwards the optional owned PID file" \
    "$UEFI_MAKEFILE" 'UCSI_QEMU_PID_FILE=\$\(UCSI_QEMU_PID_FILE\)'
expect_contains "UEFI run creates TPM state inside devcontainer" \
    "$UEFI_MAKEFILE" '\$\(DC_RUN\).*mkdir -p.*TPM_DEV'

echo "== headless and rootless security =="
expect_not_contains "runner has no workflow CLI" "$PROD" \
    'gh workflow|gh run (watch|download|list|view)|workflow_dispatch'
expect_not_contains "runner has no VNC automation" "$PROD" \
    'vncdo|vncdotool|UCSI_VNC|Pillow|from PIL|prompt\.png'
expect_not_contains "devcontainer has no VNC Python packages" "$DOCKERFILE" \
    'vncdotool|Pillow'
expect_not_contains "runner never uses sudo" "$PROD" '(^|[^A-Za-z])sudo([^A-Za-z]|$)'
expect_not_contains "runner never kills by process name" "$PROD" \
    '(^|[^A-Za-z])(pkill|killall)([^A-Za-z]|$)'
assert_have_fn ucsi_qemu_pid_alive
assert_have_fn ucsi_signal_qemu_pid
expect_contains "runner probes the recorded PID through a remote shell" "$PROD" \
    'ucsi_dc sh -c.*kill -0'
expect_contains "runner terminates only its recorded QEMU PID" "$PROD" \
    'ucsi_signal_qemu_pid "\$qemu_pid"'
expect_contains "runner boots headless" "$PROD" 'QEMU_DISPLAY=none'
expect_contains "runner prepares rootless guestfish" "$PROD" 'ucsi_prepare_guestfish'
expect_contains "runner exports cached supermin kernel" "$PROD" 'export SUPERMIN_KERNEL'
expect_contains "kernel-cache cleanup trap has an initialized temp path" "$PROD" \
    'local kernel_dir work package extracted temporary=""'
expect_contains "runner edits Winlogon offline" "$PROD" 'virt-win-reg'
assert_have_fn ucsi_cache_tree_safe
mkdir -p "$SCRATCH/cache-root/cache/libguestfs" "$SCRATCH/cache-root/outside"
expect_pass "ordinary cache tree is accepted" \
    ucsi_cache_tree_safe "$SCRATCH/cache-root/cache" "$SCRATCH/cache-root"
ln -s "$SCRATCH/cache-root/outside" "$SCRATCH/cache-root/cache/libguestfs/escaped"
expect_fail "symlink inside cache tree is rejected" \
    ucsi_cache_tree_safe "$SCRATCH/cache-root/cache" "$SCRATCH/cache-root"
rm "$SCRATCH/cache-root/cache/libguestfs/escaped"
ln -s "$SCRATCH/cache-root/outside" "$SCRATCH/cache-root/cache/cargo-home"
expect_fail "symlinked Cargo home is rejected without scanning SDK internals" \
    ucsi_cache_tree_safe "$SCRATCH/cache-root/cache" "$SCRATCH/cache-root"
rm "$SCRATCH/cache-root/cache/cargo-home"
ln -s "$SCRATCH/cache-root/outside" "$SCRATCH/cache-root/symlink-cache"
expect_fail "symlinked cache root is rejected" \
    ucsi_cache_tree_safe "$SCRATCH/cache-root/symlink-cache" "$SCRATCH/cache-root"
expect_contains "ACPI compiler output cannot corrupt returned cache path" "$PROD" \
    'bash "\$input" "\$output" *>&2'
assert_have_fn ucsi_devcontainer_git_mount
expect_eq "external worktree git metadata is mounted at the same path" \
    "type=bind,source=$SCRATCH/git-common,target=$SCRATCH/git-common" \
    "$(ucsi_devcontainer_git_mount "$SCRATCH/worktree" "$SCRATCH/git-common" 2>/dev/null || true)"
expect_eq "git metadata already inside workspace needs no extra mount" "" \
    "$(ucsi_devcontainer_git_mount "$SCRATCH/worktree" "$SCRATCH/worktree/.git" 2>/dev/null || true)"
assert_have_fn ucsi_devcontainer_worktree_mount
expect_eq "external worktree is also mounted at its host path" \
    "type=bind,source=$SCRATCH/worktree,target=$SCRATCH/worktree" \
    "$(ucsi_devcontainer_worktree_mount "$SCRATCH/worktree" "$SCRATCH/git-common" 2>/dev/null || true)"
expect_contains "devcontainer startup accepts the external git metadata mount" \
    "$PROD" 'devcontainer up.*--mount|mount_args'

echo "== failure preservation and verdict =="
assert_have_fn ucsi_run_registry_path
expect_eq "smoke Shell registry stays inside its run directory" \
    "$SCRATCH/run/smoke-shell.reg" \
    "$(ucsi_run_registry_path "$SCRATCH/run" 2>/dev/null || true)"
assert_have_fn ucsi_should_delete_run_dir
expect_fail "failed run directory is preserved" ucsi_should_delete_run_dir 0 0
expect_pass "successful run directory is deleted by default" ucsi_should_delete_run_dir 1 0
expect_fail "keep flag preserves successful run directory" ucsi_should_delete_run_dir 1 1

assert_have_fn ucsi_verify_e2e_result
printf 'PASS: UCSI ACPI/FF-A E2E\r\n' > "$SCRATCH/result.txt"
printf 'boot %s secure world\n' '65467f50-827f-4e4f-8770-dbf4c3f77f45' > "$SCRATCH/boot.log"
expect_pass "exact PASS plus secure UUID accepted" \
    ucsi_verify_e2e_result "$SCRATCH/result.txt" "$SCRATCH/boot.log"
printf 'FAIL: smoke\r\n' > "$SCRATCH/result.txt"
expect_fail "FAIL plus UUID rejected" \
    ucsi_verify_e2e_result "$SCRATCH/result.txt" "$SCRATCH/boot.log"
printf 'PASS: UCSI ACPI/FF-A E2E\r\n' > "$SCRATCH/result.txt"
: > "$SCRATCH/boot.log"
expect_fail "PASS without secure UUID rejected" \
    ucsi_verify_e2e_result "$SCRATCH/result.txt" "$SCRATCH/boot.log"

echo "== repository separation contracts =="
expect_contains "UCSI inventory includes PL061 driver" "$DRIVER_LIST" \
    '^driver-pl061gpio-ARM64-Release$'
expect_contains "UCSI inventory includes QEMU I2C driver" "$DRIVER_LIST" \
    '^driver-qemui2c-ARM64-Release$'
expect_contains "UCSI inventory includes ectest driver" "$DRIVER_LIST" \
    '^driver-ectest_kmdf-ARM64-Release$'
expect_not_contains "generic inventory is not coupled to ectest" "$GENERIC_DRIVER_LIST" \
    'ectest'
expect_not_contains "generic workflow has no UCSI runner inputs" "$WORKFLOW" \
    'validation_os_url|drivers_release|driver_asset_manifest|dispatch_nonce|ucsi-smoke'
expect_not_contains "README no longer describes workflow dispatch runner" "$README" \
    'dispatches the.*workflow|workflow.*dispatch'
expect_contains "README documents Linux-local builder" "$README" \
    'Linux|local'
expect_contains "smoke crate remains isolated" "$SMOKE_DIR/Cargo.toml" '^\[workspace\]'
expect_contains "smoke crate remains Rust 1.90" "$SMOKE_DIR/rust-toolchain.toml" \
    'channel = "1\.90\.0"'
expect_pass "smoke lockfile remains committed" test -f "$SMOKE_DIR/Cargo.lock"

echo
printf 'ran %d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
