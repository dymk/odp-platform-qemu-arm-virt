# UEFI shell startup script for the MCTP E2E test (Phase 37).
#
# Auto-launched by the UEFI shell when booting from a vdrive built by
# the `make e2e-test-mctp` target (`e2e-tests/Build/vdrive-mctp/`,
# renamed to `startup.nsh` on copy). The vdrive contains exactly one
# test EFI (`ec-battery.efi`); existing `startup.nsh` is untouched so
# `make e2e-test` keeps booting thermal.efi + tpm.efi as before.
#
# SPDX-License-Identifier: MIT
#

@echo -off
for %a in fs4 fs3 fs2 fs1 fs0
  if exist %a:\ec-battery.efi then
    %a:\ec-battery.efi
    reset -s
    goto done
  endif
endfor
echo ec-battery.efi not found on any filesystem
:done
