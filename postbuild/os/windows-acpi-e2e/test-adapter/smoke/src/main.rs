#[cfg(not(target_os = "windows"))]
fn main() {
    panic!("fixture smoke runs only on Windows");
}

#[cfg(target_os = "windows")]
fn main() {
    windows_acpi_e2e_guest_support::run(|| {
        let value = windows_acpi_e2e_guest_support::evaluate_u32(r"\_SB.ECT0.TEST")
            .map_err(|error| error.to_string())?;
        if value == 0x1234_5678 {
            Ok(())
        } else {
            Err(format!("expected 0x12345678, got {value:#010x}"))
        }
    });
}
