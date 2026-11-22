//! Opens a web address in the system browser. Feed content chooses these addresses,
//! so only http and https leave the app, as on the Mac (`Links.isSafe`).

use url::Url;

/// The address to hand the system, when it is one the app may open.
pub fn checked(text: &str) -> Option<String> {
    let url = Url::parse(text).ok()?;
    matches!(url.scheme(), "http" | "https").then(|| url.to_string())
}

pub fn open(text: &str) -> Result<(), String> {
    let url = checked(text).ok_or_else(|| "Only web addresses open in the browser".to_string())?;
    launch(&url)
}

#[cfg(windows)]
fn launch(url: &str) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::UI::Shell::ShellExecuteW;
    use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
    let wide = |text: &str| std::ffi::OsStr::new(text).encode_wide().chain(Some(0)).collect::<Vec<u16>>();
    let (verb, target) = (wide("open"), wide(url));
    // ShellExecute hands the address to the default browser; no shell parses it.
    let result = unsafe { ShellExecuteW(std::ptr::null_mut(), verb.as_ptr(), target.as_ptr(), std::ptr::null(), std::ptr::null(), SW_SHOWNORMAL) };
    if result as isize > 32 { Ok(()) } else { Err("The browser could not be opened".into()) }
}

#[cfg(not(windows))]
fn launch(url: &str) -> Result<(), String> {
    let program = if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
    // The address is one argument, never shell text.
    std::process::Command::new(program).arg(url).spawn().map(|_| ()).map_err(|error| format!("The browser could not be opened: {error}"))
}

#[cfg(test)]
mod tests {
    use super::checked;

    #[test]
    fn only_web_addresses_open() {
        assert_eq!(checked("https://example.com/a?b=c").as_deref(), Some("https://example.com/a?b=c"));
        assert!(checked("http://example.com").is_some());
        for refused in ["file:///etc/passwd", "javascript:alert(1)", "ms-settings:", "smb://host/share", "not a url", ""] {
            assert!(checked(refused).is_none(), "{refused}");
        }
    }
}
