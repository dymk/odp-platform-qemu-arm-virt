#!/usr/bin/env bash
# Cached Windows UCSI ACPI -> FF-A end-to-end runner.
#
# SPDX-License-Identifier: MIT
#
# Boots a Windows ValidationOS image under the QEMU `virt` platform and drives
# the full Windows UCSI path end to end:
#
#   ucsi-smoke.exe -> ectest.sys -> ECT0.USND -> FFixedHw/FFAC
#     -> Windows FF-A -> secure UCSI SP
#
# The image is produced by the build_os_image GitHub Actions workflow (which
# injects the ectest driver + smoke app), cached by a deterministic key, and
# booted through a disposable qcow2 overlay so the pristine base is never
# mutated. Success requires the guest to write the exact line
# "PASS: UCSI ACPI/FF-A E2E" and the boot log to show the secure UCSI UUID,
# proving secure world was reached.
#
# The public ARM64 ValidationOS (build 26100.x) lacks ExGetFfaInterface / ACPI
# FF-A support, so this path only works with an explicitly declared build
# >= 28000. There is no dry-run / fake-success mode.
#
# Sourcing note: setting UCSI_WINDOWS_E2E_SOURCE_ONLY=1 loads the pure helper
# functions without running main (used by the unit tests).

if [ -z "${UCSI_WINDOWS_E2E_SOURCE_ONLY:-}" ]; then
    set -euo pipefail
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
UCSI_MIN_BUILD=28000
UCSI_PASS_LINE='PASS: UCSI ACPI/FF-A E2E'
UCSI_SECURE_UUID='65467f50-827f-4e4f-8770-dbf4c3f77f45'
UCSI_GUEST_RESULT_PATH='/ucsi-e2e-result.txt'
UCSI_WORKFLOW_FILE='.github/workflows/build-os.yml'
UCSI_WORKFLOW_ID='build-os.yml'

# QEMU-side ports the `make -C mod/uefi run` path binds (Common.mk / uefi
# Makefile): VNC :0 -> 5900, GDB 5555, serial 56789.
UCSI_VNC_HOST='127.0.0.1'
UCSI_VNC_DISPLAY='0'
UCSI_VNC_PORT=5900
UCSI_GDB_PORT=5555
UCSI_SERIAL_PORT=56789

# ===========================================================================
# Pure helper functions (unit-tested; no external side effects)
# ===========================================================================

# ucsi_validate_os_build BUILD
# Succeeds only when BUILD is a plain positive integer >= UCSI_MIN_BUILD.
ucsi_validate_os_build() {
    local build="${1-}"
    case "$build" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$build" -ge "$UCSI_MIN_BUILD" ]
}

# ucsi_compute_cache_key SOURCE_ID OS_BUILD DRIVERS_REPO DRIVERS_RELEASE \
#                        DRIVER_ASSET_IDENTITY WORKFLOW_REPO WORKFLOW_REF \
#                        WORKFLOW_SHA WORKFLOW_HASH
# Deterministic hex digest over every input that must invalidate a cached
# image. Each argument occupies its own line so field order and boundaries are
# unambiguous; any change to any field changes the digest.
ucsi_compute_cache_key() {
    [ "$#" -eq 9 ] || return 2
    printf '%s\n' "$@" | sha256sum | awk '{print $1}'
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
    if isinstance(name, str):
        if name in by_name:
            sys.exit(1)
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
    if not isinstance(asset_id, int) or asset_id <= 0:
        sys.exit(1)
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
        sys.exit(1)
    manifest.append({
        "name": name,
        "id": asset_id,
        "digest": digest.lower(),
    })

print(json.dumps(manifest, separators=(",", ":")))
' "$@" <<< "$release_json"
}

ucsi_driver_asset_identity() {
    local manifest="${1-}"
    [ -n "$manifest" ] || return 1
    printf 'driver-assets:%s\n' "$(printf '%s' "$manifest" | sha256sum | awk '{print $1}')"
}

ucsi_driver_release_endpoint() {
    local repo="$1" release="$2"
    printf 'repos/%s/releases/tags/%s\n' "$repo" "$release"
}

ucsi_validate_image() {
    local image="$1" expected_format="$2" info
    [ -f "$image" ] || return 1
    info="$(qemu-img info --output=json "$image" 2>/dev/null)" || return 1
    python3 -c '
import json
import sys

try:
    info = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
sys.exit(0 if info.get("format") == sys.argv[1] else 1)
' "$expected_format" <<< "$info" || return 1
    if [ "$expected_format" = qcow2 ]; then
        qemu-img check -q "$image" >/dev/null 2>&1 || return 1
    fi
}

