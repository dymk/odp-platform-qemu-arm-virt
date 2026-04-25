//! Phase 16 boot-time MCTP ping (D-1, D-3 AMENDED, D-13).
//!
//! Sends one Battery::GetSta request to the EC over the SBSA secure UART and
//! logs exactly one of:
//!   - `MCTP_PING_OK service_id=8 msg_id=<n> is_error=<0|1>`  (D-2 AMENDED)
//!   - `MCTP_PING_FAIL <reason>`  where <reason> ∈ {timeout, framer_encode_error, framer_decode_error}
//!
//! See `.planning/phases/16-ping-pong-end-to-end/16-CONTEXT.md` for locked
//! decisions. Helper is host-testable via `MockMmio` (Phase 14 pattern); see
//! the `#[cfg(test)] mod tests` block below.

use qemu_sp_uart::{Error as UartError, Mmio, Pl011Uart};
use sp_mctp_framer::{decode_battery_response, encode_battery_request};

/// First-byte RX budget. In production, MUST be `u32::MAX` per Phase 14
/// carry-forward (`DEFAULT_RX_TIMEOUT_ITERS` of 1_000_000 exhausts in
/// milliseconds on QEMU SBSA before the EC even gets to TX). Under
/// `#[cfg(test)]` we shrink to keep the timeout-branch test sub-second on
/// host (M-2 minor recommendation in 16-02-PLAN).
#[cfg(not(test))]
const FIRST_BYTE_BUDGET: u32 = u32::MAX;
#[cfg(test)]
const FIRST_BYTE_BUDGET: u32 = 1_000;

/// Subsequent-byte RX budget. EC is actively transmitting → small budget OK.
const NTH_BYTE_BUDGET: u32 = 1_000_000;

/// Owned, lifetime-free copy of the framer-decoded fields we surface in the
/// OK marker. We don't return `BatteryResponse<'_>` directly to avoid
/// borrowing the rx buffer (RESEARCH §3 lifetime caveat).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodedFields {
    pub service_id: u8,
    pub is_error: bool,
    pub message_id: u16,
}

/// Public entry. Logs internally; never panics.
pub fn send_mctp_ping<M: Mmio>(uart: &mut Pl011Uart<M>, battery_id: u8) {
    match try_send_mctp_ping(uart, battery_id) {
        Ok(fields) => log::info!(
            "MCTP_PING_OK service_id={} msg_id={} is_error={}",
            fields.service_id,
            fields.message_id,
            fields.is_error as u8
        ),
        Err(reason) => log::error!("MCTP_PING_FAIL {}", reason),
    }
}

/// Test-friendly inner helper. Returns one of the 3 D-3 (AMENDED) reason
/// strings on Err: `"timeout"`, `"framer_encode_error"`, `"framer_decode_error"`.
fn try_send_mctp_ping<M: Mmio>(
    uart: &mut Pl011Uart<M>,
    battery_id: u8,
) -> Result<DecodedFields, &'static str> {
    // 1. Encode the GetSta request.
    let mut tx = [0u8; 32];
    let n = encode_battery_request(&mut tx, battery_id).map_err(|_| "framer_encode_error")?;

    // 2. Transmit (cannot fail — Pl011Uart::write_bytes returns ()).
    uart.write_bytes(&tx[..n]);

    // 3. Read first byte with the LONG budget.
    let mut rx = [0u8; 32];
    rx[0] = uart
        .read_byte_timeout(FIRST_BYTE_BUDGET)
        .map_err(|UartError::Timeout| "timeout")?;

    // 4. Read header bytes [1..4) so we can derive total length per framer
    //    rule: needed = 4 + rx[2] (sp-mctp-framer/src/lib.rs:204-205).
    for slot in rx.iter_mut().take(4).skip(1) {
        *slot = uart
            .read_byte_timeout(NTH_BYTE_BUDGET)
            .map_err(|UartError::Timeout| "timeout")?;
    }
    let needed = 4 + rx[2] as usize;
    if needed > rx.len() {
        // Pathological length — surface as decode error.
        return Err("framer_decode_error");
    }

    // 5. Read the rest of the frame.
    for slot in rx.iter_mut().take(needed).skip(4) {
        *slot = uart
            .read_byte_timeout(NTH_BYTE_BUDGET)
            .map_err(|UartError::Timeout| "timeout")?;
    }

    // 6. Decode and gate solely on service_id == 8 (Battery), per D-2 AMENDED.
    let resp = decode_battery_response(&rx[..needed]).map_err(|_| "framer_decode_error")?;
    if resp.service_id != 8 {
        return Err("framer_decode_error");
    }
    Ok(DecodedFields {
        service_id: resp.service_id,
        is_error: resp.is_error,
        message_id: resp.message_id,
    })
}

