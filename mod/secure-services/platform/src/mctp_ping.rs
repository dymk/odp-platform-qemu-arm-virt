//! Boot-time MCTP ping helper.
//!
//! Sends one Battery::GetSta request to the EC over the SBSA secure UART and
//! logs exactly one of:
//!   - `MCTP_PING_OK service_id=8 msg_id=<n> is_error=<0|1>`
//!   - `MCTP_PING_FAIL <reason>`
//!
//! Where `<reason>` is one of the [`MctpPingError`] `Display` strings:
//! `"timeout"`, `"framer_encode_error"`, `"framer_decode_error"`. The CI
//! harness (`scripts/test-serial.sh`) greps for these literal markers, so
//! the [`core::fmt::Display`] impl on [`MctpPingError`] is the contract.

use core::fmt;

use qemu_sp_uart::{Error as UartError, Mmio, Pl011Uart};
use sp_mctp_framer::{decode_response, encode_request};

/// MCTP service id for the Battery service. Used both as the destination
/// MCTP endpoint ID for outbound requests and to gate the ACCEPT decision
/// on the decoded reply — any well-formed frame whose `service_id` differs
/// from this value is treated as a decode error.
const BATTERY_SERVICE_ID: u8 = 8;

/// Battery::GetSta message id (matches the `BatteryService::GetSta`
/// discriminant on the EC side; captured wire byte 12 = 0x0f = 15).
const BATTERY_GETSTA_MSG_ID: u16 = 15;

/// First-byte RX iteration budget.
///
/// In production this is `u32::MAX` because [`Pl011Uart::read_byte_timeout`]
/// is a busy-spin (no timer); on QEMU SBSA an EC round-trip takes seconds of
/// wall-clock and the smaller [`NTH_BYTE_BUDGET`] would always exhaust before
/// the first byte arrives. Once the first byte lands, subsequent bytes are
/// emitted back-to-back and the smaller per-byte budget suffices.
///
/// Under `#[cfg(test)]` we shrink the budget so the timeout-branch unit test
/// runs in milliseconds rather than seconds.
#[cfg(not(test))]
const FIRST_BYTE_BUDGET: u32 = u32::MAX;
#[cfg(test)]
const FIRST_BYTE_BUDGET: u32 = 1_000;

/// Subsequent-byte RX iteration budget.
///
/// Sized for "EC is actively transmitting"; once we've seen byte 0 we expect
/// the rest of the frame within a few hundred PL011 polls. This is the same
/// value as `qemu-sp-uart::DEFAULT_RX_TIMEOUT_ITERS` (1M iterations ≈ a few
/// milliseconds of QEMU wall-clock — long enough that legitimate jitter
/// between bytes won't trip it, short enough that a stalled EC fails fast).
const NTH_BYTE_BUDGET: u32 = qemu_sp_uart::DEFAULT_RX_TIMEOUT_ITERS;

/// Lifetime-free copy of the framer-decoded fields surfaced in the OK marker.
///
/// We avoid returning `OdpRelayResponse<'_>` directly because that would
/// borrow from the caller's stack RX buffer, complicating composition with
/// `log::info!` argument capture. The three fields below are the full
/// contract emitted by the OK log line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodedFields {
    pub service_id: u8,
    pub is_error: bool,
    pub message_id: u16,
}

/// Reasons a ping attempt can fail. The [`Display`] impl produces the exact
/// strings the CI harness greps for in the `MCTP_PING_FAIL` log line —
/// changing those strings is a contract change.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum MctpPingError {
    /// `Pl011Uart::read_byte_timeout` exhausted its iteration budget without
    /// seeing the next expected byte.
    Timeout,
    /// `sp_mctp_framer::encode_request` rejected the request.
    /// Typically a buffer-sizing or mctp-rs version-drift bug, not a wire
    /// fault.
    FramerEncode,
    /// `sp_mctp_framer::decode_response` rejected the reply, OR the
    /// reply decoded cleanly but did not target the Battery service.
    FramerDecode,
}

