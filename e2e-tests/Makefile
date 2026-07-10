# E2E Tests for the EC Secure Partition
#
# SPDX-License-Identifier: MIT
#
# Builds Rust UEFI test applications, launches QEMU with the existing
# BIOS firmware, and executes tests against the secure partition.

SHELL := /bin/bash

include ../Common.mk

# Build output paths
TARGET_DIR := target/aarch64-unknown-uefi/release
THERMAL_EFI := $(TARGET_DIR)/thermal.efi
TPM_EFI := $(TARGET_DIR)/tpm.efi
BATTERY_EFI := $(TARGET_DIR)/battery.efi
TIME_ALARM_EFI := $(TARGET_DIR)/time_alarm.efi

# Timeout for QEMU execution (seconds)
QEMU_TIMEOUT ?= 180

# Bounds on the two-QEMU thermal e2e (test-sp-ec-link). The EC sidecar is a
# passive responder: it must stay alive for the whole window the host might
# take to boot and relay its request. On a slow runner (CI) the host needs
# well over a minute to reach the UEFI shell and issue GetTmp, so a short
# fixed EC lifetime races the host — the EC gets killed before the request
# arrives and the SP relay times out (thermal status=-1). Tie the EC lifetime
# to the host's own bound; the harness reaps the EC promptly via
# kill_ec_session once the host finishes, so this only acts as an upper
# backstop against a leaked EC process.
EC_SERIAL_TIMEOUT  ?= $(QEMU_TIMEOUT)

# Virtual drive directories for UEFI Shell to find test EFI binaries.
# Each test runs in its own vdrive so the shared startup.nsh finds exactly
# one binary (no parameterising the shell). Splitting the vdrive also lets
# the two-QEMU thermal path and the single-QEMU TPM path stage independent
# payloads.
VDRIVE_THERMAL_DIR := Build/vdrive-thermal
VDRIVE_TPM_DIR     := Build/vdrive-tpm
VDRIVE_BATTERY_DIR := Build/vdrive-battery
VDRIVE_TIME_ALARM_DIR := Build/vdrive-time-alarm

# Shared generic UEFI shell startup script (runs the single .efi on the
# vdrive), reused by every per-test vdrive so new service tests don't each
# need their own startup script.
STARTUP_NSH := startup.nsh

# Tee QEMU serial output to stdout (auto-enabled in CI). Passed through to
# scripts/test-sp-services.sh, which owns the actual -serial / tee plumbing.
ifeq ($(CI),true)
SERIAL_TEE ?= 1
else
SERIAL_TEE ?= 0
endif

# Coverage plugin
COVERAGE_PLUGIN := Build/libcoverage.so
COVERAGE_LOG := Build/coverage.log
SP_ELF := ../mod/secure-services/platform/target/aarch64-unknown-none/coverage/qemu-ec-sp

# All test EFI binaries
TEST_EFIS := $(THERMAL_EFI) $(TPM_EFI)

# ------------------------------------------------------------
# Build all test EFI binaries
# ------------------------------------------------------------
.PHONY: all
all: build

.PHONY: build
build: builder-image
	$(call GROUP,Build E2E test binaries)
	@$(DC_RUN) -w e2e-tests -- cargo build --release
	$(call ENDGROUP)

# ------------------------------------------------------------
# Prepare per-test virtual FAT drives with binaries + startup.nsh
# ------------------------------------------------------------
# make-vdrive <vdrive-dir> <efi-path>: stage a per-test FAT drive with the
# test binary + the shared generic startup.nsh. New service tests add one
# more $(call make-vdrive,...) — no new startup script.
define make-vdrive
rm -rf $(1)
mkdir -p $(1)
cp $(2) $(1)/
cp $(STARTUP_NSH) $(1)/startup.nsh
endef

$(VDRIVE_THERMAL_DIR): build $(THERMAL_EFI) $(STARTUP_NSH)
	$(call make-vdrive,$(VDRIVE_THERMAL_DIR),$(THERMAL_EFI))

$(VDRIVE_TPM_DIR): build $(TPM_EFI) $(STARTUP_NSH)
	$(call make-vdrive,$(VDRIVE_TPM_DIR),$(TPM_EFI))

$(VDRIVE_BATTERY_DIR): build $(BATTERY_EFI) $(STARTUP_NSH)
	$(call make-vdrive,$(VDRIVE_BATTERY_DIR),$(BATTERY_EFI))

$(VDRIVE_TIME_ALARM_DIR): build $(TIME_ALARM_EFI) $(STARTUP_NSH)
	$(call make-vdrive,$(VDRIVE_TIME_ALARM_DIR),$(TIME_ALARM_EFI))

# ------------------------------------------------------------
# Run tests with timeout, capture output, report results
# ------------------------------------------------------------
# ------------------------------------------------------------
# Build the TCG coverage plugin (.so loaded by QEMU)
# ------------------------------------------------------------
$(COVERAGE_PLUGIN): builder-image
	$(call GROUP,Build coverage plugin)
	@$(DC_RUN) -w e2e-tests -- make -C coverage-plugin BUILD_DIR=../Build
	$(call ENDGROUP)

