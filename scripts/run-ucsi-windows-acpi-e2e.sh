#!/usr/bin/env bash
# Launch the UCSI adapter through the generic Windows/ACPI E2E runner.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

exec "$SCRIPT_DIR/run-windows-acpi-e2e.sh" \
    --adapter "$REPO_ROOT/postbuild/os/windows-acpi-e2e/adapters/ucsi" \
    "$@"
