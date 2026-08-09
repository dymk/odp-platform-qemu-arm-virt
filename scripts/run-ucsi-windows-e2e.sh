#!/usr/bin/env bash
# Local Linux Windows UCSI ACPI -> FF-A end-to-end runner.
#
# SPDX-License-Identifier: MIT

if [ -z "${UCSI_WINDOWS_E2E_SOURCE_ONLY:-}" ]; then
    set -euo pipefail
fi

UCSI_MIN_BUILD=28000
UCSI_PASS_LINE='PASS: UCSI ACPI/FF-A E2E'
UCSI_BUILDER_PASS_LINE='PASS: local image build'
UCSI_SECURE_UUID='65467f50-827f-4e4f-8770-dbf4c3f77f45'
UCSI_CARGO_XWIN_VERSION='0.23.0'

ucsi_validate_sources() {
    local count=0
    [ -n "${1-}" ] && count=$((count + 1))
    [ -n "${2-}" ] && count=$((count + 1))
    [ -n "${3-}" ] && count=$((count + 1))
    [ "$count" -eq 1 ]
}

ucsi_ensure_rust_190() {
    if rustc +1.90.0 --version >/dev/null 2>&1; then
        return 0
    fi
    rustup toolchain install 1.90.0 --profile minimal
}

ucsi_validate_os_build() {
    local build="${1-}"
    case "$build" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$build" -ge "$UCSI_MIN_BUILD" ]
}