ucsi_atomic_convert() {
    local source_format="$1" source="$2" final="$3"
    local temporary="${final}.tmp.$$.$RANDOM"
    (
        set -e
        trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
        qemu-img convert -f "$source_format" -O qcow2 "$source" "$temporary"
        ucsi_validate_image "$temporary" qcow2
        mv -f -- "$temporary" "$final"
        trap - EXIT HUP INT TERM
    )
}

# ucsi_select_cached_image CACHE_DIR KEY
# Prints the best cached base image for KEY, preferring a ready-to-boot QCOW2
# over a VHDX that would still need converting. Returns non-zero when neither
# exists.
ucsi_select_cached_image() {
    local cache_dir="$1" key="$2"
    if [ -f "$cache_dir/$key.qcow2" ]; then
        if ucsi_validate_image "$cache_dir/$key.qcow2" qcow2; then
            printf '%s\n' "$cache_dir/$key.qcow2"
            return 0
        fi
        rm -f -- "$cache_dir/$key.qcow2"
    fi
    if [ -f "$cache_dir/$key.vhdx" ]; then
        if ucsi_validate_image "$cache_dir/$key.vhdx" vhdx; then
            printf '%s\n' "$cache_dir/$key.vhdx"
            return 0
        fi
        rm -f -- "$cache_dir/$key.vhdx"
    fi
    return 1
}

# ucsi_check_result_file FILE
# Succeeds only when FILE exists and contains the exact success line on a line
# of its own (CR tolerated). Trailing junk, wrong case, FAIL, empty, or a
# missing file all fail.
ucsi_check_result_file() {
    local file="$1"
    [ -f "$file" ] || return 1
    tr -d '\r' < "$file" | grep -qxF "$UCSI_PASS_LINE"
}

# ucsi_parse_run_id TEXT
# Extracts the numeric Actions run ID from a `.../actions/runs/<id>` URL found
# anywhere in TEXT. Returns non-zero when no such URL is present.
ucsi_parse_run_id() {
    local text="${1-}" id
    id="$(printf '%s' "$text" | grep -oE 'actions/runs/[0-9]+' | head -n1 | grep -oE '[0-9]+$' || true)"
    [ -n "$id" ] || return 1
    printf '%s\n' "$id"
}

ucsi_dispatch_run_title() {
    printf 'build_os_image [%s]\n' "$1"
}

ucsi_select_nonce_run_id() {
    local json="${1-}" nonce="${2-}" expected_sha="${3-}"
    [ -n "$json" ] && [ -n "$nonce" ] && [ -n "$expected_sha" ] || return 1
    python3 -c '
import json
import sys

expected = "build_os_image [%s]" % sys.argv[1]
expected_sha = sys.argv[2]
try:
    runs = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError):
    sys.exit(1)

if isinstance(runs, dict):
    runs = [runs]
for run in runs:
    if (
        run.get("event") == "workflow_dispatch"
        and run.get("displayTitle") == expected
        and run.get("headSha") == expected_sha
    ):
        run_id = run.get("databaseId")
        if isinstance(run_id, int):
            print(run_id)
            sys.exit(0)
sys.exit(1)
' "$nonce" "$expected_sha" <<< "$json"
}

