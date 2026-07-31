//! E2E test: UCSI PPM stub routing over FF-A Direct Request v2.
//!
//! SPDX-License-Identifier: MIT
//!
//! Direct FF-A routing smoke: drives the three read commands the secure-world
//! UCSI stub answers and asserts VERSION/CCI/MESSAGE-IN bytes. This proves
//! manifest advertisement, UUID routing, and the SP response — it does not
//! exercise the ACPI `ECT0.USND` path.

#![no_main]
#![no_std]

extern crate alloc;

use ffa::DirectMessagePayload;
use test_support::{run_tests, E2eContext, UCSI_UUID};
use uefi::prelude::*;

/// FF-A payload byte 0: the doorbell tag the OS writes ahead of the mailbox.
const DOORBELL: u8 = 0x00;
/// Connector number the stub models (single-connector fixture).
const CONNECTOR_ONE: u8 = 1;

/// Mailbox offsets inside the response payload (48-byte UCSI mailbox at
/// payload offset 0).
const VERSION_OFFSET: usize = 0;
const CCI_OFFSET: usize = 4;
const CONTROL_OFFSET: usize = 8;
const MESSAGE_IN_OFFSET: usize = 16;

const OP_GET_CAPABILITY: u8 = 0x06;
const OP_GET_CONNECTOR_CAPABILITY: u8 = 0x07;
const OP_GET_CONNECTOR_STATUS: u8 = 0x12;

const VERSION_UCSI_1_2: u16 = 0x0120;
const CCI_CAPABILITY: u32 = 0x8000_1000;
const CCI_CONNECTOR_CAPABILITY: u32 = 0x8000_0200;
const CCI_CONNECTOR_STATUS: u32 = 0x8000_0B00;

const CAPABILITY_MESSAGE_IN: [u8; 16] = [
    0x46, 0x40, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x01, 0x00, 0x03, 0x00, 0x02,
];
const CONNECTOR_CAPABILITY_MESSAGE_IN: [u8; 2] = [0x64, 0x03];
const CONNECTOR_STATUS_MESSAGE_IN: [u8; 11] = [
    0x00, 0x00, 0x29, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

#[entry]
fn main() -> Status {
    run_tests(test_ucsi_command_family)
}

fn test_ucsi_command_family(ctx: &mut E2eContext) {
    test_ucsi_partition_discovery(ctx);
    test_get_capability(ctx);
    test_get_connector_capability(ctx);
    test_get_connector_status(ctx);
}

fn test_ucsi_partition_discovery(ctx: &mut E2eContext) {
    const NAME: &str = "ucsi_partition_discovery";
    match ffa::ffa_partition_info_get_regs(&UCSI_UUID) {
        Ok((count, _)) if count > 0 => ctx.pass(NAME),
        Ok(_) => ctx.fail(NAME, "UCSI UUID is not advertised by any partition"),
        Err(_) => ctx.fail(NAME, "PARTITION_INFO_GET_REGS failed for UCSI UUID"),
    }
}

/// Send one UCSI command: `[DOORBELL] + 48-byte mailbox` with `opcode` at
/// CONTROL offset 0 and `connector` at CONTROL offset 2. Returns the response
/// mailbox (payload offset 0), failing `name` if the SP sends no DIRECT_RESP2.
fn ucsi_call(
    ctx: &mut E2eContext,
    name: &str,
    opcode: u8,
    connector: u8,
) -> Option<DirectMessagePayload> {
    let mut mailbox = [0u8; 48];
    mailbox[CONTROL_OFFSET] = opcode;
    mailbox[CONTROL_OFFSET + 2] = connector;
    ctx.send_command(name, &UCSI_UUID, DOORBELL, &mailbox)
}

fn check_header(ctx: &mut E2eContext, name: &str, m: &DirectMessagePayload, cci: u32) -> bool {
    let version = m.u16_at(VERSION_OFFSET);
    let got_cci = m.u32_at(CCI_OFFSET);
    log::info!("  {name}: version={version:#06x} cci={got_cci:#010x}");
    if version != VERSION_UCSI_1_2 {
        ctx.fail(name, "VERSION mismatch");
        return false;
    }
    if got_cci != cci {
        ctx.fail(name, "CCI mismatch");
        return false;
    }
    true
}

fn check_message_in(ctx: &mut E2eContext, name: &str, m: &DirectMessagePayload, expected: &[u8]) {
    let got = m.slice(MESSAGE_IN_OFFSET..MESSAGE_IN_OFFSET + expected.len());
    if got == expected {
        ctx.pass(name);
    } else {
        log::error!("  {name}: MESSAGE IN mismatch got={got:02x?} expected={expected:02x?}");
        ctx.fail(name, "MESSAGE IN mismatch");
    }
}

fn test_get_capability(ctx: &mut E2eContext) {
    const NAME: &str = "ucsi_get_capability";
    let Some(m) = ucsi_call(ctx, NAME, OP_GET_CAPABILITY, 0) else {
        return;
    };
    if check_header(ctx, NAME, &m, CCI_CAPABILITY) {
        check_message_in(ctx, NAME, &m, &CAPABILITY_MESSAGE_IN);
    }
}

fn test_get_connector_capability(ctx: &mut E2eContext) {
    const NAME: &str = "ucsi_get_connector_capability";
    let Some(m) = ucsi_call(ctx, NAME, OP_GET_CONNECTOR_CAPABILITY, CONNECTOR_ONE) else {
        return;
    };
    if check_header(ctx, NAME, &m, CCI_CONNECTOR_CAPABILITY) {
        check_message_in(ctx, NAME, &m, &CONNECTOR_CAPABILITY_MESSAGE_IN);
    }
}

fn test_get_connector_status(ctx: &mut E2eContext) {
    const NAME: &str = "ucsi_get_connector_status";
    let Some(m) = ucsi_call(ctx, NAME, OP_GET_CONNECTOR_STATUS, CONNECTOR_ONE) else {
        return;
    };
    if check_header(ctx, NAME, &m, CCI_CONNECTOR_STATUS) {
        check_message_in(ctx, NAME, &m, &CONNECTOR_STATUS_MESSAGE_IN);
    }
}
