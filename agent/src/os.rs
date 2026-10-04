use serde::Serialize;

/// The OS this agent booted under, so the app can show which side of a
/// dual-boot machine is up. Read once at startup; it can't change while the
/// agent runs.
#[derive(Serialize, Clone)]
pub struct OsInfo {
    /// `linux`, `windows` or `macos`: the agent's compile target, which is
    /// necessarily the running OS.
    family: &'static str,
    /// Human-readable release, e.g. "Manjaro Linux 26.0.1" or
    /// "Windows 11 Pro 25H2".
    name: Option<String>,
    /// Kernel version, e.g. "7.1.13-2-MANJARO" or "10.0.26200".
    kernel: Option<String>,
}

pub fn read() -> OsInfo {
    OsInfo {
        family: std::env::consts::OS,
        name: release_name(),
        kernel: kernel_version(),
    }
}

#[cfg(not(windows))]
fn release_name() -> Option<String> {
    use sysinfo::System;
    let name = System::name()?;
    Some(match System::os_version() {
        Some(version) => format!("{name} {version}"),
        None => name,
    })
}

#[cfg(not(windows))]
fn kernel_version() -> Option<String> {
    sysinfo::System::kernel_version()
}

// sysinfo gives Windows only the product name and build number, so read the
// feature update ("25H2") and the NT version straight from the registry.
#[cfg(windows)]
fn current_version_key() -> Option<winreg::RegKey> {
    winreg::RegKey::predef(winreg::enums::HKEY_LOCAL_MACHINE)
        .open_subkey(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion")
        .ok()
}

#[cfg(windows)]
fn release_name() -> Option<String> {
    let product = sysinfo::System::long_os_version()?;
    let feature: Option<String> = current_version_key()?.get_value("DisplayVersion").ok();
    Some(match feature {
        Some(feature) => format!("{product} {feature}"),
        None => product,
    })
}

#[cfg(windows)]
fn kernel_version() -> Option<String> {
    let key = current_version_key()?;
    let major: u32 = key.get_value("CurrentMajorVersionNumber").ok()?;
    let minor: u32 = key.get_value("CurrentMinorVersionNumber").ok()?;
    let build: String = key.get_value("CurrentBuildNumber").ok()?;
    Some(format!("{major}.{minor}.{build}"))
}