ucsi_validate_repo_name() {
    local value="${1-}"
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

ucsi_validate_safe_token() {
    local value="${1-}"
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

ucsi_compose_firmware_stamp() {
    [ "$#" -eq 3 ] || return 2
    printf 'armvirt=%s secure-services=%s patina-qemu=%s\n' "$1" "$2" "$3"
}

ucsi_can_reuse_firmware() {
    local force="$1" dirty="$2" artifacts_ready="$3" stamp_matches="$4"
    [ "$force" = "0" ] && [ "$dirty" = "0" ] \
        && [ "$artifacts_ready" = "1" ] && [ "$stamp_matches" = "1" ]
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

ucsi_should_delete_overlay() {
    local verified_success="$1" keep_requested="$2"
    [ "$verified_success" = "1" ] && [ "$keep_requested" = "0" ]
}

ucsi_guestfish_command_for_euid() {
    if [ "$1" = "0" ]; then
        printf 'guestfish\n'
    else
        printf 'sudo -n guestfish\n'
    fi
}

# ucsi_relative_backing_path OVERLAY_PATH BASE_PATH
# Backing-file path for OVERLAY expressed relative to OVERLAY's directory, so
# the overlay never bakes in an absolute host-only cache path and stays valid
# if the tree is relocated.
ucsi_relative_backing_path() {
    local overlay="$1" base="$2"
    realpath -m --relative-to="$(dirname "$overlay")" "$base"
}

# ===========================================================================
# Orchestration (only runs when executed, not when sourced)
# ===========================================================================

ucsi_log()  { printf '[ucsi-e2e] %s\n' "$*" >&2; }
ucsi_die()  { printf '[ucsi-e2e] ERROR: %s\n' "$*" >&2; exit 1; }
ucsi_warn() { printf '[ucsi-e2e] WARN: %s\n' "$*" >&2; }

ucsi_usage() {
    cat <<'EOF'
Usage: run-ucsi-windows-e2e.sh (--validation-os-url URL | --image PATH) \
                               --validation-os-build BUILD [options]

Source (exactly one required):
  --validation-os-url URL       ValidationOS ISO the workflow downloads/builds.
  --image PATH                  Pre-built VHDX/QCOW2 to import into the cache.
  --validation-os-build BUILD   Declared OS build; integer >= 28000 (26100 is
                                refused: it lacks ACPI FF-A support).

Options:
  --cache-dir DIR               Default: <repo>/postbuild/os/build/ucsi-windows-e2e-cache
  --drivers-repo OWNER/REPO     Default: OpenDevicePartnership/odp-windows-drivers
  --drivers-release TAG         Driver release tag. Default: latest
  --workflow-repo OWNER/REPO    Default: inferred from the 'dymk' remote,
                                else dymk/odp-platform-qemu-arm-virt
  --workflow-ref REF            Default: current branch
  --force-image                 Ignore any cached base image; rebuild it.
  --force-firmware              Rebuild UEFI/secure firmware even if cached.
  --boot-timeout SECONDS        Default: 900
  --keep-run-image              Keep the disposable overlay after the run.
  --help                        Show this help.

Requires: gh (authenticated), git, qemu-img, guestfish, devcontainer, timeout.
Non-root users also require passwordless `sudo -n guestfish`.
Runs no dry-run/fake-success mode; a real >= 28000 image is required to pass.
EOF
}

# ---- repo geometry ----
ucsi_repo_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dirname "$script_dir"
}

# Translate a host path under the repo root to its /workspaces/<repo> path
# inside the devcontainer (mirrors Common.mk's REPO_ROOT_IN_DEVCONTAINER).
ucsi_host_to_container_path() {
    local host_path="$1" repo_root="$2" repo_base container_root
    repo_base="$(basename "$repo_root")"
    container_root="/workspaces/$repo_base"
    printf '%s\n' "${host_path/#$repo_root/$container_root}"
}

# ---- source identity for the cache key ----
# For --image, identity is content-derived so distinct images never collide and
# an unchanged image reuses its cache. For a URL, the URL string is identity.
ucsi_image_identity() {
    local path="$1"
    printf 'image:%s\n' "$(sha256sum "$path" | awk '{print $1}')"
}

# ---- tooling / ports ----
ucsi_require_tools() {
    local missing=()
    local t
    for t in gh git qemu-img devcontainer timeout sha256sum realpath python3 tail; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        ucsi_die "missing required tools: ${missing[*]}"
    fi
    if ! gh auth status >/dev/null 2>&1; then
        ucsi_die "GitHub CLI is not authenticated. Run 'gh auth login' and retry."
    fi
}

ucsi_dc() { "$UCSI_REPO_ROOT/scripts/dc-run.sh" -- "$@"; }

ucsi_ensure_devcontainer() {
    make -C "$UCSI_REPO_ROOT" builder-image
}

ucsi_require_devcontainer_tools() {
    if ! ucsi_dc sh -c 'command -v vncdo >/dev/null 2>&1'; then
        ucsi_die "vncdo is missing inside the devcontainer; rebuild it after installing vncdotool==1.3.0"
    fi
    if ! ucsi_dc python3 -c 'from PIL import Image' >/dev/null 2>&1; then
        ucsi_die "Pillow is missing inside the devcontainer; rebuild it after installing Pillow==12.3.0"
    fi
}

ucsi_select_guestfish() {
    local command
    command="$(ucsi_guestfish_command_for_euid "$EUID")"
    if [ "$command" = "guestfish" ]; then
        command -v guestfish >/dev/null 2>&1 \
            || ucsi_die "guestfish is required for result extraction"
        guestfish --version >/dev/null 2>&1 \
            || ucsi_die "guestfish is installed but unusable"
        UCSI_GUESTFISH_CMD=(guestfish)
        return
    fi

    command -v sudo >/dev/null 2>&1 \
        || ucsi_die "result extraction requires passwordless sudo: install sudo and allow 'sudo -n guestfish'"
    if ! sudo -n guestfish --version >/dev/null 2>&1; then
        ucsi_die "result extraction requires passwordless 'sudo -n guestfish'; configure it before starting the run"
    fi
    UCSI_GUESTFISH_CMD=(sudo -n guestfish)
}

# ucsi_port_free PORT -> 0 if nothing is listening inside the devcontainer.
ucsi_port_free() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ! ucsi_dc timeout 1 bash -c ': > /dev/tcp/127.0.0.1/"$1"' bash "$port" 2>/dev/null
}

ucsi_require_ports_free() {
    local p occupied=()
    for p in "$UCSI_VNC_PORT" "$UCSI_GDB_PORT" "$UCSI_SERIAL_PORT"; do
        ucsi_port_free "$p" || occupied+=("$p")
    done
    if [ "${#occupied[@]}" -gt 0 ]; then
        ucsi_die "ports already in use: ${occupied[*]} (another QEMU/VNC instance?). \
Refusing to launch; stop it yourself (this runner never kills unrelated processes)."
    fi
}

# ---- firmware build with a SHA-keyed stamp ----
ucsi_firmware_stamp_value() {
    local repo_root="$1" armvirt_head ss_sha patina_sha
    armvirt_head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
    ss_sha="$(git -C "$repo_root/mod/secure-services/odp-secure-services" rev-parse HEAD 2>/dev/null \
        || echo unknown)"
    patina_sha="$(git -C "$repo_root/mod/uefi/patina-qemu" rev-parse HEAD 2>/dev/null \
        || echo unknown)"
    ucsi_compose_firmware_stamp "$armvirt_head" "$ss_sha" "$patina_sha"
}

ucsi_firmware_inputs_dirty() {
    local repo_root="$1" status
    if ! status="$(git -C "$repo_root" status --porcelain --untracked-files=all -- \
        .gitmodules \
        mod/secure-services/odp-secure-services \
        mod/secure-services/platform \
        mod/uefi/patina-qemu \
        mod/uefi/platform)"; then
        return 0
    fi
    if [ -n "$status" ]; then
        return 0
    fi
    if ! status="$(git -C "$repo_root/mod/secure-services/odp-secure-services" \
        status --porcelain --untracked-files=all)"; then
        return 0
    fi
    if [ -n "$status" ]; then
        return 0
    fi
    if ! status="$(git -C "$repo_root/mod/uefi/patina-qemu" \
        status --porcelain --untracked-files=all)"; then
        return 0
    fi
    [ -n "$status" ]
}

ucsi_ensure_firmware() {
    local repo_root="$1" force="$2"
    local fv_dir="$repo_root/mod/uefi/patina-qemu/Build/QemuArmVirtPkg/DEBUG_CLANGPDB/FV"
    local flash0="$fv_dir/SECURE_FLASH0.fd" efi="$fv_dir/QEMU_EFI.fd"
    local stamp="$repo_root/postbuild/os/build/ucsi-windows-e2e-cache/firmware.stamp"
    local want dirty=0 artifacts_ready=0 stamp_matches=0
    want="$(ucsi_firmware_stamp_value "$repo_root")"
    ucsi_firmware_inputs_dirty "$repo_root" && dirty=1
    if [ -f "$flash0" ] && [ -f "$efi" ]; then
        artifacts_ready=1
    fi
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
        stamp_matches=1
    fi

    if ucsi_can_reuse_firmware "$force" "$dirty" "$artifacts_ready" "$stamp_matches"; then
        ucsi_log "firmware cache hit ($want)"
        return 0
    fi

    ucsi_log "building firmware (make -C mod uefi)"
    make -C "$repo_root/mod" uefi
    [ -f "$flash0" ] || ucsi_die "firmware build did not produce $flash0"
    [ -f "$efi" ] || ucsi_die "firmware build did not produce $efi"
    if ucsi_firmware_inputs_dirty "$repo_root"; then
        ucsi_log "firmware inputs are dirty; cache stamp not written"
    else
        want="$(ucsi_firmware_stamp_value "$repo_root")"
        mkdir -p "$(dirname "$stamp")"
        printf '%s\n' "$want" > "$stamp"
        ucsi_log "firmware built and stamped ($want)"
    fi
}

# ---- workflow dispatch + artifact download ----
ucsi_resolve_workflow_sha() {
    local repo="$1" ref="$2" sha
    sha="$(gh api "repos/$repo/commits/$ref" --jq .sha 2>/dev/null || true)"
    [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || sha=""
    [ -n "$sha" ] || ucsi_die "could not resolve immutable commit for $repo@$ref"
    printf '%s\n' "$sha"
}

ucsi_resolve_driver_assets() {
    local repo="$1" release="$2" driver_list="$3"
    local endpoint release_json
    endpoint="$(ucsi_driver_release_endpoint "$repo" "$release")"
    release_json="$(gh api "$endpoint" 2>/dev/null)" \
        || ucsi_die "could not resolve driver release $repo@$release"

    local required=()
    mapfile -t required < <(
        sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$driver_list"
    )
    [ "${#required[@]}" -gt 0 ] || ucsi_die "no required drivers listed in $driver_list"
    ucsi_resolve_driver_asset_manifest "$release_json" "${required[@]}" \
        || ucsi_die "driver release $repo@$release is missing a required asset, ID, or SHA-256 digest"
}

# Dispatches build_os_image and prints the resolved numeric run ID.
ucsi_dispatch_workflow() {
    local repo="$1" ref="$2" vos_url="$3" drivers_repo="$4" drivers_release="$5"
    local driver_manifest="$6" nonce="$7" expected_sha="$8"
    local out run_id="" matched_id
    ucsi_log "dispatching $UCSI_WORKFLOW_ID on $repo@$ref"
    out="$(gh workflow run "$UCSI_WORKFLOW_ID" --repo "$repo" --ref "$ref" \
        -f "validation_os_url=$vos_url" \
        -f "drivers_repo=$drivers_repo" \
        -f "drivers_release=$drivers_release" \
        -f "driver_asset_manifest=$driver_manifest" \
        -f "dispatch_nonce=$nonce" 2>&1)" || ucsi_die "gh workflow run failed: $out"

    run_id="$(ucsi_parse_run_id "$out" || true)"

    local attempt runs_json
    for attempt in {1..10}; do
        if [ -n "$run_id" ]; then
            runs_json="$(gh run view "$run_id" --repo "$repo" \
                --json databaseId,event,displayTitle,headSha 2>/dev/null || true)"
        else
            runs_json="$(gh run list --repo "$repo" --workflow "$UCSI_WORKFLOW_ID" \
                --limit 50 --json databaseId,event,displayTitle,headSha 2>/dev/null || true)"
        fi
        if matched_id="$(ucsi_select_nonce_run_id "$runs_json" "$nonce" "$expected_sha")"; then
            printf '%s\n' "$matched_id"
            return 0
        fi
        if [ "$attempt" -lt 10 ]; then
            read -r -t 2 _ < <(timeout 3 tail -f /dev/null) || true
        fi
    done
    ucsi_die "could not resolve workflow_dispatch run with title '$(ucsi_dispatch_run_title "$nonce")'"
}

ucsi_download_artifact_vhdx() {
    local repo="$1" run_id="$2" dest_dir="$3"
    ucsi_log "watching run $run_id"
    gh run watch "$run_id" --repo "$repo" --exit-status \
        || ucsi_die "workflow run $run_id failed"
    mkdir -p "$dest_dir"
    GH_FORCE_TTY=0 gh run download "$run_id" --repo "$repo" --name os-image --dir "$dest_dir" \
        || ucsi_die "failed to download os-image artifact from run $run_id"
    local vhdx
    vhdx="$(find "$dest_dir" -name '*.vhdx' -type f | head -n1)"
    [ -n "$vhdx" ] || ucsi_die "no VHDX in downloaded os-image artifact"
    printf '%s\n' "$vhdx"
}

# ---- base image resolution -> prints path to a pristine base QCOW2 ----
ucsi_resolve_base_image() {
    local cache_dir="$1" key="$2" force="$3" image_path="$4"
    local vos_url="$5" workflow_repo="$6" workflow_ref="$7"
    local drivers_repo="$8" drivers_release="$9" driver_manifest="${10}" nonce="${11}"
    local workflow_sha="${12}"
    local base_qcow2="$cache_dir/$key.qcow2"
    mkdir -p "$cache_dir"

    if [ "$force" != "1" ]; then
        local cached
        if cached="$(ucsi_select_cached_image "$cache_dir" "$key")"; then
            case "$cached" in
                *.qcow2)
                    ucsi_log "image cache hit (qcow2): $cached"
                    printf '%s\n' "$cached"; return 0 ;;
                *.vhdx)
                    ucsi_log "image cache hit (vhdx); converting to base qcow2"
                    ucsi_atomic_convert vhdx "$cached" "$base_qcow2"
                    printf '%s\n' "$base_qcow2"; return 0 ;;
            esac
        fi
    fi

    if [ -n "$image_path" ]; then
        ucsi_log "importing supplied image into cache: $image_path"
        case "$image_path" in
            *.qcow2) ucsi_atomic_convert qcow2 "$image_path" "$base_qcow2" ;;
            *.vhdx)  ucsi_atomic_convert vhdx  "$image_path" "$base_qcow2" ;;
            *) ucsi_die "unsupported --image type: $image_path (expected .qcow2 or .vhdx)" ;;
        esac
        printf '%s\n' "$base_qcow2"; return 0
    fi

    local run_id vhdx
    run_id="$(ucsi_dispatch_workflow "$workflow_repo" "$workflow_ref" "$vos_url" \
        "$drivers_repo" "$drivers_release" "$driver_manifest" "$nonce" "$workflow_sha")"
    vhdx="$(ucsi_download_artifact_vhdx "$workflow_repo" "$run_id" "$cache_dir/artifact-$run_id")"
    ucsi_log "converting downloaded VHDX to base qcow2"
    ucsi_atomic_convert vhdx "$vhdx" "$base_qcow2"
    printf '%s\n' "$base_qcow2"
}