.PHONY: test-sp-services
test-sp-services: $(VDRIVE_TPM_DIR) $(COVERAGE_PLUGIN)
	@mkdir -p Build
	@echo "=== Running SP services E2E tests (timeout=$(QEMU_TIMEOUT)s) ==="
ifeq ($(SERIAL_TEE),1)
else
	@echo "    (serial output streaming to Build/test-output.log)"
endif
	$(call GROUP,SP services E2E tests)
	@$(DC_RUN) -- scripts/test-sp-services.sh \
		--bios-fv-dir $(BIOS_FV_DIR) \
		--build-dir e2e-tests/Build \
		--vdrive-dir e2e-tests/$(VDRIVE_TPM_DIR) \
		--coverage-plugin e2e-tests/$(COVERAGE_PLUGIN) \
		--coverage-log e2e-tests/$(COVERAGE_LOG) \
		--host-timeout $(QEMU_TIMEOUT) \
		--serial-tee $(SERIAL_TEE) \
		-- $(QEMU_COMMON_ARGS)
	$(call ENDGROUP)

# ------------------------------------------------------------
# Two-QEMU Thermal E2E Test (test-sp-ec-link)
# ------------------------------------------------------------
# Launches EC QEMU with `-serial pty` (QEMU allocates a pseudo-tty
# and prints its path to stderr), parses the path, then delegates
# host QEMU launch + result parsing to the same runner test-sp-services
# uses (scripts/lib/host-qemu.sh::run_host_efi_and_parse_results).
# Asserts the [PASS] line + DeciKelvin range originated from the EC.
#
# Caller (top-level Makefile) is responsible for ensuring `ec` and `uefi`
# are built; this target only runs the e2e check.
#
# run-sp-ec-link <vdrive-dir>: launch the EC sidecar + host SP two-QEMU run
# against the given per-test vdrive. Shared by every two-QEMU service test.
define run-sp-ec-link
@$(DC_RUN) -- scripts/test-sp-ec-link.sh \
	--ec-elf $(EC_BINARY) \
	--bios-fv-dir $(BIOS_FV_DIR) \
	--build-dir e2e-tests/Build \
	--vdrive-dir e2e-tests/$(1) \
	--coverage-plugin e2e-tests/$(COVERAGE_PLUGIN) \
	--coverage-log e2e-tests/$(COVERAGE_LOG) \
	--ec-timeout $(EC_SERIAL_TIMEOUT) \
	--host-timeout $(QEMU_TIMEOUT) \
	--serial-tee $(SERIAL_TEE) \
	-- $(QEMU_COMMON_ARGS)
endef

.PHONY: test-sp-ec-link
test-sp-ec-link: $(VDRIVE_THERMAL_DIR) $(COVERAGE_PLUGIN) | builder-image
	@mkdir -p Build
	@echo "=== Running two-QEMU Thermal e2e (EC timeout=$(EC_SERIAL_TIMEOUT)s, host timeout=$(QEMU_TIMEOUT)s) ==="
	$(call GROUP,Two-QEMU Thermal e2e)
	$(call run-sp-ec-link,$(VDRIVE_THERMAL_DIR))
	$(call ENDGROUP)

.PHONY: test-sp-ec-link-battery
test-sp-ec-link-battery: $(VDRIVE_BATTERY_DIR) $(COVERAGE_PLUGIN) | builder-image
	@mkdir -p Build
	@echo "=== Running two-QEMU Battery e2e (EC timeout=$(EC_SERIAL_TIMEOUT)s, host timeout=$(QEMU_TIMEOUT)s) ==="
	$(call GROUP,Two-QEMU Battery e2e)
	$(call run-sp-ec-link,$(VDRIVE_BATTERY_DIR))
	$(call ENDGROUP)

.PHONY: test-sp-ec-link-time-alarm
test-sp-ec-link-time-alarm: $(VDRIVE_TIME_ALARM_DIR) $(COVERAGE_PLUGIN) | builder-image
	@mkdir -p Build
	@echo "=== Running two-QEMU TimeAlarm e2e (EC timeout=$(EC_SERIAL_TIMEOUT)s, host timeout=$(QEMU_TIMEOUT)s) ==="
	$(call GROUP,Two-QEMU TimeAlarm e2e)
	$(call run-sp-ec-link,$(VDRIVE_TIME_ALARM_DIR))
	$(call ENDGROUP)

# ------------------------------------------------------------
# Generate coverage report from collected PCs
# ------------------------------------------------------------
.PHONY: coverage-report
coverage-report:
	$(call GROUP,Generate coverage report)
	@$(DC_RUN) -w e2e-tests -- python3 scripts/pcs-to-lcov.py \
		--elf $(SP_ELF) \
		--input $(COVERAGE_LOG) \
		--output Build/coverage.info \
		--source-prefix odp-secure-services \
		--source-prefix odp-platform-qemu-arm-virt
	@$(DC_RUN) -w e2e-tests -- genhtml Build/coverage.info \
		--ignore-errors source \
		--output-directory Build/coverage-html \
		--title 'EC Secure Partition Coverage'
	$(call ENDGROUP)

# ------------------------------------------------------------
# Clean build artifacts
# ------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf Build
	@$(DC_RUN) -w e2e-tests -- cargo clean
	@$(DC_RUN) -w e2e-tests -- make -C coverage-plugin clean
