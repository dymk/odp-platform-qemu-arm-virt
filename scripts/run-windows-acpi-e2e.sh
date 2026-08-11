#!/usr/bin/env bash
# Local Linux Windows/ACPI end-to-end runner.
#
# SPDX-License-Identifier: MIT

if [ -z "${ODP_WINDOWS_ACPI_E2E_SOURCE_ONLY:-}" ]; then
    set -euo pipefail
fi

ODP_E2E_MIN_BUILD=28000
ODP_E2E_PASS_LINE='PASS: Windows ACPI E2E'
ODP_E2E_BUILDER_PASS_LINE='PASS: local image build'
ODP_E2E_CARGO_XWIN_VERSION='0.23.0'
ODP_E2E_OWNED_SIDECAR_PID=''

odp_e2e_validate_adapter() {
    local adapter="${1-}" required uuid marker entry include symlink
    local entries=()
    [ -d "$adapter" ] || return 1
    for required in smoke/Cargo.toml smoke/Cargo.lock smoke/rust-toolchain.toml \
        smoke/src/main.rs drivers.txt secure-uuid.txt; do
        [ -f "$adapter/$required" ] || return 1
    done
    odp_e2e_validate_smoke_manifest "$adapter/smoke/Cargo.toml" || return 1
    [ -s "$adapter/drivers.txt" ] || return 1
    uuid="$(cat "$adapter/secure-uuid.txt")"
    [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
        || return 1
    marker="$adapter/needs-ec-sidecar"
    [ ! -e "$marker" ] || { [ -f "$marker" ] && [ ! -s "$marker" ]; } || return 1
    for include in acpi-entry.txt acpi-includes.txt; do
        [ ! -e "$adapter/$include" ] \
            || { [ -f "$adapter/$include" ] && [ ! -L "$adapter/$include" ]; } \
            || return 1
    done
    if [ -f "$adapter/acpi-entry.txt" ]; then
        mapfile -t entries < "$adapter/acpi-entry.txt"
        [ "${#entries[@]}" -eq 1 ] || return 1
        entry="${entries[0]}"
        odp_e2e_resolve_repo_path "$entry" file >/dev/null || return 1
    fi
    if [ -f "$adapter/acpi-includes.txt" ]; then
        while IFS= read -r include; do
            [ -n "$include" ] || continue
            include="$(odp_e2e_resolve_repo_path "$include" directory)" || return 1
            symlink="$(find "$include" -type l -print -quit)" || return 1
            [ -z "$symlink" ] || return 1
        done < "$adapter/acpi-includes.txt"
    fi
}

odp_e2e_validate_smoke_manifest() {
    python3 - "$1" <<'PY'
import sys
import tomllib

try:
    with open(sys.argv[1], "rb") as manifest:
        bins = tomllib.load(manifest).get("bin", [])
except (OSError, tomllib.TOMLDecodeError):
    sys.exit(1)

sys.exit(0 if any(isinstance(binary, dict) and binary.get("name") == "smoke"
                  for binary in bins) else 1)
PY
}

odp_e2e_validate_relative_path() {
    local path="${1-}"
    [ -n "$path" ] && [ "${path#/*}" = "$path" ] || return 1
    case "/$path/" in
        */../*|*/./*) return 1 ;;
    esac
}

odp_e2e_resolve_repo_path() {
    local relative="${1-}" kind="${2-}" root lexical current component resolved
    local components=()
    odp_e2e_validate_relative_path "$relative" || return 1
    root="$(realpath -e -- "$(odp_e2e_repo_root)")" || return 1
    lexical="$(realpath -s -m -- "$root/$relative")" || return 1
    case "$lexical" in
        "$root"/*) ;;
        *) return 1 ;;
    esac
    relative="${lexical#"$root"/}"
    current="$root"
    IFS='/' read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
        current="$current/$component"
        [ ! -L "$current" ] || return 1
    done
    resolved="$(realpath -e -- "$lexical")" || return 1
    odp_e2e_path_within_repo "$resolved" "$root" || return 1
    case "$kind" in
        file) [ -f "$resolved" ] || return 1 ;;
        directory) [ -d "$resolved" ] || return 1 ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$resolved"
}

odp_e2e_adapter_needs_ec_sidecar() {
    [ -f "$1/needs-ec-sidecar" ] && [ ! -s "$1/needs-ec-sidecar" ]
}

odp_e2e_ec_socket_paths() {
    local run_dir="${1-}" root
    root="${ODP_E2E_REPO_ROOT:-$(realpath -e -- "$(odp_e2e_repo_root)")}" || return 1
    run_dir="$(realpath -m -- "$run_dir")" || return 1
    odp_e2e_path_within_repo "$run_dir" "$root" || return 1
    odp_e2e_host_to_container_path "$run_dir/ec-i2c.sock" "$root"
    odp_e2e_host_to_container_path "$run_dir/ec-gpio.sock" "$root"
}

odp_e2e_validate_sources() {
    local count=0
    [ -n "${1-}" ] && count=$((count + 1))
    [ -n "${2-}" ] && count=$((count + 1))
    [ -n "${3-}" ] && count=$((count + 1))
    [ "$count" -eq 1 ]
}

odp_e2e_ensure_rust_190() {
    if rustc +1.90.0 --version >/dev/null 2>&1; then
        return 0
    fi
    rustup toolchain install 1.90.0 --profile minimal
}

odp_e2e_validate_os_build() {
    local build="${1-}"
    case "$build" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$build" -ge "$ODP_E2E_MIN_BUILD" ]
}

odp_e2e_validate_repo_name() {
    [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

odp_e2e_validate_safe_token() {
    [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

odp_e2e_file_identity() {
    [ -f "$1" ] && [ -s "$1" ] || return 1
    printf 'sha256:%s\n' "$(sha256sum "$1" | awk '{print $1}')"
}

odp_e2e_compute_image_cache_key() {
    [ "$#" -eq 5 ] || return 2
    printf '%s\n' "$@" | sha256sum | awk '{print $1}'
}

odp_e2e_hash_inputs() {
    [ "$#" -gt 0 ] || return 1
    local path
    for path in "$@"; do
        [ -f "$path" ] || return 1
    done
    for path in "$@"; do
        printf '%s  %s\n' "$(sha256sum "$path" | awk '{print $1}')" "$(basename "$path")"
    done | sha256sum | awk '{print $1}'
}

odp_e2e_atomic_download() {
    local url="$1" final="$2" temporary="${2}.tmp.$$.$RANDOM"
    mkdir -p "$(dirname "$final")"
    (
        trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
        curl --fail --location --silent --show-error --output "$temporary" "$url" \
            || exit 1
        [ -s "$temporary" ] || exit 1
        mv -f -- "$temporary" "$final" || exit 1
        trap - EXIT HUP INT TERM
    )
}

odp_e2e_atomic_publish_directory() {
    local stage="$1" final="$2"
    [ -d "$stage" ] || return 1
    [ ! -e "$final" ] && [ ! -L "$final" ] || return 1
    mkdir -p "$(dirname "$final")"
    mv -- "$stage" "$final"
}

odp_e2e_remove_owned_tree() {
    local path="$1"
    [ ! -L "$path" ] || return 1
    [ -e "$path" ] || return 0
    chmod -R u+w -- "$path" || return 1
    rm -rf -- "$path"
}

odp_e2e_resolve_driver_asset_manifest() {
    local release_json="${1-}"
    shift || return 1
    [ "$#" -gt 0 ] || return 1
    python3 -c '
import json
import re
import sys

try:
    release = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError):
    sys.exit(1)

assets = release.get("assets")
if not isinstance(assets, list):
    sys.exit(1)

by_name = {}
for asset in assets:
    if not isinstance(asset, dict):
        continue
    name = asset.get("name")
    if not isinstance(name, str) or name in by_name:
        if isinstance(name, str) and name in by_name:
            sys.exit(1)
        continue
    by_name[name] = asset

manifest = []
for driver in sorted(set(sys.argv[1:])):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", driver):
        sys.exit(1)
    name = driver + ".zip"
    asset = by_name.get(name)
    if asset is None:
        sys.exit(1)
    asset_id = asset.get("id")
    digest = asset.get("digest")
    if not isinstance(asset_id, int) or isinstance(asset_id, bool) or asset_id <= 0:
        sys.exit(1)
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
        sys.exit(1)
    manifest.append({"name": name, "id": asset_id, "digest": digest.lower()})

print(json.dumps(manifest, separators=(",", ":")))
' "$@" <<< "$release_json"
}

odp_e2e_driver_asset_identity() {
    [ -n "${1-}" ] || return 1
    printf 'driver-assets:%s\n' "$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
}

odp_e2e_cargo_xwin_version_matches() {
    [ "${1-}" = "cargo-xwin $ODP_E2E_CARGO_XWIN_VERSION" ]
}

odp_e2e_validate_image() {
    local image="$1" expected="$2" info
    [ -f "$image" ] || return 1
    info="$(qemu-img info --output=json "$image" 2>/dev/null)" || return 1
    python3 -c '
import json, sys
try:
    info = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
sys.exit(0 if info.get("format") == sys.argv[1] else 1)
' "$expected" <<< "$info" || return 1
    [ "$expected" != qcow2 ] || qemu-img check -q "$image" >/dev/null 2>&1
}

odp_e2e_validate_supplied_image() {
    local image="$1" expected info
    case "$image" in
        *.qcow2) expected=qcow2 ;;
        *.vhdx) expected=vhdx ;;
        *) return 2 ;;
    esac
    info="$(qemu-img info --output=json "$image" 2>/dev/null)" || return 1
    python3 -c '
import json, sys
try:
    info = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
if info.get("format") != sys.argv[1]:
    sys.exit(1)
if sys.argv[1] == "qcow2" and any(
    info.get(key) for key in ("backing-filename", "full-backing-filename")
):
    sys.exit(1)
' "$expected" <<< "$info" || return 1
    [ "$expected" != qcow2 ] || qemu-img check -q "$image" >/dev/null 2>&1
}

odp_e2e_atomic_convert() {
    local source_format="$1" source="$2" final="$3"
    local temporary="${final}.tmp.$$.$RANDOM"
    mkdir -p "$(dirname "$final")"
    (
        trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
        qemu-img convert -f "$source_format" -O qcow2 "$source" "$temporary" \
            || exit 1
        odp_e2e_validate_image "$temporary" qcow2 || exit 1
        mv -f -- "$temporary" "$final" || exit 1
        trap - EXIT HUP INT TERM
    )
}

odp_e2e_create_target_image() {
    local final="$1" size="${2:-4G}" temporary="${1}.tmp.$$.$RANDOM"
    mkdir -p "$(dirname "$final")"
    (
        trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
        qemu-img create -q -f qcow2 "$temporary" "$size" || exit 1
        guestfish -a "$temporary" <<'EOF' || exit 1
run
part-init /dev/sda gpt
part-add /dev/sda p 2048 206847
part-add /dev/sda p 206848 239615
part-add /dev/sda p 239616 -2048
part-set-gpt-type /dev/sda 1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b
part-set-gpt-type /dev/sda 2 e3c9e316-0b5c-4db8-817d-f92df00215ae
part-set-gpt-type /dev/sda 3 ebd0a0a2-b9e5-4433-87c0-68b6b72699c7
mkfs vfat /dev/sda1
mkfs ntfs /dev/sda3
mount /dev/sda1 /
write /ODP_ESP.TAG ODP_ESP
umount /
mount /dev/sda3 /
write /ODP_OS.TAG ODP_OS
umount /
EOF
        odp_e2e_validate_image "$temporary" qcow2 || exit 1
        mv -f -- "$temporary" "$final" || exit 1
        trap - EXIT HUP INT TERM
    )
}

odp_e2e_check_builder_result() {
    [ -f "$1" ] || return 1
    tr -d '\r' < "$1" | grep -qxF "$ODP_E2E_BUILDER_PASS_LINE"
}

odp_e2e_check_result_file() {
    [ -f "$1" ] || return 1
    tr -d '\r' < "$1" | grep -qxF "$ODP_E2E_PASS_LINE"
}

odp_e2e_verify_e2e_result() {
    [ "$#" -eq 3 ] || return 2
    odp_e2e_check_result_file "$1" && grep -qiF "$3" "$2"
}

odp_e2e_should_delete_run_dir() {
    [ "$1" = 1 ] && [ "$2" = 0 ]
}

odp_e2e_relative_backing_path() {
    realpath -m --relative-to="$(dirname "$1")" "$2"
}

odp_e2e_path_within_repo() {
    local path root
    path="$(realpath -m -- "$1")" || return 1
    root="$(realpath -m -- "$2")" || return 1
    case "$path" in
        "$root"|"$root"/*) return 0 ;;
        *) return 1 ;;
    esac
}

odp_e2e_cache_tree_safe() {
    local cache root lexical_cache lexical_root relative current component
    local components=()
    cache="$1"
    root="$2"
    [ -d "$cache" ] && [ ! -L "$cache" ] || return 1
    lexical_cache="$(realpath -s -m -- "$cache")" || return 1
    lexical_root="$(realpath -s -m -- "$root")" || return 1
    case "$lexical_cache" in
        "$lexical_root"|"$lexical_root"/*) ;;
        *) return 1 ;;
    esac
    relative="${lexical_cache#"$lexical_root"}"
    relative="${relative#/}"
    current="$lexical_root"
    IFS='/' read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
        [ -n "$component" ] || continue
        current="$current/$component"
        [ ! -L "$current" ] || return 1
    done
    odp_e2e_path_within_repo "$(realpath -e -- "$cache")" "$(realpath -e -- "$root")" \
        || return 1
    local controlled
    for controlled in libguestfs downloads drivers validationos acpi images \
        build-runs runs tools; do
        [ ! -e "$cache/$controlled" ] \
            || [ -z "$(find "$cache/$controlled" -type l -print -quit)" ] \
            || return 1
    done
    for controlled in cargo-home cargo-target xwin; do
        [ ! -L "$cache/$controlled" ] || return 1
        [ ! -e "$cache/$controlled" ] \
            || odp_e2e_path_within_repo "$(realpath -e -- "$cache/$controlled")" "$cache" \
            || return 1
    done
}

odp_e2e_log() { printf '[windows-acpi-e2e] %s\n' "$*" >&2; }
odp_e2e_warn() { printf '[windows-acpi-e2e] WARN: %s\n' "$*" >&2; }
odp_e2e_die() { printf '[windows-acpi-e2e] ERROR: %s\n' "$*" >&2; exit 1; }

odp_e2e_usage() {
    cat <<'EOF'
Usage: run-windows-acpi-e2e.sh --adapter DIR SOURCE \
       --validation-os-build BUILD [options]

Source (exactly one):
  --validation-os-url URL       Download an ARM64 ValidationOS ISO locally.
  --validation-os-iso PATH      Use a local ARM64 ValidationOS ISO.
  --image PATH                  Use a prepared flat VHDX/QCOW2. It must already
                                contain the drivers, ACPITABL.dat, and smoke app.

Required:
  --adapter DIR                 Adapter directory containing smoke/, drivers.txt,
                                and secure-uuid.txt.
  --validation-os-build BUILD   Declared build, integer >= 28000.

Options:
  --cache-dir DIR               Local cache below this repository.
  --drivers-repo OWNER/REPO     Default: OpenDevicePartnership/odp-windows-drivers
  --drivers-release TAG         Default: latest
  --force                       Rebuild cached image and firmware.
  --builder-timeout SECONDS     Default: 900
  --boot-timeout SECONDS        Default: 900
  --keep                        Preserve a successful disposable run image.
  --help                        Show this help.

The ISO path builds entirely on Linux: rootless guestfish extracts the public
builder, cargo-xwin builds the adapter's ARM64 smoke app, and Windows runs
unattended under headless QEMU to apply the local WIM, ACPI table, drivers,
and smoke executable.
EOF
}

odp_e2e_repo_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dirname "$script_dir"
}

odp_e2e_host_to_container_path() {
    local host_path="$1" repo_root="$2"
    printf '/workspaces/%s%s\n' "$(basename "$repo_root")" "${host_path#"$repo_root"}"
}

odp_e2e_devcontainer_git_mount() {
    local repo common
    repo="$(realpath -m -- "$1")" || return 1
    common="$(realpath -m -- "$2")" || return 1
    if odp_e2e_path_within_repo "$common" "$repo"; then
        return 0
    fi
    printf 'type=bind,source=%s,target=%s\n' "$common" "$common"
}

odp_e2e_devcontainer_worktree_mount() {
    local repo common
    repo="$(realpath -m -- "$1")" || return 1
    common="$(realpath -m -- "$2")" || return 1
    if odp_e2e_path_within_repo "$common" "$repo"; then
        return 0
    fi
    printf 'type=bind,source=%s,target=%s\n' "$repo" "$repo"
}

odp_e2e_dc() {
    case "${1-}" in
        -w|--shell) "$ODP_E2E_REPO_ROOT/scripts/dc-run.sh" "$@" ;;
        *) "$ODP_E2E_REPO_ROOT/scripts/dc-run.sh" -- "$@" ;;
    esac
}

odp_e2e_require_tools() {
    local missing=() tool
    for tool in cargo curl devcontainer dpkg-deb git guestfish make python3 \
        qemu-img realpath rustup sha256sum supermin timeout unzip virt-win-reg; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    [ "${#missing[@]}" -eq 0 ] || odp_e2e_die "missing required tools: ${missing[*]}"
}

odp_e2e_validate_kernel_release() {
    [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]]
}

odp_e2e_prepare_guestfish() {
    local cache_dir="$1" release modules system_kernel cached kernel
    local kernel_dir work package extracted temporary=""
    release="$(uname -r)"
    odp_e2e_validate_kernel_release "$release" \
        || odp_e2e_die "unsupported running kernel release: $release"
    modules="/lib/modules/$release"
    [ -d "$modules" ] && [ -r "$modules" ] \
        || odp_e2e_die "matching kernel modules are unreadable: $modules"

    kernel_dir="$cache_dir/libguestfs/kernels/$release"
    cached="$kernel_dir/vmlinuz-$release"
    system_kernel="/boot/vmlinuz-$release"
    if [ ! -L "$system_kernel" ] && [ -s "$system_kernel" ] && [ -r "$system_kernel" ]; then
        kernel="$system_kernel"
    elif [ ! -L "$cached" ] && [ -s "$cached" ] && [ -r "$cached" ]; then
        kernel="$cached"
    else
        command -v apt >/dev/null 2>&1 \
            || odp_e2e_die "apt is required to populate the rootless guestfish kernel cache"
        mkdir -p "$kernel_dir" "$cache_dir/libguestfs/work"
        work="$cache_dir/libguestfs/work/kernel-$release-$$-$RANDOM"
        mkdir "$work"
        package="linux-image-$release"
        (
            set -e
            trap 'rm -rf -- "$work"; rm -f -- "$temporary"' EXIT HUP INT TERM
            mkdir "$work/packages" "$work/extracted"
            (cd "$work/packages" && apt download "$package" >/dev/null)
            local packages=("$work"/packages/*.deb)
            [ "${#packages[@]}" -eq 1 ]
            dpkg-deb -x "${packages[0]}" "$work/extracted"
            extracted="$(find "$work/extracted" -type f -name "vmlinuz-$release" -print -quit)"
            [ -n "$extracted" ] && [ -s "$extracted" ]
            temporary="${cached}.tmp.$$.$RANDOM"
            cp "$extracted" "$temporary"
            chmod u+rw "$temporary"
            mv -f "$temporary" "$cached"
            temporary=""
        )
        kernel="$cached"
    fi

    SUPERMIN_KERNEL="$kernel"
    SUPERMIN_MODULES="$modules"
    export SUPERMIN_KERNEL
    export SUPERMIN_MODULES
    odp_e2e_log "guestfish kernel: $SUPERMIN_KERNEL"

    local preflight="$cache_dir/libguestfs/preflight-$$-$RANDOM.img"
    mkdir -p "$(dirname "$preflight")"
    if ! guestfish -N "$preflight=disk:1M" list-devices >/dev/null; then
        rm -f "$preflight"
        odp_e2e_die "guestfish could not launch its rootless appliance"
    fi
    rm -f "$preflight"
}

odp_e2e_git_state_identity() {
    local repo="$1"
    shift
    (
        git -C "$repo" rev-parse HEAD
        git -C "$repo" diff --binary HEAD -- "$@"
        git -C "$repo" ls-files --others --exclude-standard -- "$@" |
            while IFS= read -r path; do
                case "$path" in
                    target/*|Build/*|.cache/*) continue ;;
                esac
                printf 'untracked:%s:' "$path"
                sha256sum "$repo/$path"
            done
    ) | sha256sum | awk '{print $1}'
}

odp_e2e_firmware_identity() {
    local repo="$1" top secure patina
    top="$(odp_e2e_git_state_identity "$repo" .gitmodules mod/secure-services/platform mod/uefi/platform)"
    secure="$(odp_e2e_git_state_identity "$repo/mod/secure-services/odp-secure-services" .)"
    patina="$(odp_e2e_git_state_identity "$repo/mod/uefi/patina-qemu" Platforms/QemuArmVirtPkg)"
    printf 'top=%s secure=%s patina=%s\n' "$top" "$secure" "$patina" |
        sha256sum | awk '{print $1}'
}

odp_e2e_ensure_devcontainer() {
    local stamp="$ODP_E2E_REPO_ROOT/.devcontainer-up.stamp"
    local config="$ODP_E2E_REPO_ROOT/.devcontainer/devcontainer.json"
    local dockerfile="$ODP_E2E_REPO_ROOT/.devcontainer/Dockerfile"
    local container_repo="/workspaces/$(basename "$ODP_E2E_REPO_ROOT")"
    local common mount needs_up=0
    local mount_args=()

    if [ ! -f "$stamp" ] || [ "$config" -nt "$stamp" ] || [ "$dockerfile" -nt "$stamp" ]; then
        needs_up=1
    elif ! devcontainer exec --workspace-folder "$ODP_E2E_REPO_ROOT" \
        git -C "$container_repo/mod/uefi/patina-qemu" rev-parse HEAD >/dev/null 2>&1; then
        needs_up=1
    fi
    [ "$needs_up" = 1 ] || return 0

    common="$(git -C "$ODP_E2E_REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)"
    mount="$(odp_e2e_devcontainer_git_mount "$ODP_E2E_REPO_ROOT" "$common")"
    [ -z "$mount" ] || mount_args+=(--mount "$mount")
    mount="$(odp_e2e_devcontainer_worktree_mount "$ODP_E2E_REPO_ROOT" "$common")"
    [ -z "$mount" ] || mount_args+=(--mount "$mount")
    devcontainer up --remove-existing-container \
        --workspace-folder "$ODP_E2E_REPO_ROOT" \
        --remote-env GIT_COMMITTER_NAME=vscode \
        --remote-env GIT_COMMITTER_EMAIL=vscode@example.com \
        "${mount_args[@]}"
    touch "$stamp"
    devcontainer exec --workspace-folder "$ODP_E2E_REPO_ROOT" \
        git -C "$container_repo/mod/uefi/patina-qemu" rev-parse HEAD >/dev/null \
        || odp_e2e_die "devcontainer cannot read worktree submodule git metadata"
}

odp_e2e_ensure_firmware() {
    local cache_dir="$1" identity="$2" force="$3"
    local fv="$ODP_E2E_REPO_ROOT/mod/uefi/patina-qemu/Build/QemuArmVirtPkg/DEBUG_CLANGPDB/FV"
    local stamp="$cache_dir/firmware.stamp"
    if [ "$force" = 0 ] && [ -s "$fv/SECURE_FLASH0.fd" ] && [ -s "$fv/QEMU_EFI.fd" ] \
        && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$identity" ]; then
        odp_e2e_log "firmware cache hit"
        return 0
    fi
    odp_e2e_log "building firmware"
    make -C "$ODP_E2E_REPO_ROOT/mod" uefi
    [ -s "$fv/SECURE_FLASH0.fd" ] && [ -s "$fv/QEMU_EFI.fd" ] \
        || odp_e2e_die "firmware build did not produce the expected flash images"
    printf '%s\n' "$identity" > "$stamp"
}

odp_e2e_github_curl() {
    local url="$1"
    local headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
    if [ -n "${GH_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer ${GH_TOKEN}")
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    curl --fail --location --silent --show-error "${headers[@]}" "$url"
}

odp_e2e_driver_release_url() {
    printf 'https://api.github.com/repos/%s/releases/tags/%s\n' "$1" "$2"
}

odp_e2e_resolve_driver_assets() {
    local repo="$1" release="$2" inventory="$3" endpoint release_json
    local required=()
    endpoint="$(odp_e2e_driver_release_url "$repo" "$release")"
    release_json="$(odp_e2e_github_curl "$endpoint")" \
        || odp_e2e_die "could not resolve driver release $repo@$release"
    mapfile -t required < <(
        sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$inventory"
    )
    [ "${#required[@]}" -gt 0 ] || odp_e2e_die "empty adapter driver inventory"
    odp_e2e_resolve_driver_asset_manifest "$release_json" "${required[@]}" \
        || odp_e2e_die "driver release lacks an exact required asset ID or SHA-256 digest"
}

odp_e2e_download_github_asset() {
    local repo="$1" id="$2" final="$3" temporary="${3}.tmp.$$.$RANDOM"
    local headers=(-H 'Accept: application/octet-stream' -H 'X-GitHub-Api-Version: 2022-11-28')
    if [ -n "${GH_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer ${GH_TOKEN}")
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    mkdir -p "$(dirname "$final")"
    (
        trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
        curl --fail --location --silent --show-error "${headers[@]}" \
            --output "$temporary" \
            "https://api.github.com/repos/$repo/releases/assets/$id" || exit 1
        [ -s "$temporary" ] || exit 1
        mv -f "$temporary" "$final" || exit 1
        trap - EXIT HUP INT TERM
    )
}

odp_e2e_driver_cache_valid() {
    local root="$1" manifest="$2" name
    [ -f "$root/manifest.json" ] && [ "$(cat "$root/manifest.json")" = "$manifest" ] \
        || return 1
    while IFS= read -r name; do
        [ -d "$root/drivers/${name%.zip}" ] || return 1
        find "$root/drivers/${name%.zip}" -type f -iname '*.inf' -print -quit |
            grep -q . || return 1
    done < <(python3 -c '
import json, sys
for asset in json.load(sys.stdin):
    print(asset["name"])
' <<< "$manifest")
}

odp_e2e_prepare_drivers() {
    local cache_dir="$1" repo="$2" manifest="$3" identity final stage
    local name id digest expected actual zip
    identity="$(odp_e2e_driver_asset_identity "$manifest")"
    final="$cache_dir/drivers/${identity#driver-assets:}"
    if odp_e2e_driver_cache_valid "$final" "$manifest"; then
        printf '%s\n' "$final/drivers"
        return 0
    fi
    stage="${final}.tmp.$$.$RANDOM"
    odp_e2e_remove_owned_tree "$stage"
    mkdir -p "$stage/drivers" "$cache_dir/downloads/drivers"
    while IFS=$'\t' read -r name id digest; do
        zip="$cache_dir/downloads/drivers/$id-$name"
        expected="${digest#sha256:}"
        if [ -f "$zip" ]; then
            actual="$(sha256sum "$zip" | awk '{print $1}')"
            [ "$actual" = "$expected" ] || rm -f "$zip"
        fi
        if [ ! -f "$zip" ]; then
            odp_e2e_log "downloading immutable driver asset $id ($name)"
            odp_e2e_download_github_asset "$repo" "$id" "$zip"
        fi
        actual="$(sha256sum "$zip" | awk '{print $1}')"
        if [ "$actual" != "$expected" ]; then
            odp_e2e_remove_owned_tree "$stage"
            odp_e2e_die "SHA-256 mismatch for driver asset $name"
        fi
        mkdir -p "$stage/drivers/${name%.zip}"
        unzip -oq "$zip" -d "$stage/drivers/${name%.zip}" < /dev/null
    done < <(python3 -c '
import json, sys
for asset in json.load(sys.stdin):
    print("%s\t%s\t%s" % (asset["name"], asset["id"], asset["digest"]))
' <<< "$manifest")
    printf '%s\n' "$manifest" > "$stage/manifest.json"
    odp_e2e_driver_cache_valid "$stage" "$manifest" \
        || { odp_e2e_remove_owned_tree "$stage"; odp_e2e_die "extracted driver cache is incomplete"; }
    odp_e2e_remove_owned_tree "$final"
    odp_e2e_atomic_publish_directory "$stage" "$final" \
        || { odp_e2e_remove_owned_tree "$stage"; odp_e2e_die "could not publish driver cache"; }
    printf '%s\n' "$final/drivers"
}

odp_e2e_resolve_iso() {
    local cache_dir="$1" url="$2" local_iso="$3" os_build="$4" force="$5" target
    if [ -n "$local_iso" ]; then
        [ -r "$local_iso" ] && [ -s "$local_iso" ] \
            || odp_e2e_die "ValidationOS ISO is unreadable or empty: $local_iso"
        realpath -e "$local_iso"
        return 0
    fi
    target="$cache_dir/downloads/validationos-$(printf '%s\n%s\n' "$url" "$os_build" \
        | sha256sum | awk '{print $1}').iso"
    if [ "$force" = 1 ] || [ ! -s "$target" ]; then
        odp_e2e_log "downloading ValidationOS ISO"
        odp_e2e_atomic_download "$url" "$target" \
            || odp_e2e_die "ValidationOS ISO download failed"
    fi
    printf '%s\n' "$target"
}

odp_e2e_extract_validation_os() {
    local cache_dir="$1" iso="$2" identity="$3"
    local final="$cache_dir/validationos/${identity#sha256:}" stage
    if [ -s "$final/ValidationOS.vhdx" ] && [ -s "$final/ValidationOS.wim" ] \
        && [ -s "$final/dism/dism.exe" ]; then
        printf '%s\n' "$final"
        return 0
    fi
    stage="${final}.tmp.$$.$RANDOM"
    odp_e2e_remove_owned_tree "$stage"
    mkdir -p "$stage"
    odp_e2e_log "extracting ValidationOS builder, WIM, and ARM64 DISM"
    if ! guestfish --ro -a "$iso" run : mount-ro /dev/sda / \
        : download /ValidationOS.vhdx "$stage/ValidationOS.vhdx" \
        : download /ValidationOS.wim "$stage/ValidationOS.wim" \
        : copy-out /GenImage/Tools/DISM/arm64 "$stage"; then
        odp_e2e_remove_owned_tree "$stage"
        odp_e2e_die "ISO is not a supported ValidationOS UDF image"
    fi
    [ -d "$stage/arm64" ] && mv "$stage/arm64" "$stage/dism"
    if [ ! -s "$stage/ValidationOS.vhdx" ] || [ ! -s "$stage/ValidationOS.wim" ] \
        || [ ! -s "$stage/dism/dism.exe" ]; then
        odp_e2e_remove_owned_tree "$stage"
        odp_e2e_die "ValidationOS ISO is missing the builder, WIM, or ARM64 DISM"
    fi
    odp_e2e_remove_owned_tree "$final"
    odp_e2e_atomic_publish_directory "$stage" "$final" \
        || { odp_e2e_remove_owned_tree "$stage"; odp_e2e_die "could not publish ValidationOS extraction"; }
    printf '%s\n' "$final"
}

odp_e2e_ensure_cargo_xwin() {
    local cache_dir="$1" candidate tool_root
    odp_e2e_ensure_rust_190
    candidate="$(command -v cargo-xwin 2>/dev/null || true)"
    if [ -n "$candidate" ] \
        && odp_e2e_cargo_xwin_version_matches "$("$candidate" --version 2>/dev/null)"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    tool_root="$cache_dir/tools/cargo-xwin-$ODP_E2E_CARGO_XWIN_VERSION"
    candidate="$tool_root/bin/cargo-xwin"
    if [ -x "$candidate" ] \
        && odp_e2e_cargo_xwin_version_matches "$("$candidate" --version 2>/dev/null)"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    mkdir -p "$tool_root" "$cache_dir/cargo-home"
    CARGO_HOME="$cache_dir/cargo-home" \
        cargo +1.90.0 install cargo-xwin --version 0.23.0 --locked --root "$tool_root"
    odp_e2e_cargo_xwin_version_matches "$("$candidate" --version 2>/dev/null)" \
        || odp_e2e_die "cargo-xwin installation did not produce version $ODP_E2E_CARGO_XWIN_VERSION"
    printf '%s\n' "$candidate"
}

odp_e2e_build_smoke() {
    local cache_dir="$1" cargo_xwin="$2" adapter="$3" target_dir exe
    target_dir="$cache_dir/cargo-target/smoke"
    mkdir -p "$cache_dir/cargo-home" "$cache_dir/xwin" "$target_dir"
    odp_e2e_ensure_rust_190
    exe="$target_dir/aarch64-pc-windows-msvc/release/smoke.exe"
    rm -f "$exe"
    (
        cd "$adapter/smoke"
        PATH="$(dirname "$cargo_xwin"):$PATH" \
        CARGO_HOME="$cache_dir/cargo-home" \
        CARGO_TARGET_DIR="$target_dir" \
        XWIN_CACHE_DIR="$cache_dir/xwin" \
            cargo +1.90.0 xwin build --locked --release --target aarch64-pc-windows-msvc || exit 1
    ) || odp_e2e_die "cargo-xwin failed to build smoke.exe"
    [ -s "$exe" ] || odp_e2e_die "cargo-xwin did not produce smoke.exe"
    printf '%s\n' "$exe"
}

odp_e2e_build_acpi() {
    local cache_dir="$1" identity="$2" adapter="$3" final stage input output
    local entry="mod/uefi/platform/QemuArmVirtPkg/AcpiTables/ec.asl"
    local include_path include_container
    local includes=()
    final="$cache_dir/acpi/$identity"
    if [ -s "$final/ACPITABL.dat" ]; then
        printf '%s\n' "$final/ACPITABL.dat"
        return 0
    fi
    stage="${final}.tmp.$$.$RANDOM"
    odp_e2e_remove_owned_tree "$stage"
    mkdir -p "$stage"
    if [ -f "$adapter/acpi-entry.txt" ]; then
        entry="$(cat "$adapter/acpi-entry.txt")"
    fi
    input="$(odp_e2e_host_to_container_path "$ODP_E2E_REPO_ROOT/$entry" \
        "$ODP_E2E_REPO_ROOT")"
    output="$(odp_e2e_host_to_container_path "$stage" "$ODP_E2E_REPO_ROOT")"
    includes+=("$(dirname "$input")")
    if [ -f "$adapter/acpi-includes.txt" ]; then
        while IFS= read -r include_path; do
            [ -n "$include_path" ] || continue
            include_container="$(odp_e2e_host_to_container_path \
                "$ODP_E2E_REPO_ROOT/$include_path" "$ODP_E2E_REPO_ROOT")"
            includes+=("$include_container")
        done < "$adapter/acpi-includes.txt"
    fi
    odp_e2e_dc bash -c '
set -e
input=$1
output=$2
shift 2
include_args=()
for include in "$@"; do
    include_args+=(-I "$include")
done
iasl -tc -p "$output/table" "${include_args[@]}" "$input"
cp "$output/table.aml" "$output/ACPITABL.dat"
' bash "$input" "$output" "${includes[@]}" >&2
    [ -s "$stage/ACPITABL.dat" ] || odp_e2e_die "iasl did not produce ACPITABL.dat"
    odp_e2e_atomic_publish_directory "$stage" "$final" \
        || { odp_e2e_remove_owned_tree "$stage"; odp_e2e_die "could not publish ACPI cache"; }
    printf '%s\n' "$final/ACPITABL.dat"
}

odp_e2e_make_overlay() {
    local overlay="$1" base="$2" format="$3" relative
    mkdir -p "$(dirname "$overlay")"
    relative="$(odp_e2e_relative_backing_path "$overlay" "$base")"
    (
        cd "$(dirname "$overlay")"
        qemu-img create -q -f qcow2 -F "$format" -b "$relative" "$(basename "$overlay")"
    )
}

odp_e2e_write_shell_registry() {
    local file="$1" command="$2"
    cat > "$file" <<EOF
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon]
"Shell"="$command"
EOF
}

odp_e2e_set_winlogon_shell() {
    local image="$1" registry_file="$2"
    virt-win-reg --format qcow2 --merge "$image" < "$registry_file"
}

odp_e2e_inject_builder_payload() {
    local overlay="$1" extracted="$2" drivers="$3" acpi="$4" smoke="$5"
    guestfish -a "$overlay" -i \
        mkdir-p /odp-e2e-builder \
        : upload "$extracted/ValidationOS.wim" /odp-e2e-builder/ValidationOS.wim \
        : upload "$acpi" /odp-e2e-builder/ACPITABL.dat \
        : upload "$smoke" /odp-e2e-builder/smoke.exe \
        : upload "$ODP_E2E_REPO_ROOT/postbuild/os/windows-acpi-e2e/build-validationos.cmd" /odp-e2e-builder/build.cmd \
        : copy-in "$extracted/dism" /odp-e2e-builder \
        : copy-in "$drivers" /odp-e2e-builder
}

odp_e2e_qemu_pid_alive() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    odp_e2e_dc sh -c 'kill -0 "$1"' sh "$1"
}

odp_e2e_signal_qemu_pid() {
    local pid="$1" signal="$2"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    case "$signal" in
        TERM|KILL) ;;
        *) return 1 ;;
    esac
    odp_e2e_dc sh -c 'kill "-$1" "$2"' sh "$signal" "$pid"
}

odp_e2e_start_ec_sidecar() {
    local run_dir="$1" i2c_container="$2" gpio_container="$3"
    local log pid_file binary_container log_container pid_container
    git -C "$ODP_E2E_REPO_ROOT" submodule update --init --recursive -- mod/ec \
        || return 1
    odp_e2e_dc -w mod/ec/platform/dev-qemu -- cargo build --release --locked \
        || return 1
    log="$run_dir/ec-sidecar.log"
    pid_file="$run_dir/ec-sidecar.pid"
    binary_container="$(odp_e2e_host_to_container_path \
        "$ODP_E2E_REPO_ROOT/mod/ec/platform/dev-qemu/target/riscv32imac-unknown-none-elf/release/dev-qemu" \
        "$ODP_E2E_REPO_ROOT")"
    log_container="$(odp_e2e_host_to_container_path "$log" "$ODP_E2E_REPO_ROOT")"
    pid_container="$(odp_e2e_host_to_container_path "$pid_file" "$ODP_E2E_REPO_ROOT")"
    odp_e2e_dc sh -c '
set -eu
setsid qemu-system-riscv32 \
    -machine ec \
    -bios none \
    -kernel "$1" \
    -semihosting \
    -display none \
    -serial pty \
    -monitor none \
    -no-reboot \
    -chardev socket,id=ec-i2c-target,path="$4",server=on,wait=off \
    -chardev socket,id=ec-gpio0,path="$5",server=on,wait=off \
    >"$2" 2>&1 </dev/null &
printf "%s\n" "$!" > "$3"
' sh "$binary_container" "$log_container" "$pid_container" "$i2c_container" "$gpio_container" \
        || return 1
    ODP_E2E_OWNED_SIDECAR_PID="$(cat "$pid_file")"
    [[ "$ODP_E2E_OWNED_SIDECAR_PID" =~ ^[0-9]+$ ]] \
        || odp_e2e_die "EC sidecar did not record a valid PID"
}

odp_e2e_discover_ec_pty() {
    local log="$1" attempts="${2:-100}" i pty
    for ((i = 0; i < attempts; i++)); do
        pty="$(grep -aoE '/dev/pts/[0-9]+' "$log" 2>/dev/null | head -1 || true)"
        if [ -n "$pty" ]; then
            printf '%s\n' "$pty"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

odp_e2e_stop_ec_sidecar() {
    local pid="${1-}" i
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    odp_e2e_dc sh -c 'kill -TERM "$1" 2>/dev/null || true' sh "$pid" || true
    for ((i = 0; i < 50; i++)); do
        odp_e2e_dc sh -c 'kill -0 "$1" 2>/dev/null' sh "$pid" || return 0
        sleep 0.1
    done
    odp_e2e_dc sh -c 'kill -KILL "$1" 2>/dev/null || true' sh "$pid" || true
}

odp_e2e_boot_qemu() {
    local image="$1" target="$2" log="$3" timeout_seconds="$4" run_dir="$5"
    local ec_pty="${6-}"
    local ec_i2c_sock="${7-}" ec_gpio_sock="${8-}"
    local image_container target_container="" tpm_container pid_container status=0 qemu_pid
    image_container="$(odp_e2e_host_to_container_path "$image" "$ODP_E2E_REPO_ROOT")"
    tpm_container="$(odp_e2e_host_to_container_path "$run_dir/swtpm/sock" "$ODP_E2E_REPO_ROOT")"
    pid_container="$(odp_e2e_host_to_container_path "$run_dir/qemu.pid" "$ODP_E2E_REPO_ROOT")"
    rm -f "$run_dir/qemu.pid"
    [ -z "$target" ] \
        || target_container="$(odp_e2e_host_to_container_path "$target" "$ODP_E2E_REPO_ROOT")"
    local args=(
        -C "$ODP_E2E_REPO_ROOT/mod/uefi" run
        "PATH_TO_OS=$image_container"
        "EC_I2C_SOCK=$ec_i2c_sock"
        "EC_GPIO_SOCK=$ec_gpio_sock"
        "QEMU_DISPLAY=none"
        "TPM_DEV=$tpm_container"
        "ODP_E2E_QEMU_PID_FILE=$pid_container"
    )
    [ -z "$target_container" ] || args+=("ODP_E2E_BUILDER_TARGET=$target_container")
    [ -z "$ec_pty" ] || args+=("ODP_E2E_EC_PTY=$ec_pty")
    timeout --signal=TERM --kill-after=15 "$timeout_seconds" \
        make "${args[@]}" > "$log" 2>&1 || status=$?
    if [ -f "$run_dir/qemu.pid" ]; then
        qemu_pid="$(cat "$run_dir/qemu.pid")"
        if odp_e2e_qemu_pid_alive "$qemu_pid" 2>/dev/null; then
            odp_e2e_signal_qemu_pid "$qemu_pid" TERM 2>/dev/null || true
            timeout 15 "$ODP_E2E_REPO_ROOT/scripts/dc-run.sh" -- \
                tail --pid="$qemu_pid" -f /dev/null >/dev/null 2>&1 || true
            if odp_e2e_qemu_pid_alive "$qemu_pid" 2>/dev/null; then
                odp_e2e_signal_qemu_pid "$qemu_pid" KILL 2>/dev/null || true
            fi
        fi
    fi
    printf '%s\n' "$status" > "$run_dir/qemu-status.txt"
}

odp_e2e_extract_builder_result() {
    local builder="$1" run_dir="$2"
    guestfish --ro -a "$builder" -i \
        download /odp-e2e-builder/build-result.txt "$run_dir/build-result.txt" \
        : download /odp-e2e-builder/build.log "$run_dir/build.log"
}

odp_e2e_validate_target_payload() {
    local target="$1"
    [ "$(guestfish --ro -a "$target" run : mount-ro /dev/sda1 / \
        : is-file /EFI/Boot/bootaa64.efi)" = true ] \
        && [ "$(guestfish --ro -a "$target" run : mount-ro /dev/sda1 / \
        : is-file /EFI/Microsoft/Boot/BCD)" = true ] \
        && [ "$(guestfish --ro -a "$target" run : mount-ro /dev/sda3 / \
        : is-file /Windows/System32/ACPITABL.dat)" = true ] \
        && [ "$(guestfish --ro -a "$target" run : mount-ro /dev/sda3 / \
        : is-file /odp-e2e/smoke.exe)" = true ]
}

odp_e2e_publish_built_base() {
    local target="$1" final="$2" run_dir="$3"
    odp_e2e_validate_image "$target" qcow2 || return 1
    mkdir -p "$(dirname "$final")" || return 1
    mv -f -- "$target" "$final" || return 1
    odp_e2e_remove_owned_tree "$run_dir"
}

odp_e2e_build_local_base() {
    local cache_dir="$1" key="$2" extracted="$3" drivers="$4"
    local acpi="$5" smoke="$6" final="$7" timeout_seconds="$8"
    local run_dir target builder registry
    run_dir="$cache_dir/build-runs/$key-$(date +%Y%m%d-%H%M%S)-$$"
    target="$run_dir/target.qcow2"
    builder="$run_dir/builder.qcow2"
    registry="$run_dir/builder-shell.reg"
    mkdir -p "$run_dir"
    odp_e2e_log "builder artifacts: $run_dir"

    if ! odp_e2e_create_target_image "$target" 4G \
        || ! odp_e2e_make_overlay "$builder" "$extracted/ValidationOS.vhdx" vhdx \
        || ! odp_e2e_inject_builder_payload "$builder" "$extracted" "$drivers" "$acpi" "$smoke"; then
        odp_e2e_warn "local image preparation failed; artifacts preserved at $run_dir"
        return 1
    fi
    odp_e2e_write_shell_registry "$registry" 'cmd.exe /c C:\\odp-e2e-builder\\build.cmd'
    if ! odp_e2e_set_winlogon_shell "$builder" "$registry"; then
        odp_e2e_warn "builder Shell injection failed; artifacts preserved at $run_dir"
        return 1
    fi

    odp_e2e_log "booting ValidationOS builder headlessly"
    odp_e2e_boot_qemu "$builder" "$target" "$run_dir/builder-boot.log" \
        "$timeout_seconds" "$run_dir"
    if ! odp_e2e_extract_builder_result "$builder" "$run_dir" \
        || ! odp_e2e_check_builder_result "$run_dir/build-result.txt" \
        || ! odp_e2e_validate_target_payload "$target"; then
        odp_e2e_warn "Windows builder did not produce a valid target; artifacts preserved at $run_dir"
        return 1
    fi

    if ! odp_e2e_publish_built_base "$target" "$final" "$run_dir"; then
        odp_e2e_warn "could not publish validated builder target; artifacts preserved at $run_dir"
        return 1
    fi
}

odp_e2e_run_registry_path() {
    printf '%s/smoke-shell.reg\n' "$1"
}

odp_e2e_remove_e2e_result() {
    local image="$1"
    guestfish -a "$image" run : mount /dev/sda3 / \
        : rm-f /odp-e2e/result.txt
}

odp_e2e_prepare_run_overlay() {
    local base="$1" overlay="$2" run_dir="$3" registry
    registry="$(odp_e2e_run_registry_path "$run_dir")"
    odp_e2e_make_overlay "$overlay" "$base" qcow2
    guestfish -a "$overlay" run : ntfsfix /dev/sda3
    odp_e2e_remove_e2e_result "$overlay" || return 1
    odp_e2e_write_shell_registry "$registry" 'cmd.exe /c C:\\odp-e2e\\smoke.exe'
    odp_e2e_set_winlogon_shell "$overlay" "$registry"
}

odp_e2e_extract_e2e_result() {
    local overlay="$1" output="$2"
    guestfish --ro -a "$overlay" run : mount-ro /dev/sda3 / \
        : download /odp-e2e/result.txt "$output"
}

odp_e2e_preserve_evidence() {
    local run_dir="$1" cache_dir="$2" evidence file
    evidence="$cache_dir/evidence/$(basename "$run_dir")"
    mkdir -p "$evidence"
    for file in result.txt boot.log qemu-status.txt ec-sidecar.log; do
        [ ! -f "$run_dir/$file" ] || cp "$run_dir/$file" "$evidence/$file"
    done
    printf '%s\n' "$evidence"
}

odp_e2e_run_e2e() {
    local cache_dir="$1" base="$2" timeout_seconds="$3" keep="$4" adapter="$5"
    local secure_uuid="$6"
    local run_dir overlay result ec_pty="" ec_i2c_sock="" ec_gpio_sock=""
    local evidence verified=0 socket_paths=()
    run_dir="$cache_dir/runs/$(date +%Y%m%d-%H%M%S)-$$"
    overlay="$run_dir/overlay.qcow2"
    result="$run_dir/result.txt"
    mkdir -p "$run_dir"
    if ! odp_e2e_prepare_run_overlay "$base" "$overlay" "$run_dir"; then
        odp_e2e_warn "run image preparation failed; artifacts preserved at $run_dir"
        return 1
    fi
    if odp_e2e_adapter_needs_ec_sidecar "$adapter"; then
        mapfile -t socket_paths < <(odp_e2e_ec_socket_paths "$run_dir")
        [ "${#socket_paths[@]}" -eq 2 ] \
            || { odp_e2e_warn "could not resolve EC sidecar socket paths"; return 1; }
        ec_i2c_sock="${socket_paths[0]}"
        ec_gpio_sock="${socket_paths[1]}"
        odp_e2e_start_ec_sidecar "$run_dir" "$ec_i2c_sock" "$ec_gpio_sock"
        ec_pty="$(odp_e2e_discover_ec_pty "$run_dir/ec-sidecar.log")" \
            || { odp_e2e_warn "EC sidecar PTY was not reported"; return 1; }
        odp_e2e_log "EC sidecar connected through $ec_pty"
    fi
    odp_e2e_log "booting adapter smoke headlessly"
    odp_e2e_boot_qemu "$overlay" "" "$run_dir/boot.log" "$timeout_seconds" \
        "$run_dir" "$ec_pty" "$ec_i2c_sock" "$ec_gpio_sock"
    if [ -n "$ODP_E2E_OWNED_SIDECAR_PID" ]; then
        odp_e2e_stop_ec_sidecar "$ODP_E2E_OWNED_SIDECAR_PID"
        ODP_E2E_OWNED_SIDECAR_PID=""
    fi
    if odp_e2e_extract_e2e_result "$overlay" "$result" \
        && odp_e2e_verify_e2e_result "$result" "$run_dir/boot.log" "$secure_uuid"; then
        verified=1
    fi
    evidence="$(odp_e2e_preserve_evidence "$run_dir" "$cache_dir")"
    odp_e2e_log "evidence: $evidence"
    if [ "$verified" = 0 ]; then
        odp_e2e_warn "E2E verification failed; artifacts preserved at $run_dir"
        return 1
    fi
    if odp_e2e_should_delete_run_dir "$verified" "$keep"; then
        rm -rf "$run_dir"
    else
        odp_e2e_log "successful run image preserved at $run_dir"
    fi
    printf '%s\n' "$ODP_E2E_PASS_LINE"
}

odp_e2e_collect_input_files() {
    local adapter="$1" file entry include
    printf '%s\n' \
        "$ODP_E2E_REPO_ROOT/scripts/run-windows-acpi-e2e.sh" \
        "$ODP_E2E_REPO_ROOT/scripts/qemu-ec-wrapper.sh" \
        "$ODP_E2E_REPO_ROOT/mod/uefi/Makefile" \
        "$ODP_E2E_REPO_ROOT/postbuild/os/windows-acpi-e2e/build-validationos.cmd" \
        "$ODP_E2E_REPO_ROOT/postbuild/os/windows-acpi-e2e/guest-support/Cargo.toml" \
        "$ODP_E2E_REPO_ROOT/postbuild/os/windows-acpi-e2e/guest-support/Cargo.lock" \
        "$ODP_E2E_REPO_ROOT/postbuild/os/windows-acpi-e2e/guest-support/rust-toolchain.toml" \
        "$ODP_E2E_REPO_ROOT/postbuild/os/windows-acpi-e2e/guest-support/src/lib.rs" \
        "$adapter/drivers.txt" \
        "$adapter/secure-uuid.txt"
    find "$adapter/smoke" -type f ! -path '*/target/*' -print | sort
    for file in needs-ec-sidecar acpi-entry.txt acpi-includes.txt; do
        [ ! -f "$adapter/$file" ] || printf '%s\n' "$adapter/$file"
    done
    while IFS= read -r file; do
        printf '%s\n' "$file"
    done < <(find "$ODP_E2E_REPO_ROOT/mod/uefi/platform/QemuArmVirtPkg/AcpiTables" \
        -type f \( -name '*.asl' -o -name '*.asi' -o -name '*.inc' \) | sort)
    if [ -f "$adapter/acpi-entry.txt" ]; then
        entry="$(odp_e2e_resolve_repo_path "$(cat "$adapter/acpi-entry.txt")" file)" \
            || return 1
        printf '%s\n' "$entry"
    fi
    if [ -f "$adapter/acpi-includes.txt" ]; then
        while IFS= read -r include; do
            [ -n "$include" ] || continue
            include="$(odp_e2e_resolve_repo_path "$include" directory)" || return 1
            find "$include" -type f \
                \( -name '*.asl' -o -name '*.asi' -o -name '*.inc' \) -print
        done < "$adapter/acpi-includes.txt" | sort
    fi
}

odp_e2e_main() {
    local adapter="" validation_os_url="" validation_os_iso="" image_path="" os_build=""
    local cache_dir="" drivers_repo="OpenDevicePartnership/odp-windows-drivers"
    local drivers_release="latest"
    local force=0 builder_timeout=900 boot_timeout=900 keep=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --adapter) [ "$#" -ge 2 ] || odp_e2e_die "$1 requires a value"; adapter="$2"; shift 2 ;;
            --validation-os-url) [ "$#" -ge 2 ] || odp_e2e_die "$1 requires a value"; validation_os_url="$2"; shift 2 ;;
            --validation-os-iso) [ "$#" -ge 2 ] || odp_e2e_die "$1 requires a value"; validation_os_iso="$2"; shift 2 ;;
            --image) [ "$#" -ge 2 ] || odp_e2e_die "$1 requires a value"; image_path="$2"; shift 2 ;;
            --validation-os-build) [ "$#" -ge 2 ] || odp_e2e_die "$1 requires a value"; os_build="$2"; shift 2 ;;
            --cache-dir) [ "$#" -ge 2 ] || odp_e2e_die "$1 requires a value"; cache_dir="$2"; shift 2 ;;
            --drivers-repo) [ "$#" -ge 2 ] || odp_e2e_die "$1 requires a value"; drivers_repo="$2"; shift 2 ;;
            --drivers-release) [ "$#" -ge 2 ] || odp_e2e_die "$1 requires a value"; drivers_release="$2"; shift 2 ;;
            --force) force=1; shift ;;
            --builder-timeout) [ "$#" -ge 2 ] || odp_e2e_die "$1 requires a value"; builder_timeout="$2"; shift 2 ;;
            --boot-timeout) [ "$#" -ge 2 ] || odp_e2e_die "$1 requires a value"; boot_timeout="$2"; shift 2 ;;
            --keep) keep=1; shift ;;
            -h|--help) odp_e2e_usage; return 0 ;;
            *) odp_e2e_usage >&2; odp_e2e_die "unknown argument: $1" ;;
        esac
    done

    odp_e2e_validate_sources "$validation_os_url" "$validation_os_iso" "$image_path" \
        || odp_e2e_die "specify exactly one of --validation-os-url, --validation-os-iso, or --image"
    odp_e2e_validate_os_build "$os_build" \
        || odp_e2e_die "--validation-os-build must be an integer >= $ODP_E2E_MIN_BUILD; build 26100 lacks ACPI FF-A"
    case "$builder_timeout" in
        ''|*[!0-9]*|0) odp_e2e_die "--builder-timeout must be a positive integer" ;;
    esac
    case "$boot_timeout" in
        ''|*[!0-9]*|0) odp_e2e_die "--boot-timeout must be a positive integer" ;;
    esac
    odp_e2e_validate_repo_name "$drivers_repo" || odp_e2e_die "invalid --drivers-repo"
    odp_e2e_validate_safe_token "$drivers_release" || odp_e2e_die "invalid --drivers-release"

    ODP_E2E_REPO_ROOT="$(realpath -e -- "$(odp_e2e_repo_root)")"
    adapter="$(realpath -e -- "$adapter")" || odp_e2e_die "--adapter directory not found"
    odp_e2e_validate_adapter "$adapter" || odp_e2e_die "invalid adapter directory"
    [ -n "$cache_dir" ] \
        || cache_dir="$ODP_E2E_REPO_ROOT/postbuild/os/build/windows-acpi-e2e-cache"
    cache_dir="$(realpath -m -- "$cache_dir")"
    odp_e2e_path_within_repo "$cache_dir" "$ODP_E2E_REPO_ROOT" \
        || odp_e2e_die "--cache-dir must be inside $ODP_E2E_REPO_ROOT"
    mkdir -p "$cache_dir"
    odp_e2e_cache_tree_safe "$cache_dir" "$ODP_E2E_REPO_ROOT" \
        || odp_e2e_die "--cache-dir must not contain symlinks"

    odp_e2e_require_tools
    odp_e2e_prepare_guestfish "$cache_dir"
    odp_e2e_ensure_devcontainer

    local firmware_identity
    firmware_identity="$(odp_e2e_firmware_identity "$ODP_E2E_REPO_ROOT")"
    odp_e2e_ensure_firmware "$cache_dir" "$firmware_identity" "$force"

    local input_files=() input_hash source_identity driver_identity key base
    mapfile -t input_files < <(odp_e2e_collect_input_files "$adapter")
    input_hash="$(odp_e2e_hash_inputs "${input_files[@]}")"

    if [ -n "$image_path" ]; then
        image_path="$(realpath -e -- "$image_path")" \
            || odp_e2e_die "prepared image not found"
        odp_e2e_validate_supplied_image "$image_path" \
            || odp_e2e_die "--image must be a flat, valid VHDX or QCOW2"
        source_identity="image:$(odp_e2e_file_identity "$image_path")"
        driver_identity="prepared-image"
        key="$(odp_e2e_compute_image_cache_key "$source_identity" "$os_build" \
            "$driver_identity" "$input_hash" "$firmware_identity")"
        base="$cache_dir/images/$key.qcow2"
        if [ "$force" = 1 ] || ! odp_e2e_validate_image "$base" qcow2; then
            case "$image_path" in
                *.qcow2) odp_e2e_atomic_convert qcow2 "$image_path" "$base" ;;
                *.vhdx) odp_e2e_atomic_convert vhdx "$image_path" "$base" ;;
            esac
        fi
    else
        local iso iso_identity extracted manifest drivers cargo_xwin smoke acpi
        iso="$(odp_e2e_resolve_iso "$cache_dir" "$validation_os_url" \
            "$validation_os_iso" "$os_build" "$force")"
        iso_identity="$(odp_e2e_file_identity "$iso")" \
            || odp_e2e_die "ValidationOS ISO is empty or unreadable"
        extracted="$(odp_e2e_extract_validation_os "$cache_dir" "$iso" "$iso_identity")"
        manifest="$(odp_e2e_resolve_driver_assets "$drivers_repo" "$drivers_release" \
            "$adapter/drivers.txt")"
        driver_identity="$(odp_e2e_driver_asset_identity "$manifest")"
        drivers="$(odp_e2e_prepare_drivers "$cache_dir" "$drivers_repo" "$manifest")"
        cargo_xwin="$(odp_e2e_ensure_cargo_xwin "$cache_dir")"
        smoke="$(odp_e2e_build_smoke "$cache_dir" "$cargo_xwin" "$adapter")"
        acpi="$(odp_e2e_build_acpi "$cache_dir" "$input_hash" "$adapter")"
        source_identity="iso:$iso_identity"
        key="$(odp_e2e_compute_image_cache_key "$source_identity" "$os_build" \
            "$driver_identity" "$input_hash" "$firmware_identity")"
        base="$cache_dir/images/$key.qcow2"
        if [ "$force" = 1 ] || ! odp_e2e_validate_image "$base" qcow2; then
            odp_e2e_build_local_base "$cache_dir" "$key" "$extracted" "$drivers" \
                "$acpi" "$smoke" "$base" "$builder_timeout" \
                || odp_e2e_die "local Windows image builder failed"
        fi
    fi

    odp_e2e_log "pristine base: $base"
    odp_e2e_run_e2e "$cache_dir" "$base" "$boot_timeout" "$keep" "$adapter" \
        "$(cat "$adapter/secure-uuid.txt")" \
        || odp_e2e_die "Windows ACPI E2E failed"
}

if [ -n "${ODP_WINDOWS_ACPI_E2E_SOURCE_ONLY:-}" ]; then
    return 0 2>/dev/null || true
else
    trap 'odp_e2e_stop_ec_sidecar "$ODP_E2E_OWNED_SIDECAR_PID"' EXIT INT TERM
    odp_e2e_main "$@"
fi