impl fmt::Display for MctpPingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Timeout => "timeout",
            Self::FramerEncode => "framer_encode_error",
            Self::FramerDecode => "framer_decode_error",
        })
    }
}

/// Public entry. Logs internally; never panics.
///
/// `log::error!` is used (not `info!`) because a `MCTP_PING_FAIL` is a
/// harness-level test failure — the CI gate fails on its presence.
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

/// Test-friendly inner helper. Returns one of the three [`MctpPingError`]
/// variants on failure.
fn try_send_mctp_ping<M: Mmio>(
    uart: &mut Pl011Uart<M>,
    battery_id: u8,
) -> Result<DecodedFields, MctpPingError> {
    // 1. Encode the GetSta request.
    let mut tx = [0u8; 32];
    let n = encode_request(&mut tx, BATTERY_SERVICE_ID, BATTERY_GETSTA_MSG_ID, &[battery_id])
        .map_err(|_| MctpPingError::FramerEncode)?;

    // 2. Transmit (cannot fail — Pl011Uart::write_bytes returns ()).
    uart.write_bytes(&tx[..n]);

    // 3. Read first byte with the LONG budget.
    let mut rx = [0u8; 32];
    rx[0] = uart
        .read_byte_timeout(FIRST_BYTE_BUDGET)
        .map_err(|UartError::Timeout| MctpPingError::Timeout)?;

    // 4. Read header bytes [1..4) so we can derive total length per the
    //    framer rule: needed = 4 + rx[2] (SmbusEspi byte_count field).
    for slot in rx.iter_mut().take(4).skip(1) {
        *slot = uart
            .read_byte_timeout(NTH_BYTE_BUDGET)
            .map_err(|UartError::Timeout| MctpPingError::Timeout)?;
    }
    let needed = 4 + rx[2] as usize;
    if needed > rx.len() {
        // Pathological wire-claimed length — surface as decode error. Note
        // this also subsumes the FIFO state for the in-flight bytes; the
        // caller (boot-time, one-shot) does not retry, so we don't drain.
        return Err(MctpPingError::FramerDecode);
    }

    // 5. Read the rest of the frame.
    for slot in rx.iter_mut().take(needed).skip(4) {
        *slot = uart
            .read_byte_timeout(NTH_BYTE_BUDGET)
            .map_err(|UartError::Timeout| MctpPingError::Timeout)?;
    }

    // 6. Decode and gate on `service_id == BATTERY_SERVICE_ID` AND
    //    `is_request == false` (we expect a response, not an echoed
    //    request). Either mismatch surfaces as a decode error.
    let resp = decode_response(&rx[..needed]).map_err(|_| MctpPingError::FramerDecode)?;
    if resp.is_request {
        return Err(MctpPingError::FramerDecode);
    }
    if resp.service_id != BATTERY_SERVICE_ID {
        return Err(MctpPingError::FramerDecode);
    }
    Ok(DecodedFields {
        service_id: resp.service_id,
        is_error: resp.is_error,
        message_id: resp.message_id,
    })
}

// ---------------------------------------------------------------------------
// Host unit tests. Run with:
//   cd mod/secure-services/platform && \
//     cargo test --bin qemu-ec-sp --target x86_64-unknown-linux-gnu
//
// MockMmio uses the `Pl011Uart::mmio()` accessor (test-only convenience on
// the driver) so the test can read the TX log and adjust the RXFE pattern
// after the mock has been moved into `Pl011Uart::new(_)` — matches the
// pattern used by `qemu-sp-uart`'s own tests.
// ---------------------------------------------------------------------------
#[cfg(test)]
extern crate std;

