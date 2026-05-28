//! QEMU EC Secure Partition Service entry point.
//!
//! SPDX-License-Identifier: MIT
//!

#![cfg_attr(target_os = "none", no_std)]
#![cfg_attr(target_os = "none", no_main)]
#![deny(clippy::undocumented_unsafe_blocks)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
mod baremetal;

#[cfg(not(target_os = "none"))]
fn main() {
    println!("qemu-sp stub");
}

/// TPM CRB MMIO base address.
///
/// Must match the device-region mapping in the SP manifest (`qemu-ec-sp.dts`).
#[cfg(target_os = "none")]
const TPM_CRB_MMIO_BASE: u64 = 0x10000210000;
/// External TPM CRB (swtpm MMIO registers) — matches `tpm_external_crb`
/// device-region in the SP manifest (`qemu-ec-sp.dts`).
#[cfg(target_os = "none")]
const TPM_EXTERNAL_CRB_BASE: u64 = 0x60120000;

#[cfg(target_os = "none")]
fn main() -> ! {
    use core::cell::RefCell;
    use ec_service_lib::MessageHandler;
    use odp_ffa::Function;

    log::info!("QEMU Secure Partition - build time: {}", env!("BUILD_TIME"));

    let version = odp_ffa::Version::new().exec().unwrap();
    log::info!("FFA version: {}.{}", version.major(), version.minor());

    let tpm_sst = ec_service_lib::services::TpmSst::new();
    let mut tpm = ec_service_lib::services::TpmService::new(tpm_sst);

    // SAFETY: TPM_CRB_MMIO_BASE is mapped as a device region in the SP manifest (qemu-ec-sp.dts).
    unsafe {
        tpm.init(TPM_CRB_MMIO_BASE, TPM_EXTERNAL_CRB_BASE);
    }

    // SAFETY: 0x60030000 is mapped as the `ec_uart` device region in the
    // SP manifest (`qemu-ec-sp.dts`). `Pl011Uart::new` is `unsafe` because
    // it wraps `RawMmio::new`; the caller must guarantee the device region
    // is mapped exactly once.
    let ec_uart = unsafe { qemu_sp_uart::Pl011Uart::new(0x60030000) };
    // Wiring layer owns the relay. Service code (`Battery`, future
    // `EcThermal`, ...) borrows the `RefCell` and never touches the
    // transport or assembly buffer directly. `RefCell` interior
    // mutability is sufficient because the SP runtime is single-threaded
    // synchronous; nested `borrow_mut` would only happen on a programming
    // error.
    //
    // EIDs: src = SP_EID (0x08), dst = EC_EID (0x0A). The MCTP serial medium
    // has no addressing of its own (per `odp_client::SerialTransport` docs),
    // so these are stamped onto outbound frames purely for trace clarity and
    // are not validated on receive.
    let ec_relay = RefCell::new(odp_client::OdpClient::new(
        odp_client::SerialTransport::new(ec_uart, mctp_rs::SP_EID, mctp_rs::EC_EID),
    ));

    MessageHandler::new()
        .append(ec_service_lib::services::Thermal::new())
        .append(ec_service_lib::services::FwMgmt::new())
        .append(ec_service_lib::services::Notify::new())
        .append(ec_service_lib::services::Battery::new(&ec_relay))
        .append(tpm)
        .run_message_loop()
        .expect("Error in run_message_loop");

    unreachable!()
}
