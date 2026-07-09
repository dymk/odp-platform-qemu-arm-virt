//! E2E test: Thermal service get_temperature via FF-A Direct Request v2.
//!
//! SPDX-License-Identifier: MIT
//!

#![no_main]
#![no_std]

extern crate alloc;

use test_support::{run_tests, send_service_command, TestResults, THERMAL_UUID};
use uefi::prelude::*;

/// EC_THM_GET_TMP opcode.
const EC_THM_GET_TMP: u8 = 0x01;

/// Mock sensor in dev-qemu sawtooths 20–40 °C, which is
/// (20+273.15)*10 ≈ 2932 dK .. (40+273.15)*10 ≈ 3132 dK.
/// Widen by ±~30 dK to absorb sawtooth phase + any
/// truncation/rounding the EC's sensor stack applies.
const MIN_DK: u64 = 2900;
const MAX_DK: u64 = 3200;

#[entry]
fn main() -> Status {
    run_tests(test_thermal_get_temperature)
}

fn test_thermal_get_temperature(results: &mut TestResults, our_id: u16, ec_id: u16) {
    // byte 0 = command (EC_THM_GET_TMP), byte 1 = sensor_id
    let sensor_id: u8 = 0;
    let resp_payload = match send_service_command(
        results,
        "thermal_get_temperature",
        our_id,
        ec_id,
        &THERMAL_UUID,
        EC_THM_GET_TMP,
        &[sensor_id],
    ) {
        Some(p) => p,
        None => return,
    };

    // Response layout: byte 0..8 = status (i64),
    // byte 8..16 = temperature (u64; EC u32 LE DeciKelvin zero-extended)
    let status = resp_payload.u64_at(0) as i64;
    let temperature = resp_payload.u64_at(8);

    log::info!(
        "  get_temperature response: status={}, temp={:#x}",
        status,
        temperature,
    );

    if status != 0 {
        results.fail("thermal_get_temperature", "non-zero status from SP");
        return;
    }
    if !(MIN_DK..=MAX_DK).contains(&temperature) {
        results.fail(
            "thermal_get_temperature",
            "DeciKelvin out of EC mock-sensor range",
        );
        return;
    }
    results.pass("thermal_get_temperature");
}