ucsi_validate_repo_name() {
    [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

ucsi_validate_safe_token() {
    [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

ucsi_file_identity() {
    [ -f "$1" ] && [ -s "$1" ] || return 1
    printf 'sha256:%s\n' "$(sha256sum "$1" | awk '{print $1}')"
}

ucsi_compute_image_cache_key() {
    [ "$#" -eq 5 ] || return 2
    printf '%s\n' "$@" | sha256sum | awk '{print $1}'
}

ucsi_hash_inputs() {
    [ "$#" -gt 0 ] || return 1
    local path
    for path in "$@"; do
        [ -f "$path" ] || return 1
    done
    for path in "$@"; do
        printf '%s  %s\n' "$(sha256sum "$path" | awk '{print $1}')" "$(basename "$path")"
    done | sha256sum | awk '{print $1}'
}

ucsi_atomic_download() {
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

ucsi_atomic_publish_directory() {
    local stage="$1" final="$2"
    [ -d "$stage" ] || return 1
    [ ! -e "$final" ] && [ ! -L "$final" ] || return 1
    mkdir -p "$(dirname "$final")"
    mv -- "$stage" "$final"
}

ucsi_remove_owned_tree() {
    local path="$1"
    [ ! -L "$path" ] || return 1
    [ -e "$path" ] || return 0
    chmod -R u+w -- "$path" || return 1
    rm -rf -- "$path"
}

ucsi_resolve_driver_asset_manifest() {
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

ucsi_driver_asset_identity() {
    [ -n "${1-}" ] || return 1
    printf 'driver-assets:%s\n' "$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
}

ucsi_cargo_xwin_version_matches() {
    [ "${1-}" = "cargo-xwin $UCSI_CARGO_XWIN_VERSION" ]
}

ucsi_validate_image() {
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

ucsi_validate_supplied_image() {
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

ucsi_atomic_convert() {
    local source_format="$1" source="$2" final="$3"
    local temporary="${final}.tmp.$$.$RANDOM"
    mkdir -p "$(dirname "$final")"
    (
        trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
        qemu-img convert -f "$source_format" -O qcow2 "$source" "$temporary" \
            || exit 1
        ucsi_validate_image "$temporary" qcow2 || exit 1
        mv -f -- "$temporary" "$final" || exit 1
        trap - EXIT HUP INT TERM
    )
}

ucsi_create_target_image() {
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
        ucsi_validate_image "$temporary" qcow2 || exit 1
        mv -f -- "$temporary" "$final" || exit 1
        trap - EXIT HUP INT TERM
    )
}

ucsi_check_builder_result() {
    [ -f "$1" ] || return 1
    tr -d '\r' < "$1" | grep -qxF "$UCSI_BUILDER_PASS_LINE"
}

ucsi_check_result_file() {
    [ -f "$1" ] || return 1
    tr -d '\r' < "$1" | grep -qxF "$UCSI_PASS_LINE"
}

ucsi_verify_e2e_result() {
    ucsi_check_result_file "$1" && grep -qiF "$UCSI_SECURE_UUID" "$2"
}

ucsi_should_delete_run_dir() {
    [ "$1" = 1 ] && [ "$2" = 0 ]
}

ucsi_relative_backing_path() {
    realpath -m --relative-to="$(dirname "$1")" "$2"
}

ucsi_path_within_repo() {
    local path root
    path="$(realpath -m -- "$1")" || return 1
    root="$(realpath -m -- "$2")" || return 1
    case "$path" in
        "$root"|"$root"/*) return 0 ;;
        *) return 1 ;;
    esac
}

ucsi_cache_tree_safe() {
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
    ucsi_path_within_repo "$(realpath -e -- "$cache")" "$(realpath -e -- "$root")" \
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
            || ucsi_path_within_repo "$(realpath -e -- "$cache/$controlled")" "$cache" \
            || return 1
    done
}

ucsi_log() { printf '[ucsi-e2e] %s\n' "$*" >&2; }
ucsi_warn() { printf '[ucsi-e2e] WARN: %s\n' "$*" >&2; }
ucsi_die() { printf '[ucsi-e2e] ERROR: %s\n' "$*" >&2; exit 1; }

ucsi_usage() {
    cat <<'EOF'
Usage: run-ucsi-windows-e2e.sh SOURCE --validation-os-build BUILD [options]

Source (exactly one):
  --validation-os-url URL       Download an ARM64 ValidationOS ISO locally.
  --validation-os-iso PATH      Use a local ARM64 ValidationOS ISO.
  --image PATH                  Use a prepared flat VHDX/QCOW2. It must already
                                contain the drivers, ACPITABL.dat, and smoke app.

Required:
  --validation-os-build BUILD   Declared build, integer >= 28000.

Options:
  --cache-dir DIR               Local cache below this repository.
  --drivers-repo OWNER/REPO     Default: OpenDevicePartnership/odp-windows-drivers
  --drivers-release TAG         Default: latest
  --force-image                 Rebuild or reimport the pristine base image.
  --force-firmware              Rebuild UEFI and secure firmware.
  --boot-timeout SECONDS        Default: 900
  --keep-run-image              Preserve a successful disposable run image.
  --help                        Show this help.

The ISO path builds entirely on Linux: rootless guestfish extracts the public
builder, cargo-xwin builds the ARM64 smoke app, and Windows runs unattended
under headless QEMU to apply the local WIM and drivers.
EOF
}

ucsi_repo_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dirname "$script_dir"
}

ucsi_host_to_container_path() {
    local host_path="$1" repo_root="$2"
    printf '/workspaces/%s%s\n' "$(basename "$repo_root")" "${host_path#"$repo_root"}"
}

ucsi_devcontainer_git_mount() {
    local repo common
    repo="$(realpath -m -- "$1")" || return 1
    common="$(realpath -m -- "$2")" || return 1
    if ucsi_path_within_repo "$common" "$repo"; then
        return 0
    fi
    printf 'type=bind,source=%s,target=%s\n' "$common" "$common"
}

ucsi_devcontainer_worktree_mount() {
    local repo common
    repo="$(realpath -m -- "$1")" || return 1
    common="$(realpath -m -- "$2")" || return 1
    if ucsi_path_within_repo "$common" "$repo"; then
        return 0
    fi
    printf 'type=bind,source=%s,target=%s\n' "$repo" "$repo"
}

ucsi_dc() {
    "$UCSI_REPO_ROOT/scripts/dc-run.sh" -- "$@"
}

ucsi_require_tools() {
    local missing=() tool
    for tool in cargo curl devcontainer dpkg-deb git guestfish make python3 \
        qemu-img realpath rustup sha256sum supermin timeout unzip virt-win-reg; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    [ "${#missing[@]}" -eq 0 ] || ucsi_die "missing required tools: ${missing[*]}"
}

ucsi_validate_kernel_release() {
    [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]]
}

ucsi_prepare_guestfish() {
    local cache_dir="$1" release modules system_kernel cached kernel
    local kernel_dir work package extracted temporary=""
    release="$(uname -r)"
    ucsi_validate_kernel_release "$release" \
        || ucsi_die "unsupported running kernel release: $release"
    modules="/lib/modules/$release"
    [ -d "$modules" ] && [ -r "$modules" ] \
        || ucsi_die "matching kernel modules are unreadable: $modules"

    kernel_dir="$cache_dir/libguestfs/kernels/$release"
    cached="$kernel_dir/vmlinuz-$release"
    system_kernel="/boot/vmlinuz-$release"
    if [ ! -L "$system_kernel" ] && [ -s "$system_kernel" ] && [ -r "$system_kernel" ]; then
        kernel="$system_kernel"
    elif [ ! -L "$cached" ] && [ -s "$cached" ] && [ -r "$cached" ]; then
        kernel="$cached"
    else
        command -v apt >/dev/null 2>&1 \
            || ucsi_die "apt is required to populate the rootless guestfish kernel cache"
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
    ucsi_log "guestfish kernel: $SUPERMIN_KERNEL"

    local preflight="$cache_dir/libguestfs/preflight-$$-$RANDOM.img"
    mkdir -p "$(dirname "$preflight")"
    if ! guestfish -N "$preflight=disk:1M" list-devices >/dev/null; then
        rm -f "$preflight"
        ucsi_die "guestfish could not launch its rootless appliance"
    fi
    rm -f "$preflight"
}

ucsi_git_state_identity() {
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

ucsi_firmware_identity() {
    local repo="$1" top secure patina
    top="$(ucsi_git_state_identity "$repo" .gitmodules mod/secure-services/platform mod/uefi/platform)"
    secure="$(ucsi_git_state_identity "$repo/mod/secure-services/odp-secure-services" .)"
    patina="$(ucsi_git_state_identity "$repo/mod/uefi/patina-qemu" Platforms/QemuArmVirtPkg)"
    printf 'top=%s secure=%s patina=%s\n' "$top" "$secure" "$patina" |
        sha256sum | awk '{print $1}'
}

ucsi_ensure_devcontainer() {
    local stamp="$UCSI_REPO_ROOT/.devcontainer-up.stamp"
    local config="$UCSI_REPO_ROOT/.devcontainer/devcontainer.json"
    local dockerfile="$UCSI_REPO_ROOT/.devcontainer/Dockerfile"
    local container_repo="/workspaces/$(basename "$UCSI_REPO_ROOT")"
    local common mount needs_up=0
    local mount_args=()

    if [ ! -f "$stamp" ] || [ "$config" -nt "$stamp" ] || [ "$dockerfile" -nt "$stamp" ]; then
        needs_up=1
    elif ! devcontainer exec --workspace-folder "$UCSI_REPO_ROOT" \
        git -C "$container_repo/mod/uefi/patina-qemu" rev-parse HEAD >/dev/null 2>&1; then
        needs_up=1
    fi
    [ "$needs_up" = 1 ] || return 0

    common="$(git -C "$UCSI_REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)"
    mount="$(ucsi_devcontainer_git_mount "$UCSI_REPO_ROOT" "$common")"
    [ -z "$mount" ] || mount_args+=(--mount "$mount")
    mount="$(ucsi_devcontainer_worktree_mount "$UCSI_REPO_ROOT" "$common")"
    [ -z "$mount" ] || mount_args+=(--mount "$mount")
    devcontainer up --remove-existing-container \
        --workspace-folder "$UCSI_REPO_ROOT" \
        --remote-env GIT_COMMITTER_NAME=vscode \
        --remote-env GIT_COMMITTER_EMAIL=vscode@example.com \
        "${mount_args[@]}"
    touch "$stamp"
    devcontainer exec --workspace-folder "$UCSI_REPO_ROOT" \
        git -C "$container_repo/mod/uefi/patina-qemu" rev-parse HEAD >/dev/null \
        || ucsi_die "devcontainer cannot read worktree submodule git metadata"
}

ucsi_ensure_firmware() {
    local cache_dir="$1" identity="$2" force="$3"
    local fv="$UCSI_REPO_ROOT/mod/uefi/patina-qemu/Build/QemuArmVirtPkg/DEBUG_CLANGPDB/FV"
    local stamp="$cache_dir/firmware.stamp"
    if [ "$force" = 0 ] && [ -s "$fv/SECURE_FLASH0.fd" ] && [ -s "$fv/QEMU_EFI.fd" ] \
        && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$identity" ]; then
        ucsi_log "firmware cache hit"
        return 0
    fi
    ucsi_log "building firmware"
    make -C "$UCSI_REPO_ROOT/mod" uefi
    [ -s "$fv/SECURE_FLASH0.fd" ] && [ -s "$fv/QEMU_EFI.fd" ] \
        || ucsi_die "firmware build did not produce the expected flash images"
    printf '%s\n' "$identity" > "$stamp"
}

ucsi_github_curl() {
    local url="$1"
    local headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
    if [ -n "${GH_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer $GH_TOKEN")
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    curl --fail --location --silent --show-error "${headers[@]}" "$url"
}

ucsi_driver_release_url() {
    printf 'https://api.github.com/repos/%s/releases/tags/%s\n' "$1" "$2"
}

ucsi_resolve_driver_assets() {
    local repo="$1" release="$2" inventory="$3" endpoint release_json
    local required=()
    endpoint="$(ucsi_driver_release_url "$repo" "$release")"
    release_json="$(ucsi_github_curl "$endpoint")" \
        || ucsi_die "could not resolve driver release $repo@$release"
    mapfile -t required < <(
        sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$inventory"
    )
    [ "${#required[@]}" -gt 0 ] || ucsi_die "empty UCSI driver inventory"
    ucsi_resolve_driver_asset_manifest "$release_json" "${required[@]}" \
        || ucsi_die "driver release lacks an exact required asset ID or SHA-256 digest"
}

ucsi_download_github_asset() {
    local repo="$1" id="$2" final="$3" temporary="${3}.tmp.$$.$RANDOM"
    local headers=(-H 'Accept: application/octet-stream' -H 'X-GitHub-Api-Version: 2022-11-28')
    if [ -n "${GH_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer $GH_TOKEN")
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
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

ucsi_driver_cache_valid() {
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

ucsi_prepare_drivers() {
    local cache_dir="$1" repo="$2" manifest="$3" identity final stage
    local name id digest expected actual zip
    identity="$(ucsi_driver_asset_identity "$manifest")"
    final="$cache_dir/drivers/${identity#driver-assets:}"
    if ucsi_driver_cache_valid "$final" "$manifest"; then
        printf '%s\n' "$final/drivers"
        return 0
    fi
    stage="${final}.tmp.$$.$RANDOM"
    ucsi_remove_owned_tree "$stage"
    mkdir -p "$stage/drivers" "$cache_dir/downloads/drivers"
    while IFS=$'\t' read -r name id digest; do
        zip="$cache_dir/downloads/drivers/$id-$name"
        expected="${digest#sha256:}"
        if [ -f "$zip" ]; then
            actual="$(sha256sum "$zip" | awk '{print $1}')"
            [ "$actual" = "$expected" ] || rm -f "$zip"
        fi
        if [ ! -f "$zip" ]; then
            ucsi_log "downloading immutable driver asset $id ($name)"
            ucsi_download_github_asset "$repo" "$id" "$zip"
        fi
        actual="$(sha256sum "$zip" | awk '{print $1}')"
        if [ "$actual" != "$expected" ]; then
            ucsi_remove_owned_tree "$stage"
            ucsi_die "SHA-256 mismatch for driver asset $name"
        fi
        mkdir -p "$stage/drivers/${name%.zip}"
        unzip -oq "$zip" -d "$stage/drivers/${name%.zip}" < /dev/null
    done < <(python3 -c '
import json, sys
for asset in json.load(sys.stdin):
    print("%s\t%s\t%s" % (asset["name"], asset["id"], asset["digest"]))
' <<< "$manifest")
    printf '%s\n' "$manifest" > "$stage/manifest.json"
    ucsi_driver_cache_valid "$stage" "$manifest" \
        || { ucsi_remove_owned_tree "$stage"; ucsi_die "extracted driver cache is incomplete"; }
    ucsi_remove_owned_tree "$final"
    ucsi_atomic_publish_directory "$stage" "$final" \
        || { ucsi_remove_owned_tree "$stage"; ucsi_die "could not publish driver cache"; }
    printf '%s\n' "$final/drivers"
}

ucsi_resolve_iso() {
    local cache_dir="$1" url="$2" local_iso="$3" os_build="$4" force="$5" target
    if [ -n "$local_iso" ]; then
        [ -r "$local_iso" ] && [ -s "$local_iso" ] \
            || ucsi_die "ValidationOS ISO is unreadable or empty: $local_iso"
        realpath -e "$local_iso"
        return 0
    fi
    target="$cache_dir/downloads/validationos-$(printf '%s\n%s\n' "$url" "$os_build" \
        | sha256sum | awk '{print $1}').iso"
    if [ "$force" = 1 ] || [ ! -s "$target" ]; then
        ucsi_log "downloading ValidationOS ISO"
        ucsi_atomic_download "$url" "$target" \
            || ucsi_die "ValidationOS ISO download failed"
    fi
    printf '%s\n' "$target"
}

ucsi_extract_validation_os() {
    local cache_dir="$1" iso="$2" identity="$3"
    local final="$cache_dir/validationos/${identity#sha256:}" stage
    if [ -s "$final/ValidationOS.vhdx" ] && [ -s "$final/ValidationOS.wim" ] \
        && [ -s "$final/dism/dism.exe" ]; then
        printf '%s\n' "$final"
        return 0
    fi
    stage="${final}.tmp.$$.$RANDOM"
    ucsi_remove_owned_tree "$stage"
    mkdir -p "$stage"
    ucsi_log "extracting ValidationOS builder, WIM, and ARM64 DISM"
    if ! guestfish --ro -a "$iso" run : mount-ro /dev/sda / \
        : download /ValidationOS.vhdx "$stage/ValidationOS.vhdx" \
        : download /ValidationOS.wim "$stage/ValidationOS.wim" \
        : copy-out /GenImage/Tools/DISM/arm64 "$stage"; then
        ucsi_remove_owned_tree "$stage"
        ucsi_die "ISO is not a supported ValidationOS UDF image"
    fi
    [ -d "$stage/arm64" ] && mv "$stage/arm64" "$stage/dism"
    if [ ! -s "$stage/ValidationOS.vhdx" ] || [ ! -s "$stage/ValidationOS.wim" ] \
        || [ ! -s "$stage/dism/dism.exe" ]; then
        ucsi_remove_owned_tree "$stage"
        ucsi_die "ValidationOS ISO is missing the builder, WIM, or ARM64 DISM"
    fi
    ucsi_remove_owned_tree "$final"
    ucsi_atomic_publish_directory "$stage" "$final" \
        || { ucsi_remove_owned_tree "$stage"; ucsi_die "could not publish ValidationOS extraction"; }
    printf '%s\n' "$final"
}

ucsi_ensure_cargo_xwin() {
    local cache_dir="$1" candidate tool_root
    ucsi_ensure_rust_190
    candidate="$(command -v cargo-xwin 2>/dev/null || true)"
    if [ -n "$candidate" ] \
        && ucsi_cargo_xwin_version_matches "$("$candidate" --version 2>/dev/null)"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    tool_root="$cache_dir/tools/cargo-xwin-$UCSI_CARGO_XWIN_VERSION"
    candidate="$tool_root/bin/cargo-xwin"
    if [ -x "$candidate" ] \
        && ucsi_cargo_xwin_version_matches "$("$candidate" --version 2>/dev/null)"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    mkdir -p "$tool_root" "$cache_dir/cargo-home"
    CARGO_HOME="$cache_dir/cargo-home" \
        cargo +1.90.0 install cargo-xwin --version 0.23.0 --locked --root "$tool_root"
    ucsi_cargo_xwin_version_matches "$("$candidate" --version 2>/dev/null)" \
        || ucsi_die "cargo-xwin installation did not produce version $UCSI_CARGO_XWIN_VERSION"
    printf '%s\n' "$candidate"
}

ucsi_build_smoke() {
    local cache_dir="$1" cargo_xwin="$2" target_dir exe
    target_dir="$cache_dir/cargo-target/ucsi-smoke"
    mkdir -p "$cache_dir/cargo-home" "$cache_dir/xwin" "$target_dir"
    ucsi_ensure_rust_190
    exe="$target_dir/aarch64-pc-windows-msvc/release/ucsi-smoke.exe"
    rm -f "$exe"
    (
        cd "$UCSI_REPO_ROOT/postbuild/os/ucsi-smoke"
        PATH="$(dirname "$cargo_xwin"):$PATH" \
        CARGO_HOME="$cache_dir/cargo-home" \
        CARGO_TARGET_DIR="$target_dir" \
        XWIN_CACHE_DIR="$cache_dir/xwin" \
            cargo +1.90.0 xwin build --locked --release --target aarch64-pc-windows-msvc || exit 1
    ) || ucsi_die "cargo-xwin failed to build ucsi-smoke.exe"
    [ -s "$exe" ] || ucsi_die "cargo-xwin did not produce ucsi-smoke.exe"
    printf '%s\n' "$exe"
}

ucsi_build_acpi() {
    local cache_dir="$1" identity="$2" final stage input output
    final="$cache_dir/acpi/$identity"
    if [ -s "$final/ACPITABL.dat" ]; then
        printf '%s\n' "$final/ACPITABL.dat"
        return 0
    fi
    stage="${final}.tmp.$$.$RANDOM"
    ucsi_remove_owned_tree "$stage"
    mkdir -p "$stage"
    input="$(ucsi_host_to_container_path \
        "$UCSI_REPO_ROOT/mod/uefi/platform/QemuArmVirtPkg/AcpiTables/ec.asl" \
        "$UCSI_REPO_ROOT")"
    output="$(ucsi_host_to_container_path "$stage" "$UCSI_REPO_ROOT")"
    ucsi_dc bash -c '
set -e
input=$1
output=$2
iasl -tc -p "$output/ec" -I "$(dirname "$input")" "$input"
cp "$output/ec.aml" "$output/ACPITABL.dat"
' bash "$input" "$output" >&2
    [ -s "$stage/ACPITABL.dat" ] || ucsi_die "iasl did not produce ACPITABL.dat"
    ucsi_atomic_publish_directory "$stage" "$final" \
        || { ucsi_remove_owned_tree "$stage"; ucsi_die "could not publish ACPI cache"; }
    printf '%s\n' "$final/ACPITABL.dat"
}

ucsi_make_overlay() {
    local overlay="$1" base="$2" format="$3" relative
    mkdir -p "$(dirname "$overlay")"
    relative="$(ucsi_relative_backing_path "$overlay" "$base")"
    (
        cd "$(dirname "$overlay")"
        qemu-img create -q -f qcow2 -F "$format" -b "$relative" "$(basename "$overlay")"
    )
}

ucsi_write_shell_registry() {
    local file="$1" command="$2"
    cat > "$file" <<EOF
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon]
"Shell"="$command"
EOF
}

ucsi_set_winlogon_shell() {
    local image="$1" registry_file="$2"
    virt-win-reg --format qcow2 --merge "$image" < "$registry_file"
}

ucsi_inject_builder_payload() {
    local overlay="$1" extracted="$2" drivers="$3" acpi="$4" smoke="$5"
    guestfish -a "$overlay" -i \
        mkdir-p /ucsi-builder \
        : upload "$extracted/ValidationOS.wim" /ucsi-builder/ValidationOS.wim \
        : upload "$acpi" /ucsi-builder/ACPITABL.dat \
        : upload "$smoke" /ucsi-builder/ucsi-smoke.exe \
        : upload "$UCSI_REPO_ROOT/postbuild/os/build-ucsi-validationos.cmd" /ucsi-builder/build.cmd \
        : copy-in "$extracted/dism" /ucsi-builder \
        : copy-in "$drivers" /ucsi-builder
}

ucsi_qemu_pid_alive() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    ucsi_dc sh -c 'kill -0 "$1"' sh "$1"
}

ucsi_signal_qemu_pid() {
    local pid="$1" signal="$2"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    case "$signal" in
        TERM|KILL) ;;
        *) return 1 ;;
    esac
    ucsi_dc sh -c 'kill "-$1" "$2"' sh "$signal" "$pid"
}

ucsi_boot_qemu() {
    local image="$1" target="$2" log="$3" timeout_seconds="$4" run_dir="$5"
    local image_container target_container="" tpm_container pid_container status=0 qemu_pid
    image_container="$(ucsi_host_to_container_path "$image" "$UCSI_REPO_ROOT")"
    tpm_container="$(ucsi_host_to_container_path "$run_dir/swtpm/sock" "$UCSI_REPO_ROOT")"
    pid_container="$(ucsi_host_to_container_path "$run_dir/qemu.pid" "$UCSI_REPO_ROOT")"
    rm -f "$run_dir/qemu.pid"
    [ -z "$target" ] \
        || target_container="$(ucsi_host_to_container_path "$target" "$UCSI_REPO_ROOT")"
    local args=(
        -C "$UCSI_REPO_ROOT/mod/uefi" run
        "PATH_TO_OS=$image_container"
        "EC_I2C_SOCK="
        "EC_GPIO_SOCK="
        "QEMU_DISPLAY=none"
        "TPM_DEV=$tpm_container"
        "UCSI_QEMU_PID_FILE=$pid_container"
    )
    [ -z "$target_container" ] || args+=("UCSI_BUILDER_TARGET=$target_container")
    timeout --signal=TERM --kill-after=15 "$timeout_seconds" \
        make "${args[@]}" > "$log" 2>&1 || status=$?
    if [ -f "$run_dir/qemu.pid" ]; then
        qemu_pid="$(cat "$run_dir/qemu.pid")"
        if ucsi_qemu_pid_alive "$qemu_pid" 2>/dev/null; then
            ucsi_signal_qemu_pid "$qemu_pid" TERM 2>/dev/null || true
            timeout 15 "$UCSI_REPO_ROOT/scripts/dc-run.sh" -- \
                tail --pid="$qemu_pid" -f /dev/null >/dev/null 2>&1 || true
            if ucsi_qemu_pid_alive "$qemu_pid" 2>/dev/null; then
                ucsi_signal_qemu_pid "$qemu_pid" KILL 2>/dev/null || true
            fi
        fi
    fi
    printf '%s\n' "$status" > "$run_dir/qemu-status.txt"
}

ucsi_extract_builder_result() {
    local builder="$1" run_dir="$2"
    guestfish --ro -a "$builder" -i \
        download /ucsi-builder/build-result.txt "$run_dir/build-result.txt" \
        : download /ucsi-builder/build.log "$run_dir/build.log"
}

ucsi_validate_target_payload() {
    local target="$1"
    [ "$(guestfish --ro -a "$target" run : mount-ro /dev/sda1 / \
        : is-file /EFI/Boot/bootaa64.efi)" = true ] \
        && [ "$(guestfish --ro -a "$target" run : mount-ro /dev/sda1 / \
        : is-file /EFI/Microsoft/Boot/BCD)" = true ] \
        && [ "$(guestfish --ro -a "$target" run : mount-ro /dev/sda3 / \
        : is-file /Windows/System32/ACPITABL.dat)" = true ] \
        && [ "$(guestfish --ro -a "$target" run : mount-ro /dev/sda3 / \
        : is-file /ucsi-smoke/ucsi-smoke.exe)" = true ]
}

ucsi_publish_built_base() {
    local target="$1" final="$2" run_dir="$3"
    ucsi_validate_image "$target" qcow2 || return 1
    mkdir -p "$(dirname "$final")" || return 1
    mv -f -- "$target" "$final" || return 1
    ucsi_remove_owned_tree "$run_dir"
}

ucsi_build_local_base() {
    local cache_dir="$1" key="$2" extracted="$3" drivers="$4"
    local acpi="$5" smoke="$6" final="$7" timeout_seconds="$8"
    local run_dir target builder registry
    run_dir="$cache_dir/build-runs/$key-$(date +%Y%m%d-%H%M%S)-$$"
    target="$run_dir/target.qcow2"
    builder="$run_dir/builder.qcow2"
    registry="$run_dir/builder-shell.reg"
    mkdir -p "$run_dir"
    ucsi_log "builder artifacts: $run_dir"

    if ! ucsi_create_target_image "$target" 4G \
        || ! ucsi_make_overlay "$builder" "$extracted/ValidationOS.vhdx" vhdx \
        || ! ucsi_inject_builder_payload "$builder" "$extracted" "$drivers" "$acpi" "$smoke"; then
        ucsi_warn "local image preparation failed; artifacts preserved at $run_dir"
        return 1
    fi
    ucsi_write_shell_registry "$registry" 'cmd.exe /c C:\\ucsi-builder\\build.cmd'
    if ! ucsi_set_winlogon_shell "$builder" "$registry"; then
        ucsi_warn "builder Shell injection failed; artifacts preserved at $run_dir"
        return 1
    fi

    ucsi_log "booting ValidationOS builder headlessly"
    ucsi_boot_qemu "$builder" "$target" "$run_dir/builder-boot.log" \
        "$timeout_seconds" "$run_dir"
    if ! ucsi_extract_builder_result "$builder" "$run_dir" \
        || ! ucsi_check_builder_result "$run_dir/build-result.txt" \
        || ! ucsi_validate_target_payload "$target"; then
        ucsi_warn "Windows builder did not produce a valid target; artifacts preserved at $run_dir"
        return 1
    fi

    if ! ucsi_publish_built_base "$target" "$final" "$run_dir"; then
        ucsi_warn "could not publish validated builder target; artifacts preserved at $run_dir"
        return 1
    fi
}

ucsi_run_registry_path() {
    printf '%s/smoke-shell.reg\n' "$1"
}

ucsi_remove_e2e_result() {
    local image="$1"
    guestfish -a "$image" run : mount /dev/sda3 / \
        : rm-f /ucsi-e2e-result.txt
}

ucsi_prepare_run_overlay() {
    local base="$1" overlay="$2" run_dir="$3" registry
    registry="$(ucsi_run_registry_path "$run_dir")"
    ucsi_make_overlay "$overlay" "$base" qcow2
    guestfish -a "$overlay" run : ntfsfix /dev/sda3
    ucsi_remove_e2e_result "$overlay" || return 1
    ucsi_write_shell_registry "$registry" 'cmd.exe /c C:\\ucsi-smoke\\ucsi-smoke.exe'
    ucsi_set_winlogon_shell "$overlay" "$registry"
}

ucsi_extract_e2e_result() {
    local overlay="$1" output="$2"
    guestfish --ro -a "$overlay" run : mount-ro /dev/sda3 / \
        : download /ucsi-e2e-result.txt "$output"
}

ucsi_run_e2e() {
    local cache_dir="$1" base="$2" timeout_seconds="$3" keep="$4"
    local run_dir overlay result verified=0
    run_dir="$cache_dir/runs/$(date +%Y%m%d-%H%M%S)-$$"
    overlay="$run_dir/overlay.qcow2"
    result="$run_dir/ucsi-e2e-result.txt"
    mkdir -p "$run_dir"
    if ! ucsi_prepare_run_overlay "$base" "$overlay" "$run_dir"; then
        ucsi_warn "run image preparation failed; artifacts preserved at $run_dir"
        return 1
    fi
    ucsi_log "booting UCSI smoke headlessly"
    ucsi_boot_qemu "$overlay" "" "$run_dir/boot.log" "$timeout_seconds" "$run_dir"
    if ucsi_extract_e2e_result "$overlay" "$result" \
        && ucsi_verify_e2e_result "$result" "$run_dir/boot.log"; then
        verified=1
    fi
    if [ "$verified" = 0 ]; then
        ucsi_warn "E2E verification failed; artifacts preserved at $run_dir"
        return 1
    fi
    if ucsi_should_delete_run_dir "$verified" "$keep"; then
        rm -rf "$run_dir"
    else
        ucsi_log "successful run image preserved at $run_dir"
    fi
    printf '%s\n' "$UCSI_PASS_LINE"
}

ucsi_collect_input_files() {
    local file
    printf '%s\n' \
        "$UCSI_REPO_ROOT/scripts/run-ucsi-windows-e2e.sh" \
        "$UCSI_REPO_ROOT/scripts/qemu-ec-wrapper.sh" \
        "$UCSI_REPO_ROOT/mod/uefi/Makefile" \
        "$UCSI_REPO_ROOT/postbuild/os/build-ucsi-validationos.cmd" \
        "$UCSI_REPO_ROOT/postbuild/os/ucsi-driverlist.txt" \
        "$UCSI_REPO_ROOT/postbuild/os/ucsi-smoke/Cargo.toml" \
        "$UCSI_REPO_ROOT/postbuild/os/ucsi-smoke/Cargo.lock" \
        "$UCSI_REPO_ROOT/postbuild/os/ucsi-smoke/rust-toolchain.toml" \
        "$UCSI_REPO_ROOT/postbuild/os/ucsi-smoke/src/main.rs"
    while IFS= read -r file; do
        printf '%s\n' "$file"
    done < <(find "$UCSI_REPO_ROOT/mod/uefi/platform/QemuArmVirtPkg/AcpiTables" \
        -type f \( -name '*.asl' -o -name '*.asi' -o -name '*.inc' \) | sort)
}

ucsi_main() {
    local validation_os_url="" validation_os_iso="" image_path="" os_build=""
    local cache_dir="" drivers_repo="OpenDevicePartnership/odp-windows-drivers"
    local drivers_release="latest"
    local force_image=0 force_firmware=0 boot_timeout=900 keep_run_image=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --validation-os-url) [ "$#" -ge 2 ] || ucsi_die "$1 requires a value"; validation_os_url="$2"; shift 2 ;;
            --validation-os-iso) [ "$#" -ge 2 ] || ucsi_die "$1 requires a value"; validation_os_iso="$2"; shift 2 ;;
            --image) [ "$#" -ge 2 ] || ucsi_die "$1 requires a value"; image_path="$2"; shift 2 ;;
            --validation-os-build) [ "$#" -ge 2 ] || ucsi_die "$1 requires a value"; os_build="$2"; shift 2 ;;
            --cache-dir) [ "$#" -ge 2 ] || ucsi_die "$1 requires a value"; cache_dir="$2"; shift 2 ;;
            --drivers-repo) [ "$#" -ge 2 ] || ucsi_die "$1 requires a value"; drivers_repo="$2"; shift 2 ;;
            --drivers-release) [ "$#" -ge 2 ] || ucsi_die "$1 requires a value"; drivers_release="$2"; shift 2 ;;
            --force-image) force_image=1; shift ;;
            --force-firmware) force_firmware=1; shift ;;
            --boot-timeout) [ "$#" -ge 2 ] || ucsi_die "$1 requires a value"; boot_timeout="$2"; shift 2 ;;
            --keep-run-image) keep_run_image=1; shift ;;
            -h|--help) ucsi_usage; return 0 ;;
            *) ucsi_usage >&2; ucsi_die "unknown argument: $1" ;;
        esac
    done

    ucsi_validate_sources "$validation_os_url" "$validation_os_iso" "$image_path" \
        || ucsi_die "specify exactly one of --validation-os-url, --validation-os-iso, or --image"
    ucsi_validate_os_build "$os_build" \
        || ucsi_die "--validation-os-build must be an integer >= $UCSI_MIN_BUILD; build 26100 lacks ACPI FF-A"
    case "$boot_timeout" in
        ''|*[!0-9]*|0) ucsi_die "--boot-timeout must be a positive integer" ;;
    esac
    ucsi_validate_repo_name "$drivers_repo" || ucsi_die "invalid --drivers-repo"
    ucsi_validate_safe_token "$drivers_release" || ucsi_die "invalid --drivers-release"

    UCSI_REPO_ROOT="$(realpath -e -- "$(ucsi_repo_root)")"
    [ -n "$cache_dir" ] \
        || cache_dir="$UCSI_REPO_ROOT/postbuild/os/build/ucsi-windows-e2e-cache"
    cache_dir="$(realpath -m -- "$cache_dir")"
    ucsi_path_within_repo "$cache_dir" "$UCSI_REPO_ROOT" \
        || ucsi_die "--cache-dir must be inside $UCSI_REPO_ROOT"
    mkdir -p "$cache_dir"
    ucsi_cache_tree_safe "$cache_dir" "$UCSI_REPO_ROOT" \
        || ucsi_die "--cache-dir must not contain symlinks"

    ucsi_require_tools
    ucsi_prepare_guestfish "$cache_dir"
    ucsi_ensure_devcontainer

    local firmware_identity
    firmware_identity="$(ucsi_firmware_identity "$UCSI_REPO_ROOT")"
    ucsi_ensure_firmware "$cache_dir" "$firmware_identity" "$force_firmware"

    local input_files=() input_hash source_identity driver_identity key base
    mapfile -t input_files < <(ucsi_collect_input_files)
    input_hash="$(ucsi_hash_inputs "${input_files[@]}")"

    if [ -n "$image_path" ]; then
        image_path="$(realpath -e -- "$image_path")" \
            || ucsi_die "prepared image not found"
        ucsi_validate_supplied_image "$image_path" \
            || ucsi_die "--image must be a flat, valid VHDX or QCOW2"
        source_identity="image:$(ucsi_file_identity "$image_path")"
        driver_identity="prepared-image"
        key="$(ucsi_compute_image_cache_key "$source_identity" "$os_build" \
            "$driver_identity" "$input_hash" "$firmware_identity")"
        base="$cache_dir/images/$key.qcow2"
        if [ "$force_image" = 1 ] || ! ucsi_validate_image "$base" qcow2; then
            case "$image_path" in
                *.qcow2) ucsi_atomic_convert qcow2 "$image_path" "$base" ;;
                *.vhdx) ucsi_atomic_convert vhdx "$image_path" "$base" ;;
            esac
        fi
    else
        local iso iso_identity extracted manifest drivers cargo_xwin smoke acpi
        iso="$(ucsi_resolve_iso "$cache_dir" "$validation_os_url" \
            "$validation_os_iso" "$os_build" "$force_image")"
        iso_identity="$(ucsi_file_identity "$iso")" \
            || ucsi_die "ValidationOS ISO is empty or unreadable"
        extracted="$(ucsi_extract_validation_os "$cache_dir" "$iso" "$iso_identity")"
        manifest="$(ucsi_resolve_driver_assets "$drivers_repo" "$drivers_release" \
            "$UCSI_REPO_ROOT/postbuild/os/ucsi-driverlist.txt")"
        driver_identity="$(ucsi_driver_asset_identity "$manifest")"
        drivers="$(ucsi_prepare_drivers "$cache_dir" "$drivers_repo" "$manifest")"
        cargo_xwin="$(ucsi_ensure_cargo_xwin "$cache_dir")"
        smoke="$(ucsi_build_smoke "$cache_dir" "$cargo_xwin")"
        acpi="$(ucsi_build_acpi "$cache_dir" "$input_hash")"
        source_identity="iso:$iso_identity"
        key="$(ucsi_compute_image_cache_key "$source_identity" "$os_build" \
            "$driver_identity" "$input_hash" "$firmware_identity")"
        base="$cache_dir/images/$key.qcow2"
        if [ "$force_image" = 1 ] || ! ucsi_validate_image "$base" qcow2; then
            ucsi_build_local_base "$cache_dir" "$key" "$extracted" "$drivers" \
                "$acpi" "$smoke" "$base" "$boot_timeout" \
                || ucsi_die "local Windows image builder failed"
        fi
    fi

    ucsi_log "pristine base: $base"
    ucsi_run_e2e "$cache_dir" "$base" "$boot_timeout" "$keep_run_image" \
        || ucsi_die "Windows UCSI ACPI/FF-A E2E failed"
}

if [ -n "${UCSI_WINDOWS_E2E_SOURCE_ONLY:-}" ]; then
    return 0 2>/dev/null || true
else
    ucsi_main "$@"
fi
