use std::fmt;

const PASS_LINE: &str = "PASS: Windows ACPI E2E";
const INPUT_SIGNATURE: &[u8; 4] = b"AeiF";
const OUTPUT_SIGNATURE: &[u8; 4] = b"AeoB";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EvalError {
    InvalidMethod,
    DeviceNotFound,
    InvalidOutput,
    Windows(i32),
    UnsupportedPlatform,
}

impl fmt::Display for EvalError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidMethod => formatter.write_str("invalid absolute ACPI method"),
            Self::DeviceNotFound => formatter.write_str("ectest device not found"),
            Self::InvalidOutput => formatter.write_str("unexpected ACPI output buffer"),
            Self::Windows(code) => write!(formatter, "Windows error {code:#x}"),
            Self::UnsupportedPlatform => formatter.write_str("Windows is required"),
        }
    }
}

impl std::error::Error for EvalError {}

pub fn run(test: impl FnOnce() -> Result<(), String>) {
    let message = result_message(test());

    #[cfg(target_os = "windows")]
    {
        use std::fs::{OpenOptions, create_dir_all, write};
        use std::io::Write as _;
        use std::process::Command;

        let _ = create_dir_all(r"C:\odp-e2e");
        let _ = write(r"C:\odp-e2e\result.txt", &message);
        if let Ok(mut serial) = OpenOptions::new().write(true).open(r"\\.\COM1") {
            let _ = serial.write_all(message.as_bytes());
        }
        let _ = Command::new("shutdown")
            .args(["/s", "/f", "/t", "5"])
            .status();
    }

    #[cfg(not(target_os = "windows"))]
    let _ = message;
}

fn result_message(result: Result<(), String>) -> String {
    match result {
        Ok(()) => format!("{PASS_LINE}\n"),
        Err(error) => format!("FAIL: {error}\n"),
    }
}

pub fn evaluate_u32(absolute_method: &str) -> Result<u32, EvalError> {
    let input = encode_method_input(absolute_method)?;
    evaluate_input(&input).and_then(|output| parse_u32_output(&output))
}

fn encode_method_input(method: &str) -> Result<Vec<u8>, EvalError> {
    let method = method.as_bytes();
    if method.first() != Some(&b'\\')
        || method.len() > 255
        || !method.is_ascii()
        || method.contains(&0)
    {
        return Err(EvalError::InvalidMethod);
    }

    let mut input = vec![0u8; 268];
    input[..4].copy_from_slice(INPUT_SIGNATURE);
    input[4..4 + method.len()].copy_from_slice(method);
    Ok(input)
}

fn parse_u32_output(output: &[u8]) -> Result<u32, EvalError> {
    if output.len() < 20 || &output[..4] != OUTPUT_SIGNATURE {
        return Err(EvalError::InvalidOutput);
    }
    let declared_length = read_u32(output, 4)? as usize;
    let count = read_u32(output, 8)?;
    let argument_type = read_u16(output, 12)?;
    let data_length = read_u16(output, 14)?;
    if declared_length < 20
        || declared_length > output.len()
        || count != 1
        || argument_type != 0
        || data_length != 4
    {
        return Err(EvalError::InvalidOutput);
    }
    read_u32(output, 16)
}

fn read_u16(buffer: &[u8], offset: usize) -> Result<u16, EvalError> {
    let bytes = buffer
        .get(offset..offset + 2)
        .ok_or(EvalError::InvalidOutput)?;
    Ok(u16::from_le_bytes(
        bytes.try_into().map_err(|_| EvalError::InvalidOutput)?,
    ))
}

fn read_u32(buffer: &[u8], offset: usize) -> Result<u32, EvalError> {
    let bytes = buffer
        .get(offset..offset + 4)
        .ok_or(EvalError::InvalidOutput)?;
    Ok(u32::from_le_bytes(
        bytes.try_into().map_err(|_| EvalError::InvalidOutput)?,
    ))
}