#[cfg(test)]
mod tests {
    use super::*;
    use qemu_sp_uart::{FR_RXFE, UARTDR, UARTFR};
    use sp_mctp_framer::test_fixtures::{PHASE_12_RX_13B, PHASE_12_TX_18B};
    use std::cell::RefCell;
    use std::collections::VecDeque;
    use std::vec::Vec;

    /// Mock MMIO backend. Mirrors `qemu-sp-uart`'s test mock: state lives
    /// inside `RefCell`s on the mock itself, accessed through
    /// `Pl011Uart::mmio()` (cfg(test)-only accessor).
    struct MockMmio {
        rx_queue: RefCell<VecDeque<u8>>,
        /// Optional scripted UARTFR pattern. When non-empty, each
        /// `read32(UARTFR)` pops one value (returning the default once
        /// exhausted). When empty, falls back to the rxfe-from-queue rule.
        fr_script: RefCell<VecDeque<u32>>,
        tx_log: RefCell<Vec<u8>>,
    }
    impl MockMmio {
        fn new(rx: &[u8]) -> Self {
            Self {
                rx_queue: RefCell::new(rx.iter().copied().collect()),
                fr_script: RefCell::new(VecDeque::new()),
                tx_log: RefCell::new(Vec::new()),
            }
        }
        fn with_fr_script(rx: &[u8], script: &[u32]) -> Self {
            Self {
                rx_queue: RefCell::new(rx.iter().copied().collect()),
                fr_script: RefCell::new(script.iter().copied().collect()),
                tx_log: RefCell::new(Vec::new()),
            }
        }
        fn tx_bytes(&self) -> Vec<u8> {
            self.tx_log.borrow().clone()
        }
    }
    impl Mmio for MockMmio {
        unsafe fn read32(&self, off: usize) -> u32 {
            assert_eq!(off, UARTFR, "MockMmio only models UARTFR for read32");
            // Scripted pattern wins (used to model TXFF back-pressure).
            if let Some(v) = self.fr_script.borrow_mut().pop_front() {
                return v;
            }
            // Fallback: RXFE clear iff queue non-empty; TXFF always clear.
            if self.rx_queue.borrow().is_empty() {
                FR_RXFE
            } else {
                0
            }
        }
        unsafe fn read8(&self, off: usize) -> u8 {
            assert_eq!(off, UARTDR);
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

    #[test]
    fn ok_path_emits_correct_decoded_fields_and_writes_18_byte_tx() {
        let mock = MockMmio::new(&PHASE_12_RX_13B);
        let mut uart = Pl011Uart::new(mock);
        let result = try_send_mctp_ping(&mut uart, /* battery_id = */ 0);
        assert!(result.is_ok(), "expected Ok, got {result:?}");
        let fields = result.unwrap();
        assert_eq!(fields.service_id, BATTERY_SERVICE_ID);
        assert_eq!(fields.message_id, 1, "captured RX has message_id=1");
        assert!(fields.is_error, "captured RX has is_error=1");
        // TX-log must equal the captured 18-byte golden fixture exactly.
        assert_eq!(
            uart.mmio_for_test().tx_bytes(),
            PHASE_12_TX_18B.to_vec(),
            "TX log mismatch vs captured wire bytes"
        );
    }

    #[test]
    fn pathological_byte_count_returns_decode_error_and_does_not_swallow_tx() {
        // 13 bytes of 0xFF: byte_count = 0xFF → needed = 4 + 255 = 259, our
        // internal rx buffer is 32 → triggers the explicit pathological-
        // length guard BEFORE `decode_response` is called. The TX
        // log must STILL contain the encoded request — a regression where
        // the decode-failure path also dropped TX would be caught here.
        let garbage = [0xFFu8; 13];
        let mock = MockMmio::new(&garbage);
        let mut uart = Pl011Uart::new(mock);
        let result = try_send_mctp_ping(&mut uart, 0);
        assert_eq!(result, Err(MctpPingError::FramerDecode));
        assert_eq!(
            uart.mmio_for_test().tx_bytes(),
            PHASE_12_TX_18B.to_vec(),
            "TX should have been emitted before RX failure"
        );
    }

    #[test]
    fn decoder_rejects_corrupt_but_length_coherent_frame() {
        // Length-coherent (4-byte header, byte_count=0 → needed=4), but the
        // first 4 bytes are not a valid SmbusEspi header. mctp-rs's
        // deserializer rejects → mapped to FramerDecode by the
        // framer-error branch (NOT the pathological-length guard).
        let broken: [u8; 4] = [0x00, 0x00, 0x00, 0x00];
        let mock = MockMmio::new(&broken);
        let mut uart = Pl011Uart::new(mock);
        let result = try_send_mctp_ping(&mut uart, 0);
        assert_eq!(result, Err(MctpPingError::FramerDecode));
    }

    #[test]
    fn decoder_rejects_response_with_wrong_service_id() {
        // Take the captured Battery RX and flip the ODP service-id byte to
        // 0x02 (Thermal). This produces a wire-correct, mctp-rs-parseable
        // frame whose decoded `service_id != BATTERY_SERVICE_ID`. Catches a
        // regression where the gate at the bottom of `try_send_mctp_ping`
        // is removed or inverted.
        let mut frame = PHASE_12_RX_13B;
        frame[10] = 0x02; // ODP relay header byte 1 = service_id
        let mock = MockMmio::new(&frame);
        let mut uart = Pl011Uart::new(mock);
        let result = try_send_mctp_ping(&mut uart, 0);
        assert_eq!(result, Err(MctpPingError::FramerDecode));
    }

    #[test]
    fn decoder_rejects_echoed_request_frame() {
        // Feed back the SP's own request bytes. is_request=1 → SP must
        // refuse to treat its own outbound frame as a reply.
        let mock = MockMmio::new(&PHASE_12_TX_18B);
        let mut uart = Pl011Uart::new(mock);
        let result = try_send_mctp_ping(&mut uart, 0);
        assert_eq!(result, Err(MctpPingError::FramerDecode));
    }

    #[test]
    fn timeout_when_rx_queue_empty() {
        let mock = MockMmio::new(&[]);
        let mut uart = Pl011Uart::new(mock);
        let result = try_send_mctp_ping(&mut uart, 0);
        assert_eq!(result, Err(MctpPingError::Timeout));
    }

    #[test]
    fn write_path_polls_txff_until_clear() {
        // Script UARTFR to report TXFF=set for the first 2 polls of each TX
        // byte, then clear, repeated for all 18 bytes. Confirms the driver
        // honors back-pressure rather than blindly stuffing bytes (mock TXFF
        // model gap flagged in code review T-5).
        const FR_TXFF: u32 = 1 << 5;
        let mut script = Vec::new();
        for _ in 0..PHASE_12_TX_18B.len() {
            script.push(FR_TXFF);
            script.push(FR_TXFF);
            script.push(0); // clear → write proceeds
        }
        // After TX, fall back to the queue-driven RXFE rule so the read
        // path can complete normally with the captured RX bytes.
        let mock = MockMmio::with_fr_script(&PHASE_12_RX_13B, &script);
        let mut uart = Pl011Uart::new(mock);
        let result = try_send_mctp_ping(&mut uart, 0);
        assert!(result.is_ok(), "expected Ok with TXFF back-pressure, got {result:?}");
        assert_eq!(uart.mmio_for_test().tx_bytes(), PHASE_12_TX_18B.to_vec());
    }

    #[test]
    fn display_strings_match_harness_contract() {
        // The CI harness greps for these literal substrings — pin them.
        use std::format;
        assert_eq!(format!("{}", MctpPingError::Timeout), "timeout");
        assert_eq!(format!("{}", MctpPingError::FramerEncode), "framer_encode_error");
        assert_eq!(format!("{}", MctpPingError::FramerDecode), "framer_decode_error");
    }
}
