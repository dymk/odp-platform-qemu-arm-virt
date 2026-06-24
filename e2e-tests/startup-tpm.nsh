# UEFI shell startup script for the TPM E2E test.
#
# SPDX-License-Identifier: MIT
#

@echo -off
for %a in fs4 fs3 fs2 fs1 fs0
  if exist %a:\tpm.efi then
    %a:\tpm.efi
    reset -s
    goto done
  endif
endfor
echo tpm.efi not found on any filesystem
:done
