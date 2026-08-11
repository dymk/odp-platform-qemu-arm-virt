# UCSI Windows ACPI E2E adapter

This adapter depends on the generic harness, UCSI platform PR #143, and platform-common PR #162.

Run it with a Windows ValidationOS image whose build is at least 28000:

```sh
scripts/run-windows-acpi-e2e.sh \
  --adapter postbuild/os/windows-acpi-e2e/adapters/ucsi \
  --image /path/to/winvos.qcow2 \
  --validation-os-build 28000
```
