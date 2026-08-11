#[cfg(not(target_os = "windows"))]
fn main() {
    panic!("UCSI E2E smoke runs only on Windows");
}

#[cfg(target_os = "windows")]
fn main() {
    use ec_test_lib::UcsiSource;
    use ec_test_lib::acpi::Acpi;
    use ec_test_lib::ucsi::{PowerDirection, UcsiVersion};

    windows_acpi_e2e_guest_support::run(|| {
        let source = Acpi::new(0);

        let version = source
            .get_version()
            .map_err(|error| format!("get_version: {error}"))?;
        if version != UcsiVersion(0x0120) {
            return Err(format!("VERSION: expected 0x0120, got {:#06x}", version.0));
        }

        let capability = source
            .get_capability()
            .map_err(|error| format!("get_capability: {error}"))?;
        if capability.num_connectors != 1
            || !capability.attributes.usb_power_delivery()
            || capability.bcd_usb_pd_spec != 0x0300
        {
            return Err(format!("GET_CAPABILITY: {capability:?}"));
        }

        let connector = source
            .get_connector_capability(1)
            .map_err(|error| format!("get_connector_capability: {error}"))?;
        let modes = connector.operation_mode();
        if !modes.drp()
            || !modes.usb2()
            || !modes.usb3()
            || !connector.provider()
            || !connector.consumer()
        {
            return Err(format!("GET_CONNECTOR_CAPABILITY: {connector:?}"));
        }

        let status = source
            .get_connector_status(1)
            .map_err(|error| format!("get_connector_status: {error}"))?;
        let connected = status
            .status
            .ok_or_else(|| format!("GET_CONNECTOR_STATUS disconnected: {status:?}"))?;
        if !status.connect_status
            || !connected.partner_flags.usb()
            || connected.power_direction != PowerDirection::Sink
        {
            return Err(format!("GET_CONNECTOR_STATUS: {status:?}"));
        }

        Ok(())
    });
}
