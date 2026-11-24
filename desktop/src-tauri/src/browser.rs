//! The default browser's own name, for "Open in Firefox", as the Mac's `DefaultBrowser`
//! reads it from Launch Services. Windows reads the https association's program from the
//! registry; Linux asks `xdg-settings` and reads the name from its desktop entry. Any
//! failure leaves the name unknown, and the button says "Open in browser".

use std::sync::OnceLock;

/// Looked up once; changing the default browser takes effect on the next start.
#[tauri::command]
pub fn default_browser() -> Option<String> {
    static NAME: OnceLock<Option<String>> = OnceLock::new();
    NAME.get_or_init(|| match std::env::var("FYKE_BROWSER") {
        // Test mode: a fixed name, or none when empty.
        Ok(name) => Some(name).filter(|n| !n.is_empty()),
        Err(_) => lookup().and_then(|n| plain(&n)),
    })
    .clone()
}

/// A name fit to show: one short line, and not a resource reference (`@{…}`, `@%…`).
fn plain(name: &str) -> Option<String> {
    let name = name.trim();
    (!name.is_empty() && !name.starts_with('@') && name.chars().count() <= 40 && !name.contains(['\n', '\r'])).then(|| name.to_string())
}

/// The `Name=` of a desktop entry's `[Desktop Entry]` group, unlocalized.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn desktop_entry_name(text: &str) -> Option<String> {
    let mut in_entry = false;
    for line in text.lines().map(str::trim) {
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
        } else if in_entry {
            if let Some(value) = line.strip_prefix("Name=") {
                return Some(value.trim().to_string());
            }
        }
    }
    None
}

#[cfg(target_os = "linux")]
fn lookup() -> Option<String> {
    use std::path::PathBuf;
    let output = std::process::Command::new("xdg-settings").args(["get", "default-web-browser"]).output().ok()?;
    let id = String::from_utf8(output.stdout).ok()?.trim().to_string();
    // A desktop file id, never a path.
    if !id.ends_with(".desktop") || id.contains(['/', '\\']) || id.starts_with('.') {
        return None;
    }
    let home = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")));
    let dirs = std::env::var("XDG_DATA_DIRS").ok().filter(|d| !d.is_empty()).unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    home.into_iter()
        .chain(dirs.split(':').map(PathBuf::from))
        .find_map(|dir| std::fs::read_to_string(dir.join("applications").join(&id)).ok())
        .and_then(|text| desktop_entry_name(&text))
}

#[cfg(windows)]
fn lookup() -> Option<String> {
    let prog_id = registry(
        windows_sys::Win32::System::Registry::HKEY_CURRENT_USER,
        r"Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice",
        "ProgId",
    )?;
    if prog_id.contains(['\\', '/']) {
        return None;
    }
    registry(windows_sys::Win32::System::Registry::HKEY_CLASSES_ROOT, &format!(r"{prog_id}\Application"), "ApplicationName")
}

#[cfg(windows)]
fn registry(root: windows_sys::Win32::System::Registry::HKEY, key: &str, value: &str) -> Option<String> {
    use windows_sys::Win32::System::Registry::{RegGetValueW, RRF_RT_REG_SZ};
    let wide = |text: &str| text.encode_utf16().chain(Some(0)).collect::<Vec<u16>>();
    let (key, value) = (wide(key), wide(value));
    let mut buffer = [0u16; 256];
    let mut size = std::mem::size_of_val(&buffer) as u32;
    let status = unsafe {
        RegGetValueW(root, key.as_ptr(), value.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buffer.as_mut_ptr().cast(), &mut size)
    };
    if status != 0 {
        return None;
    }
    let len = buffer.iter().position(|&c| c == 0).unwrap_or(buffer.len());
    String::from_utf16(&buffer[..len]).ok()
}

#[cfg(not(any(windows, target_os = "linux")))]
fn lookup() -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::{desktop_entry_name, plain};

    #[test]
    fn reads_the_entry_name_and_not_an_action_name() {
        let text = "[Desktop Entry]\nType=Application\nName[de]=Feuerfuchs\nName=Firefox\n\n[Desktop Action new-window]\nName=New Window\n";
        assert_eq!(desktop_entry_name(text).as_deref(), Some("Firefox"));
        assert_eq!(desktop_entry_name("[Desktop Action x]\nName=New Window\n"), None);
        assert_eq!(desktop_entry_name(""), None);
    }

    #[test]
    fn shows_only_plain_short_names() {
        assert_eq!(plain(" Google Chrome ").as_deref(), Some("Google Chrome"));
        assert_eq!(plain("@{Microsoft.MicrosoftEdge_8wekyb3d8bbwe?ms-resource://x}"), None);
        assert_eq!(plain(""), None);
        assert_eq!(plain(&"x".repeat(41)), None);
    }
}
