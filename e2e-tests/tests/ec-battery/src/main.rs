//! E2E test: EcBattery GetBst via FF-A Direct Request v2 ↔ MCTP/PL011 ↔ EC.
//!
//! Issues an FFA Direct Request v2 to the SP-side `EcBattery` service
//! (UUID `25cb5207-ac36-427d-aaef-3aa78877d27e`). The SP service round-trips
//! a `GetBst { battery_id: 0 }` request over MCTP-via-PL011 to the EC SP's
//! `BatteryServiceRelayHandler`, parses the EC's 16-byte BST response (4
//! little-endian `u32` dwords: `battery_state`, `battery_present_rate`,
//! `battery_remaining_capacity`, `battery_present_voltage` — see
//! `ec-service-lib::services::ec_battery::BstReturnRaw`), and packs those
//! 16 bytes into the FFA Direct Resp2 register payload (`x4..=x7`).
//!
//! On PASS this test emits the contract-locked marker:
//!
//! ```text
//! EC_MCTP_OK service_id=8 msg_id=GetBst battery_status=<32-hex>
//! ```
//!
//! `scripts/test-e2e-mctp.sh` greps the SBSA serial log for the literal
//! prefix `EC_MCTP_OK service_id=8 msg_id=GetBst` via `grep -F`.
//!
//! On any failure the test emits `EC_MCTP_FAIL <reason>` and returns
//! `Status::ABORTED` so the QEMU exit code distinguishes pass from fail.
//!
//! The EC mock battery (`battery_service::mock::MockBatteryDriver`) is
//! state-machine-driven and does not expose deterministic field values from
//! an inspectable source crate, so this test asserts only the wire-format
//! invariants: 16-byte response length + a non-zero leading dword. The full
//! 16 bytes are echoed in the marker's `battery_status` field for
//! human/CI diagnostic inspection.
//!
//! SPDX-License-Identifier: MIT
//!

#![no_main]
#![no_std]

extern crate alloc;

use core::fmt::Write;
use ffa::DirectMessagePayload;
use test_support::{
    response_payload, run_tests, send_direct_req2, TestResults, BATTERY_UUID,
    EC_MCTP_OK_MARKER_PREFIX,
};
use uefi::prelude::*;

/// Expected length of the SP-side EcBattery BST response payload (4 LE u32).
const BST_RESPONSE_LEN: usize = 16;

#[entry]
fn main() -> Status {
    run_tests(test_ec_battery_get_bst)
}

fn test_ec_battery_get_bst(results: &mut TestResults, our_id: u16, ec_id: u16) {
    log::info!("ec-battery: starting GetBst round-trip");

    // The SP-side EcBattery service ignores the FFA request payload and
    // always issues `GetBst { battery_id: 0 }` for v1.8 (see
    // `ec-service-lib::services::ec_battery::EcBattery::ffa_msg_send_direct_req2`).
    // We send a single `0x00` byte (battery_id = 0) anyway so future
    // multi-battery support has a forward-compatible call site.
    let payload = DirectMessagePayload::from_iter(core::iter::once(0u8));

    let resp = match send_direct_req2(our_id, ec_id, &BATTERY_UUID, &payload) {
        Some(r) => r,
        None => {
            log::error!("EC_MCTP_FAIL unexpected-response-fid");
            results.fail("ec_battery_get_bst", "unexpected response FID");
            return;
        }
    };

    // The SP packs the 16 BST bytes into the response payload's leading
    // 16 bytes (x4..=x7). The full `DirectMessagePayload` covers
    // x4..=x17 = 14 regs = 112 bytes; we slice the leading 16 bytes.
    let resp_payload = response_payload(&resp);
    let mut body = [0u8; BST_RESPONSE_LEN];
    for (i, b) in body.iter_mut().enumerate() {
        *b = resp_payload.u8_at(i);
    }

    let leading_dword = u32::from_le_bytes([body[0], body[1], body[2], body[3]]);

    if leading_dword == 0 {
        log::error!(
            "EC_MCTP_FAIL bst-leading-dword-zero body={}",
            fmt_hex(&body)
        );
        results.fail(
            "ec_battery_get_bst",
            "leading BST dword (battery_state) is zero",
        );
        return;
    }

    // Marker — the prefix is the single source of truth at
    // `test_support::EC_MCTP_OK_MARKER_PREFIX`; the harness extracts it
    // from that file at run-time. The `battery_status=<hex>` suffix is
    // informational / diagnostic.
    log::info!(
        "{} battery_status={}",
        EC_MCTP_OK_MARKER_PREFIX,
        fmt_hex(&body)
    );
    results.pass("ec_battery_get_bst");
}

/// Format bytes as a contiguous lowercase hex string (no separators).
fn fmt_hex(bytes: &[u8]) -> alloc::string::String {
    let mut s = alloc::string::String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(&mut s, "{:02x}", b);
    }
    s
}
