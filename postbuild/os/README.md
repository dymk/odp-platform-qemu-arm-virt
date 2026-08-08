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

## Windows UCSI ACPI -> FF-A end-to-end runner

`scripts/run-ucsi-windows-e2e.sh` drives the full Windows UCSI path
(`ucsi-smoke.exe -> ectest.sys -> ECT0.USND -> FFixedHw/FFAC -> Windows FF-A
-> secure UCSI SP`). It builds/reuses the firmware, dispatches the
`build_os_image` workflow (which injects the `ectest` driver and the smoke app),
caches the resulting image by a deterministic key, boots a disposable qcow2
overlay, and asserts both the guest success line and the secure UCSI UUID in the
boot log.

The public ValidationOS (build `26100.x`) lacks ACPI FF-A support, so the runner
refuses any build `< 28000`. Declare the build explicitly:

    scripts/run-ucsi-windows-e2e.sh \
      --validation-os-url <ARM64-ValidationOS-ISO-URL> \
      --validation-os-build 28000

or import a pre-built image instead of dispatching the workflow:

    scripts/run-ucsi-windows-e2e.sh --image path/to/os-image.vhdx \
      --validation-os-build 28000

Run `scripts/run-ucsi-windows-e2e.sh --help` for the full option list. Unit
tests for the runner's pure logic live in
`scripts/tests/run-ucsi-windows-e2e-test.sh`.