// ---------------------------------------------------------------------------
// Host unit tests (D-11). Run with:
//   cd mod/secure-services/platform && \
//     cargo test --bin qemu-ec-sp --target x86_64-unknown-linux-gnu
//
// MockMmio pattern adapted from qemu-sp-uart/src/lib.rs:160-228 (Phase 14):
// `read*` are `&self` on the Mmio trait, so all interior state lives in
// `RefCell`. We additionally wrap `tx_log` in `Rc<RefCell<_>>` so the test
// can read it after the mock is moved into `Pl011Uart::new(_)`.
// ---------------------------------------------------------------------------
#[cfg(test)]
extern crate std;

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::VecDeque;
    use std::rc::Rc;
    use std::vec::Vec;

    // PL011 register offsets — keep in sync with qemu-sp-uart's internals.
    const UARTDR: usize = 0x000;
    const UARTFR: usize = 0x018;
    // UARTFR flag bits we care about:
    //   RXFE (bit 4 = 0x10): RX FIFO empty
    //   TXFF (bit 5 = 0x20): TX FIFO full (we always report 0 — never full)
    const FR_RXFE: u32 = 1 << 4;

    struct MockMmio {
        rx_queue: RefCell<VecDeque<u8>>,
        tx_log: Rc<RefCell<Vec<u8>>>,
    }
    impl MockMmio {
        fn new(rx: &[u8], tx_log: Rc<RefCell<Vec<u8>>>) -> Self {
            Self {
                rx_queue: RefCell::new(rx.iter().copied().collect()),
                tx_log,
            }
        }
    }
    impl Mmio for MockMmio {
        unsafe fn read32(&self, off: usize) -> u32 {
            assert_eq!(off, UARTFR, "MockMmio only models UARTFR for read32");
            // RXFE clear (data available) iff queue non-empty; TXFF always clear.
            if self.rx_queue.borrow().is_empty() {
                FR_RXFE
            } else {
                0
            }
        }
        unsafe fn read8(&self, off: usize) -> u8 {
            assert_eq!(off, UARTDR);
            // Pl011Uart reads UARTDR only after observing RXFE=0 (queue
            // non-empty). Pop the next byte; panic if empty (bug).
            self.rx_queue
                .borrow_mut()
                .pop_front()
                .expect("read8(UARTDR) called with empty rx_queue — driver bug")
        }
        unsafe fn write8(&mut self, off: usize, val: u8) {
            assert_eq!(off, UARTDR);
            self.tx_log.borrow_mut().push(val);
        }
    }

    // Phase 12 golden TX fixture (18 bytes, D-11 + RESEARCH §2.2).
    const PHASE_12_TX: [u8; 18] = [
        0x00, 0x0f, 0x0e, 0x03, 0x01, 0x08, 0x80, 0xd3, 0x7d, 0x02, 0x08, 0x00, 0x0f, 0x02, 0x08,
        0x00, 0x0f, 0x00,
    ];
    // Phase 12 golden RX fixture (13 bytes).
    const PHASE_12_RX: [u8; 13] = [
        0x00, 0x0f, 0x09, 0x03, 0x01, 0x80, 0x08, 0xd3, 0x7d, 0x00, 0x08, 0x80, 0x01,
    ];

    fn fresh_mock(rx: &[u8]) -> (MockMmio, Rc<RefCell<Vec<u8>>>) {
        let tx_log = Rc::new(RefCell::new(Vec::new()));
        let mock = MockMmio::new(rx, Rc::clone(&tx_log));
        (mock, tx_log)
    }

    #[test]
    fn ok_path_emits_correct_decoded_fields_and_writes_18_byte_tx() {
        let (mock, tx_log) = fresh_mock(&PHASE_12_RX);
        let mut uart = Pl011Uart::new(mock);
        let result = try_send_mctp_ping(&mut uart, /* battery_id = */ 0);
        assert!(result.is_ok(), "expected Ok, got {:?}", result);
        let fields = result.unwrap();
        assert_eq!(
            fields.service_id, 8,
            "OK gate is service_id==8 per D-2 AMENDED"
        );
        // message_id and is_error are informational only — pin to Phase 12
        // spike values (RX[12]=0x01 → message_id=1; relay flags → is_error=true).
        assert_eq!(
            fields.message_id, 1,
            "Phase 12 spike: EC mock returns message_id=1"
        );
        assert!(
            fields.is_error,
            "Phase 12 spike: EC mock returns is_error=1"
        );
        // TX-log must equal the Phase 12 18-byte golden fixture exactly.
        let tx = tx_log.borrow();
        assert_eq!(
            &tx[..],
            &PHASE_12_TX[..],
            "TX log mismatch vs Phase 12 golden bytes"
        );
    }

    #[test]
    fn decode_error_when_rx_is_garbage() {
        // 13 bytes of 0xFF: byte_count = 0xFF → needed = 4 + 255 = 259, but
        // our internal rx buffer is 32 bytes → triggers the explicit
        // "framer_decode_error" branch on pathological length BEFORE we
        // would call `decode_battery_response`. Either way, mapped to
        // `"framer_decode_error"` per D-3 AMENDED.
        let garbage = [0xFFu8; 13];
        let (mock, _tx) = fresh_mock(&garbage);
        let mut uart = Pl011Uart::new(mock);
        let result = try_send_mctp_ping(&mut uart, 0);
        assert_eq!(result, Err("framer_decode_error"));
    }

    #[test]
    fn decode_error_when_rx_decodes_invalid_frame() {
        // Length-coherent but semantically broken: 4-byte header with
        // byte_count=0 → needed=4, decoder will reject it. Confirms the
        // mapping from FramerError → "framer_decode_error" in the actual
        // decoder branch (not just the pathological-length guard).
        let broken: [u8; 4] = [0x00, 0x00, 0x00, 0x00];
        let (mock, _tx) = fresh_mock(&broken);
        let mut uart = Pl011Uart::new(mock);
        let result = try_send_mctp_ping(&mut uart, 0);
        assert_eq!(result, Err("framer_decode_error"));
    }

    #[test]
    fn timeout_when_rx_queue_empty() {
        // Empty RX queue → RXFE reports set forever → first-byte
        // read_byte_timeout exhausts FIRST_BYTE_BUDGET (1_000 under
        // cfg(test) per M-2) and returns Err(Timeout) → mapped to
        // "timeout" per D-3 AMENDED.
        let (mock, _tx) = fresh_mock(&[]);
        let mut uart = Pl011Uart::new(mock);
        let result = try_send_mctp_ping(&mut uart, 0);
        assert_eq!(result, Err("timeout"));
    }

    // The "framer_encode_error" branch is exercise-by-inspection only.
    // `encode_battery_request` only fails when the output buffer is
    // <18 bytes (BufTooSmall) or mctp-rs internals reject the encode
    // (EncodeFailed). Our caller passes a fixed 32-byte buffer that's
    // always sufficient for the 18-byte GetSta encode. The mapping is
    // covered by the framer's own Phase 15 unit tests.
}