#[cfg(target_os = "windows")]
fn evaluate_input(input: &[u8]) -> Result<Vec<u8>, EvalError> {
    use windows::Win32::Foundation::{CloseHandle, GENERIC_READ, GENERIC_WRITE, HANDLE};
    use windows::Win32::Storage::FileSystem::{
        CreateFileW, FILE_FLAGS_AND_ATTRIBUTES, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
    };
    use windows::Win32::System::IO::DeviceIoControl;
    use windows::core::PCWSTR;

    const IOCTL_ACPI_EVAL_METHOD_EX: u32 = 0x0032_C018;

    struct OwnedHandle(HANDLE);

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            let _ = unsafe { CloseHandle(self.0) };
        }
    }

    let path = find_device_path()?;
    let wide_path: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
    let handle = unsafe {
        CreateFileW(
            PCWSTR::from_raw(wide_path.as_ptr()),
            (GENERIC_READ | GENERIC_WRITE).0,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            None,
            OPEN_EXISTING,
            FILE_FLAGS_AND_ATTRIBUTES(0),
            None,
        )
    }
    .map_err(|error| EvalError::Windows(error.code().0))?;
    if handle.is_invalid() {
        return Err(EvalError::DeviceNotFound);
    }
    let handle = OwnedHandle(handle);

    let mut output = vec![0u8; 1024];
    let mut bytes_returned = 0u32;
    unsafe {
        DeviceIoControl(
            handle.0,
            IOCTL_ACPI_EVAL_METHOD_EX,
            Some(input.as_ptr().cast()),
            u32::try_from(input.len()).map_err(|_| EvalError::InvalidMethod)?,
            Some(output.as_mut_ptr().cast()),
            u32::try_from(output.len()).map_err(|_| EvalError::InvalidOutput)?,
            Some(&mut bytes_returned),
            None,
        )
    }
    .map_err(|error| EvalError::Windows(error.code().0))?;
    output.truncate(bytes_returned as usize);
    Ok(output)
}

#[cfg(target_os = "windows")]
fn find_device_path() -> Result<String, EvalError> {
    use windows::Win32::Devices::DeviceAndDriverInstallation::{
        DIGCF_PRESENT, HDEVINFO, SP_DEVINFO_DATA, SetupDiDestroyDeviceInfoList,
        SetupDiEnumDeviceInfo, SetupDiGetClassDevsW, SetupDiGetDevicePropertyW,
    };
    use windows::Win32::Devices::Properties::{
        DEVPKEY_Device_InstanceId, DEVPKEY_Device_PDOName, DEVPROPTYPE,
    };
    use windows::Win32::Foundation::HWND;
    use windows::core::{GUID, PCWSTR};

    const DEVICE_CLASS: GUID = GUID::from_values(
        0x5362_ad97,
        0xddfe,
        0x429d,
        [0x93, 0x05, 0x31, 0xc0, 0xad, 0x27, 0x88, 0x0a],
    );

    struct OwnedDeviceInfo(HDEVINFO);

    impl Drop for OwnedDeviceInfo {
        fn drop(&mut self) {
            let _ = unsafe { SetupDiDestroyDeviceInfoList(self.0) };
        }
    }

    fn property(
        set: HDEVINFO,
        data: &SP_DEVINFO_DATA,
        key: &windows::Win32::Devices::Properties::DEVPROPKEY,
    ) -> Option<String> {
        let mut buffer = [0u16; 512];
        let mut required_size = 0u32;
        let mut property_type = DEVPROPTYPE(0);
        unsafe {
            SetupDiGetDevicePropertyW(
                set,
                data,
                key,
                &mut property_type,
                Some(std::slice::from_raw_parts_mut(
                    buffer.as_mut_ptr().cast(),
                    buffer.len() * 2,
                )),
                Some(&mut required_size),
                0,
            )
        }
        .ok()?;
        let units = usize::try_from(required_size).ok()?.checked_div(2)?;
        let units = units.checked_sub(1)?;
        Some(String::from_utf16_lossy(buffer.get(..units)?))
    }

    let set = unsafe {
        SetupDiGetClassDevsW(
            Some(&DEVICE_CLASS),
            PCWSTR::null(),
            HWND::default(),
            DIGCF_PRESENT,
        )
    }
    .map_err(|error| EvalError::Windows(error.code().0))?;
    let set = OwnedDeviceInfo(set);

    let mut index = 0;
    loop {
        let mut data = SP_DEVINFO_DATA {
            cbSize: std::mem::size_of::<SP_DEVINFO_DATA>() as u32,
            ..Default::default()
        };
        if unsafe { SetupDiEnumDeviceInfo(set.0, index, &mut data) }.is_err() {
            break;
        }
        if property(set.0, &data, &DEVPKEY_Device_InstanceId)
            .is_some_and(|instance| instance.contains("ETST0001"))
            && let Some(pdo_name) = property(set.0, &data, &DEVPKEY_Device_PDOName)
        {
            return Ok(format!(r"\\.\GLOBALROOT{pdo_name}"));
        }
        index += 1;
    }
    Err(EvalError::DeviceNotFound)
}

