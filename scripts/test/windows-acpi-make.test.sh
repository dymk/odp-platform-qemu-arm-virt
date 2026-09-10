#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

for service in thermal ucsi; do
    for inside in 0 1; do
        output="$(make --no-print-directory -n -C "$ROOT" windows-acpi-e2e \
            IN_DEVCONTAINER="$inside" WINDOWS_ACPI_E2E_SERVICE="$service")"
        if ! grep -qF "WINDOWS_ACPI_E2E_SERVICE=\"$service\"" <<< "$output"; then
            echo "FAIL: $service selection was not forwarded (IN_DEVCONTAINER=$inside)" >&2
            exit 1
        fi
    done
done

output="$(make --no-print-directory -n -C "$ROOT" windows-acpi-e2e IN_DEVCONTAINER=1)"
grep -qF 'WINDOWS_ACPI_E2E_SERVICE="thermal"' <<< "$output"

for invalid in '' unknown 'thermal ucsi' 'thermal unknown'; do
    if make --no-print-directory -n -C "$ROOT" windows-acpi-e2e \
        IN_DEVCONTAINER=1 WINDOWS_ACPI_E2E_SERVICE="$invalid" >/dev/null 2>&1; then
        echo "FAIL: invalid service '$invalid' was accepted" >&2
        exit 1
    fi
done

echo "Windows ACPI Make selection checks passed"
