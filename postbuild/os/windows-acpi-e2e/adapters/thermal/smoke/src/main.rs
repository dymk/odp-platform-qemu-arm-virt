#[cfg(any(target_os = "windows", test))]
fn validate_temperature(temperature: u32) -> Result<(), String> {
    if (2900..=3200).contains(&temperature) {
        Ok(())
    } else {
        Err(format!(
            "temperature {temperature} outside 2900..=3200 deciKelvin"
        ))
    }
}

#[cfg(not(target_os = "windows"))]
fn main() {
    panic!("thermal smoke runs only on Windows");
}

#[cfg(target_os = "windows")]
fn main() {
    windows_acpi_e2e_guest_support::run(|| {
        let temperature = windows_acpi_e2e_guest_support::evaluate_u32(r"\_SB.SKIN._TMP")
            .map_err(|error| error.to_string())?;
        validate_temperature(temperature)
    });
}

#[cfg(test)]
mod tests {
    use super::validate_temperature;

    #[test]
    fn accepts_minimum_temperature() {
        assert_eq!(validate_temperature(2900), Ok(()));
    }

    #[test]
    fn accepts_maximum_temperature() {
        assert_eq!(validate_temperature(3200), Ok(()));
    }

    #[test]
    fn rejects_temperature_below_minimum() {
        assert!(validate_temperature(2899).is_err());
    }

    #[test]
    fn rejects_temperature_above_maximum() {
        assert!(validate_temperature(3201).is_err());
    }
}