#[cfg(not(target_os = "windows"))]
fn evaluate_input(_input: &[u8]) -> Result<Vec<u8>, EvalError> {
    Err(EvalError::UnsupportedPlatform)
}

#[cfg(test)]
mod tests {
    use super::{EvalError, encode_method_input, parse_u32_output, result_message};

    fn integer_output(value: u32) -> Vec<u8> {
        let mut output = Vec::new();
        output.extend_from_slice(b"AeoB");
        output.extend_from_slice(&20u32.to_le_bytes());
        output.extend_from_slice(&1u32.to_le_bytes());
        output.extend_from_slice(&0u16.to_le_bytes());
        output.extend_from_slice(&4u16.to_le_bytes());
        output.extend_from_slice(&value.to_le_bytes());
        output
    }

    #[test]
    fn parses_one_integer_result() {
        assert_eq!(
            parse_u32_output(&integer_output(0x1234_5678)),
            Ok(0x1234_5678)
        );
    }

    #[test]
    fn rejects_truncated_output_without_panicking() {
        for length in 0..20 {
            assert_eq!(
                parse_u32_output(&integer_output(7)[..length]),
                Err(EvalError::InvalidOutput)
            );
        }
    }

    #[test]
    fn rejects_wrong_count_type_and_length() {
        let mut output = integer_output(7);
        output[8..12].copy_from_slice(&2u32.to_le_bytes());
        assert_eq!(parse_u32_output(&output), Err(EvalError::InvalidOutput));

        let mut output = integer_output(7);
        output[12..14].copy_from_slice(&2u16.to_le_bytes());
        assert_eq!(parse_u32_output(&output), Err(EvalError::InvalidOutput));

        let mut output = integer_output(7);
        output[14..16].copy_from_slice(&8u16.to_le_bytes());
        assert_eq!(parse_u32_output(&output), Err(EvalError::InvalidOutput));
    }

    #[test]
    fn encodes_no_argument_absolute_method() {
        let input = encode_method_input(r"\_SB.ECT0.TEST").unwrap();
        assert_eq!(&input[..4], b"AeiF");
        assert_eq!(&input[4..18], br"\_SB.ECT0.TEST");
        assert_eq!(&input[260..264], &0u32.to_le_bytes());
        assert_eq!(&input[264..268], &0u32.to_le_bytes());
    }

    #[test]
    fn rejects_relative_empty_nul_and_oversized_methods() {
        for method in ["", "TEST", "\\BAD\0NAME"] {
            assert_eq!(encode_method_input(method), Err(EvalError::InvalidMethod));
        }
        let oversized = format!(r"\{}", "A".repeat(256));
        assert_eq!(
            encode_method_input(&oversized),
            Err(EvalError::InvalidMethod)
        );
    }

    #[test]
    fn formats_standardized_results() {
        assert_eq!(result_message(Ok(())), "PASS: Windows ACPI E2E\n");
        assert_eq!(
            result_message(Err("proof failed".to_string())),
            "FAIL: proof failed\n"
        );
    }
}
