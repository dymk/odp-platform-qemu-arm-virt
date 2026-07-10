//! E2E test: TimeAlarm GetRealTime via FF-A Direct Request v2.
//!
//! SPDX-License-Identifier: MIT
//!

#![no_main]
#![no_std]

extern crate alloc;

use ffa::DirectMessagePayload;
use test_support::{run_tests, send_service_command, TestResults, TIME_ALARM_UUID};
use uefi::{boot, prelude::*};

const GET_REAL_TIME: u8 = 2;
const STALL_MICROSECONDS: usize = 3_000_000;
const ACPI_TIMESTAMP_LEN: usize = 16;

#[derive(Clone, Copy)]
struct Timestamp {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    valid: u8,
    milliseconds: u16,
    timezone: i16,
    daylight: u8,
    reserved: [u8; 3],
}

impl Timestamp {
    fn parse(payload: &DirectMessagePayload) -> Self {
        Self {
            year: u16::from_le_bytes([payload.u8_at(0), payload.u8_at(1)]),
            month: payload.u8_at(2),
            day: payload.u8_at(3),
            hour: payload.u8_at(4),
            minute: payload.u8_at(5),
            second: payload.u8_at(6),
            valid: payload.u8_at(7),
            milliseconds: u16::from_le_bytes([payload.u8_at(8), payload.u8_at(9)]),
            timezone: i16::from_le_bytes([payload.u8_at(10), payload.u8_at(11)]),
            daylight: payload.u8_at(12),
            reserved: [
                payload.u8_at(ACPI_TIMESTAMP_LEN - 3),
                payload.u8_at(ACPI_TIMESTAMP_LEN - 2),
                payload.u8_at(ACPI_TIMESTAMP_LEN - 1),
            ],
        }
    }

    fn seconds_of_day(self) -> u32 {
        u32::from(self.hour) * 3600 + u32::from(self.minute) * 60 + u32::from(self.second)
    }

    fn is_expected_mock_shape(self) -> bool {
        self.year == 1970
            && self.month == 1
            && self.day == 1
            && self.hour < 24
            && self.minute < 60
            && self.second < 60
            && self.valid == 1
            && self.milliseconds < 1000
            && self.timezone == 0
            && self.daylight == 0
            && self.reserved == [0, 0, 0]
    }
}

#[entry]
fn main() -> Status {
    run_tests(test_get_real_time)
}

fn get_real_time(results: &mut TestResults, our_id: u16, ec_id: u16) -> Option<Timestamp> {
    let payload = send_service_command(
        results,
        "time_alarm_get_real_time",
        our_id,
        ec_id,
        &TIME_ALARM_UUID,
        GET_REAL_TIME,
        &[],
    )?;
    Some(Timestamp::parse(&payload))
}

fn test_get_real_time(results: &mut TestResults, our_id: u16, ec_id: u16) {
    let Some(first) = get_real_time(results, our_id, ec_id) else {
        return;
    };
    if !first.is_expected_mock_shape() {
        results.fail(
            "time_alarm_get_real_time",
            "first timestamp does not match EC mock shape",
        );
        return;
    }

    boot::stall(STALL_MICROSECONDS);

    let Some(second) = get_real_time(results, our_id, ec_id) else {
        return;
    };
    if !second.is_expected_mock_shape() {
        results.fail(
            "time_alarm_get_real_time",
            "second timestamp does not match EC mock shape",
        );
        return;
    }

    let Some(delta) = second.seconds_of_day().checked_sub(first.seconds_of_day()) else {
        results.fail("time_alarm_get_real_time", "EC time moved backwards");
        return;
    };

    log::info!(
        "  GetRealTime: first={:02}:{:02}:{:02}.{:03} \
         second={:02}:{:02}:{:02}.{:03} delta={}s",
        first.hour,
        first.minute,
        first.second,
        first.milliseconds,
        second.hour,
        second.minute,
        second.second,
        second.milliseconds,
        delta,
    );

    if !(2..=6).contains(&delta) {
        results.fail(
            "time_alarm_get_real_time",
            "EC clock delta outside 2..=6 seconds",
        );
        return;
    }

    results.pass("time_alarm_get_real_time");
}
