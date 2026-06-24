# UEFI shell startup script for the thermal E2E test.
#
# SPDX-License-Identifier: MIT
#

@echo -off
for %a in fs4 fs3 fs2 fs1 fs0
  if exist %a:\thermal.efi then
    %a:\thermal.efi
    reset -s
    goto done
  endif
endfor
echo thermal.efi not found on any filesystem
:done
