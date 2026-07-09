# Generic UEFI shell startup script for the E2E tests.
#
# Runs whichever single *.efi is staged on the test vdrive, so every
# per-test vdrive reuses this one script (only the .efi differs). The
# host QEMU exposes exactly one FAT filesystem (the vdrive), so the
# *.efi wildcard matches only the test binary.
#
# SPDX-License-Identifier: MIT
#

@echo -off
for %a in fs4:\*.efi fs3:\*.efi fs2:\*.efi fs1:\*.efi fs0:\*.efi
  if exist %a then
    %a
    reset -s
    goto done
  endif
endfor
echo No test .efi found on any filesystem
:done
