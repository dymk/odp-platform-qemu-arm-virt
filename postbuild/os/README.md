# Booting Validation OS Image

## Preparing the Windows Validation OS (WinVOS) Image

WinVOS is a pared down Windows OS image that is convenient for basic development while also booting relatively quickly under QEMU.  

The image is built by the `build_os_image` GitHub Actions workflow (`.github/workflows/build-os.yml`), which injects the QEMU drivers listed in `prebuilt/driverlist.txt`. Running `make run_os` or `make qcow2` will download the latest built artifact. To build manually, download the ISO from https://aka.ms/DownloadValidationOS_arm64.


## Booting QEMU `virt` to Windows

After you have created a ValidationOS.vhdx with your required files, simply copy it to the prebuilt folder and from the root folder run
    `make run_os`

This will generate the qcow2 image from the vhdx and run your BIOS in the parent folder path and boot to a command prompt. Your output display will be redirected to VNC port 5900 by default. You can use and VNC Viewer to open the display `127.0.0.1:5900`. 

If you want you can force regeneration of the winvos.qcow2 image using
    `make qcow2`

## Connecting with Windbg

GDB server is at:  `127.0.0.1:5555`. 

Windbg can be connected on  `windbg -k com:ipport=56789,port=127.0.0.1 -v`

## Local Windows/ACPI E2E adapters

`scripts/run-windows-acpi-e2e.sh` builds and runs a Windows ValidationOS
image locally. It downloads or consumes the ISO, resolves immutable driver
release assets, builds the adapter smoke executable with cargo-xwin 0.23,
compiles the current ACPI table, builds firmware, constructs a GPT Windows
disk under headless QEMU, and verifies the guest result and secure partition
UUID. The final command refuses a declared ValidationOS build below 28000.

Every adapter directory contains:

```text
drivers.txt
secure-uuid.txt
smoke/
  Cargo.toml
  Cargo.lock
  rust-toolchain.toml
  src/main.rs
```

`drivers.txt` lists release asset basenames without `.zip`.
`secure-uuid.txt` contains exactly one lowercase canonical UUID. The smoke
crate must explicitly declare a `[[bin]]` named `smoke`, producing
`smoke.exe`; use
`postbuild/os/windows-acpi-e2e/guest-support` to write the standard result,
mirror it to COM1 when available, and shut down the guest.

The guest paths are fixed:

- `C:\odp-e2e\smoke.exe`
- `C:\odp-e2e\result.txt`
- success: `PASS: Windows ACPI E2E`
- failure prefix: `FAIL: `

An empty `needs-ec-sidecar` file selects the existing EC firmware sidecar.
The runner builds `mod/ec/platform/dev-qemu`, starts its RISC-V QEMU, wires
run-local I2C/GPIO sockets into the host QEMU, connects the established PTY
serial transport, records `ec-sidecar.log`, and terminates only the PID it
started.

Adapters normally compile
`mod/uefi/platform/QemuArmVirtPkg/AcpiTables/ec.asl`. An optional
`acpi-entry.txt` may select another repository-relative entry file, and
`acpi-includes.txt` may list additional repository-relative include
directories. Absolute paths and parent traversal are rejected.

Example:

```sh
scripts/run-windows-acpi-e2e.sh \
  --adapter postbuild/os/windows-acpi-e2e/test-adapter \
  --validation-os-url https://example.invalid/ValidationOS.iso \
  --validation-os-build 28000
```

Use exactly one of `--validation-os-url`, `--validation-os-iso`, or `--image`.
`--image` accepts a flat VHDX or QCOW2 that already contains the adapter
payload. `--cache-dir`, `--drivers-release`, `--force`,
`--builder-timeout`, `--boot-timeout`, and `--keep` control local execution.
Completed boots retain compact evidence under the cache. Failures preserve
their run directory; `--keep` also preserves a successful disposable overlay.