# ---- VNC automation (runs vncdo/Pillow inside the devcontainer) ----
ucsi_vncdo() {
    ucsi_dc vncdo -s "${UCSI_VNC_HOST}:${UCSI_VNC_DISPLAY}" "$@"
}

# Write the prompt-detection analyzer once; it runs inside the container.
ucsi_write_prompt_analyzer() {
    local path="$1"
    cat > "$path" <<'PY'
# Detects the ValidationOS Administrator cmd prompt in a VNC screenshot.
# Heuristic (per the proven runner): a real prompt shows a substantial band of
# neutral/white title-bar pixels near the top AND substantial green
# command-prompt text elsewhere. A blank/boot framebuffer fails both.
import sys
from PIL import Image

img = Image.open(sys.argv[1]).convert("RGB")
w, h = img.size
px = img.load()

title_band = max(1, int(h * 0.06))
neutral = 0
for y in range(title_band):
    for x in range(0, w, 3):
        r, g, b = px[x, y]
        if r > 180 and g > 180 and b > 180 and max(r, g, b) - min(r, g, b) < 40:
            neutral += 1
neutral_frac = neutral / max(1, (w // 3) * title_band)

green = 0
for y in range(title_band, h, 3):
    for x in range(0, w, 3):
        r, g, b = px[x, y]
        if g > 110 and g - r > 40 and g - b > 40:
            green += 1
green_frac = green / max(1, (w // 3) * ((h - title_band) // 3))

ok = neutral_frac > 0.15 and green_frac > 0.004
sys.stderr.write("neutral_frac=%.3f green_frac=%.4f ok=%s\n" % (neutral_frac, green_frac, ok))
sys.exit(0 if ok else 1)
PY
}

# Poll the framebuffer until the Administrator prompt appears (or timeout).
ucsi_wait_for_prompt() {
    local run_dir="$1" deadline="$2"
    local analyzer="$run_dir/ucsi-detect-prompt.py"
    local shot_host="$run_dir/prompt.png"
    local shot_rel; shot_rel="$(ucsi_host_to_container_path "$shot_host" "$UCSI_REPO_ROOT")"
    local analyzer_rel; analyzer_rel="$(ucsi_host_to_container_path "$analyzer" "$UCSI_REPO_ROOT")"
    ucsi_write_prompt_analyzer "$analyzer"

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ucsi_vncdo capture "$shot_rel" 2>/dev/null; then
            if ucsi_dc python3 "$analyzer_rel" "$shot_rel"; then
                ucsi_log "Administrator prompt detected"
                return 0
            fi
        fi
        ucsi_vncdo pause 5 >/dev/null 2>&1 || true
    done
    return 1
}

ucsi_type_smoke_command() {
    # Type the guest command and press Enter. vncdo `type` sends the literal
    # string; `key enter` submits it.
    ucsi_vncdo type '\ucsi-smoke\ucsi-smoke.exe'
    ucsi_vncdo key enter
}

# ---- guest result extraction ----
ucsi_extract_guest_result() {
    local overlay="$1" out_file="$2"
    # NTFS is the last partition; guestfish's inspection finds the Windows root.
    "${UCSI_GUESTFISH_CMD[@]}" --ro -a "$overlay" -i \
        download "$UCSI_GUEST_RESULT_PATH" "$out_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
ucsi_main() {
    local validation_os_url="" image_path="" os_build=""
    local cache_dir="" drivers_repo="OpenDevicePartnership/odp-windows-drivers"
    local drivers_release="latest"
    local workflow_repo="" workflow_ref=""
    local force_image=0 force_firmware=0 boot_timeout=900 keep_run_image=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --validation-os-url) validation_os_url="$2"; shift 2 ;;
            --image) image_path="$2"; shift 2 ;;
            --validation-os-build) os_build="$2"; shift 2 ;;
            --cache-dir) cache_dir="$2"; shift 2 ;;
            --drivers-repo) drivers_repo="$2"; shift 2 ;;
            --drivers-release) drivers_release="$2"; shift 2 ;;
            --workflow-repo) workflow_repo="$2"; shift 2 ;;
            --workflow-ref) workflow_ref="$2"; shift 2 ;;
            --force-image) force_image=1; shift ;;
            --force-firmware) force_firmware=1; shift ;;
            --boot-timeout) boot_timeout="$2"; shift 2 ;;
            --keep-run-image) keep_run_image=1; shift ;;
            -h|--help) ucsi_usage; return 0 ;;
            *) ucsi_usage >&2; ucsi_die "unknown argument: $1" ;;
        esac
    done

    UCSI_REPO_ROOT="$(realpath -e -- "$(ucsi_repo_root)")"

    # ---- source declaration & build gate ----
    if [ -n "$validation_os_url" ] && [ -n "$image_path" ]; then
        ucsi_die "specify only one of --validation-os-url or --image"
    fi
    if [ -z "$validation_os_url" ] && [ -z "$image_path" ]; then
        ucsi_usage >&2; ucsi_die "one of --validation-os-url or --image is required"
    fi
    if [ -z "$os_build" ]; then
        ucsi_die "--validation-os-build is required"
    fi
    if ! ucsi_validate_os_build "$os_build"; then
        ucsi_die "--validation-os-build must be an integer >= $UCSI_MIN_BUILD (got '$os_build'); \
build 26100 lacks ACPI FF-A support and cannot pass, even with a custom --image."
    fi
    if [ -n "$image_path" ] && [ ! -f "$image_path" ]; then
        ucsi_die "--image not found: $image_path"
    fi

    # ---- defaults derived from repo state ----
    [ -n "$cache_dir" ] || cache_dir="$UCSI_REPO_ROOT/postbuild/os/build/ucsi-windows-e2e-cache"
    if [ -z "$workflow_ref" ]; then
        workflow_ref="$(git -C "$UCSI_REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    fi
    if [ -z "$workflow_repo" ]; then
        local dymk_url
        dymk_url="$(git -C "$UCSI_REPO_ROOT" remote get-url dymk 2>/dev/null || true)"
        if [ -n "$dymk_url" ]; then
            dymk_url="${dymk_url%.git}"
            workflow_repo="$(printf '%s' "$dymk_url" \
                | sed -E 's#^.*[:/]([^/]+/[^/]+)$#\1#')"
        fi
        [ -n "$workflow_repo" ] || workflow_repo="dymk/odp-platform-qemu-arm-virt"
    fi

    ucsi_validate_repo_name "$drivers_repo" \
        || ucsi_die "--drivers-repo must be OWNER/REPO using only letters, digits, '.', '_', or '-'"
    ucsi_validate_repo_name "$workflow_repo" \
        || ucsi_die "--workflow-repo must be OWNER/REPO using only letters, digits, '.', '_', or '-'"
    ucsi_validate_safe_token "$drivers_release" \
        || ucsi_die "--drivers-release contains unsupported characters"

    cache_dir="$(realpath -m -- "$cache_dir")"
    if ! ucsi_path_within_repo "$cache_dir" "$UCSI_REPO_ROOT"; then
        ucsi_die "--cache-dir must resolve inside the repository root ($UCSI_REPO_ROOT)"
    fi

    ucsi_require_tools
    ucsi_ensure_devcontainer
    ucsi_require_devcontainer_tools
    ucsi_select_guestfish

    # ---- deterministic cache key ----
    local source_id workflow_hash workflow_sha cache_key dispatch_nonce
    local driver_manifest driver_asset_identity
    if [ -n "$image_path" ]; then
        source_id="$(ucsi_image_identity "$image_path")"
    else
        source_id="url:$validation_os_url"
    fi
    workflow_sha="$(ucsi_resolve_workflow_sha "$workflow_repo" "$workflow_ref")"
    workflow_hash="$(sha256sum "$UCSI_REPO_ROOT/$UCSI_WORKFLOW_FILE" | awk '{print $1}')"
    driver_manifest="$(ucsi_resolve_driver_assets "$drivers_repo" "$drivers_release" \
        "$UCSI_REPO_ROOT/postbuild/os/prebuilt/driverlist.txt")"
    driver_asset_identity="$(ucsi_driver_asset_identity "$driver_manifest")"
    cache_key="$(ucsi_compute_cache_key "$source_id" "$os_build" "$drivers_repo" \
        "$drivers_release" "$driver_asset_identity" "$workflow_repo" "$workflow_ref" \
        "$workflow_sha" "$workflow_hash")"
    ucsi_log "cache key: $cache_key"
    ucsi_log "workflow source: $workflow_repo@$workflow_sha"

    dispatch_nonce="ucsi-$(date +%s%N)-$$-$RANDOM"
    ucsi_validate_safe_token "$dispatch_nonce" \
        || ucsi_die "internal error: generated dispatch nonce is invalid"

    # ---- firmware ----
    ucsi_ensure_firmware "$UCSI_REPO_ROOT" "$force_firmware"

    # ---- pristine base image ----
    local base_image
    base_image="$(ucsi_resolve_base_image "$cache_dir" "$cache_key" "$force_image" \
        "$image_path" "$validation_os_url" "$workflow_repo" "$workflow_ref" \
        "$drivers_repo" "$drivers_release" "$driver_manifest" "$dispatch_nonce" "$workflow_sha")"
    ucsi_log "base image: $base_image"

    # ---- disposable overlay with a relative backing path ----
    local run_dir overlay backing_rel
    run_dir="$cache_dir/run-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$run_dir"
    overlay="$run_dir/overlay.qcow2"
    backing_rel="$(ucsi_relative_backing_path "$overlay" "$base_image")"
    ( cd "$run_dir" && qemu-img create -f qcow2 -b "$backing_rel" -F qcow2 "overlay.qcow2" >/dev/null )
    ucsi_log "overlay: $overlay (backing $backing_rel)"

    local boot_log="$run_dir/boot.log"
    local result_file="$run_dir/ucsi-e2e-result.txt"
    local tpm_sock="$run_dir/swtpm-sock"
    local overlay_container; overlay_container="$(ucsi_host_to_container_path "$overlay" "$UCSI_REPO_ROOT")"

    ucsi_require_ports_free

    # ---- boot QEMU (background, bounded by --boot-timeout) ----
    UCSI_RUNNER_PID=""
    UCSI_VERIFIED_SUCCESS=0
    ucsi_cleanup() {
        local code=$?
        if [ -n "${UCSI_RUNNER_PID:-}" ] && kill -0 "$UCSI_RUNNER_PID" 2>/dev/null; then
            kill "$UCSI_RUNNER_PID" 2>/dev/null || true
            wait "$UCSI_RUNNER_PID" 2>/dev/null || true
        fi
        if ucsi_should_delete_overlay "$UCSI_VERIFIED_SUCCESS" "$keep_run_image"; then
            rm -f "$overlay"
        fi
        exit "$code"
    }
    trap ucsi_cleanup EXIT INT TERM

    ucsi_log "booting overlay under QEMU (timeout ${boot_timeout}s)"
    (
        timeout --foreground "$boot_timeout" \
            make -C "$UCSI_REPO_ROOT/mod/uefi" run \
                PATH_TO_OS="$overlay_container" \
                EC_I2C_SOCK= EC_GPIO_SOCK= \
                QEMU_DISPLAY=vnc \
                TPM_DEV="$tpm_sock" \
            > "$boot_log" 2>&1
    ) &
    UCSI_RUNNER_PID=$!

    # ---- drive the guest over VNC ----
    local deadline=$(( $(date +%s) + boot_timeout ))
    if ! ucsi_wait_for_prompt "$run_dir" "$deadline"; then
        ucsi_report_failure "$run_dir" "$boot_log" "$overlay" "timed out waiting for the ValidationOS prompt"
    fi

    ucsi_log "typing smoke command"
    if ! ucsi_type_smoke_command; then
        ucsi_report_failure "$run_dir" "$boot_log" "$overlay" \
            "failed to type or submit the UCSI smoke command over VNC"
    fi

    # The smoke app writes the result then shuts down; wait for QEMU to exit.
    # The stuart wrapper may exit non-zero (known UTF-8 serial decoder bug), so
    # its exit code is NOT used as the result signal.
    wait "$UCSI_RUNNER_PID" 2>/dev/null || true
    UCSI_RUNNER_PID=""

    # ---- verdict: guest result line AND secure-world UUID in the boot log ----
    if ! ucsi_extract_guest_result "$overlay" "$result_file"; then
        ucsi_report_failure "$run_dir" "$boot_log" "$overlay" "could not read $UCSI_GUEST_RESULT_PATH from the guest"
    fi
    if ! ucsi_check_result_file "$result_file"; then
        ucsi_report_failure "$run_dir" "$boot_log" "$overlay" \
            "guest result did not contain exact line '$UCSI_PASS_LINE'"
    fi
    if ! grep -qiF "$UCSI_SECURE_UUID" "$boot_log"; then
        ucsi_report_failure "$run_dir" "$boot_log" "$overlay" \
            "boot log missing secure UCSI UUID $UCSI_SECURE_UUID (secure world not reached)"
    fi
    UCSI_VERIFIED_SUCCESS=1

    ucsi_log "SUCCESS: Windows UCSI ACPI/FF-A E2E passed"
    ucsi_log "  result:   $result_file"
    ucsi_log "  boot log: $boot_log"
    printf '%s\n' "$UCSI_PASS_LINE"
    return 0
}

ucsi_report_failure() {
    local run_dir="$1" boot_log="$2" overlay="$3" reason="$4"
    ucsi_warn "FAILED: $reason"
    ucsi_warn "  run dir:  $run_dir"
    ucsi_warn "  boot log: $boot_log"
    [ -f "$run_dir/ucsi-e2e-result.txt" ] && ucsi_warn "  guest:    $run_dir/ucsi-e2e-result.txt"
    [ -f "$run_dir/prompt.png" ] && ucsi_warn "  screenshot: $run_dir/prompt.png"
    [ -f "$overlay" ] && ucsi_warn "  overlay preserved: $overlay"
    exit 1
}

# When sourced for unit tests, stop here (functions only).
if [ -n "${UCSI_WINDOWS_E2E_SOURCE_ONLY:-}" ]; then
    return 0 2>/dev/null || true
else
    ucsi_main "$@"
fi
