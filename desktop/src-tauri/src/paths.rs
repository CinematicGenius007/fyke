//! Where the data folder is, resolved the way `homeDirectory` in src/main.zig does:
//! `FYKE_HOME` first; on Windows `%LOCALAPPDATA%\Fyke`, following the `location`
//! pointer that `fyke data move` writes there; elsewhere `~/.fyke`.
//!
//! The app never moves or renames anything here. The daemon migrates legacy folders.

use std::path::{Path, PathBuf};

/// The file in the default Windows data folder that names the folder chosen by
/// `fyke data move` (`location_file` in src/data_home.zig).
pub const LOCATION_FILE: &str = "location";

/// The socket the daemon listens on, inside the data folder, on every system.
pub const SOCKET_FILE: &str = "fyked.sock";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum System {
    Windows,
    Other,
}

impl System {
    pub const fn current() -> System {
        if cfg!(windows) {
            System::Windows
        } else {
            System::Other
        }
    }
}

/// The data folder. `env` reads one environment variable, `read` reads a small text
/// file (None when it is missing), so tests can give both.
pub fn data_home(system: System, env: impl Fn(&str) -> Option<String>, read: impl Fn(&Path) -> Option<String>) -> Result<PathBuf, String> {
    if let Some(path) = env("FYKE_HOME").filter(|p| !p.is_empty()) {
        return Ok(PathBuf::from(path));
    }
    match system {
        System::Windows => {
            let base = env("LOCALAPPDATA").filter(|p| !p.is_empty()).ok_or("LOCALAPPDATA is not set")?;
            let anchor = PathBuf::from(base).join("Fyke");
            let pointer = read(&anchor.join(LOCATION_FILE))
                .map(|text| text.trim_matches(|c| matches!(c, ' ' | '\t' | '\r' | '\n')).to_string())
                .filter(|text| !text.is_empty());
            Ok(pointer.map(PathBuf::from).unwrap_or(anchor))
        }
        System::Other => {
            let home = env("HOME").or_else(|| env("USERPROFILE")).filter(|p| !p.is_empty()).ok_or("HOME is not set")?;
            Ok(PathBuf::from(home).join(".fyke"))
        }
    }
}

/// The data folder for this process.
pub fn current_data_home() -> Result<PathBuf, String> {
    data_home(
        System::current(),
        |name| std::env::var(name).ok(),
        |path| {
            // The daemon reads at most 4096 bytes of the pointer.
            std::fs::read(path).ok().map(|bytes| String::from_utf8_lossy(&bytes[..bytes.len().min(4096)]).into_owned())
        },
    )
}

/// The `fyke` binary to start: `FYKE_BIN` when set, else the one installed beside the app.
pub fn daemon_binary(env: impl Fn(&str) -> Option<String>, app: &Path) -> PathBuf {
    if let Some(path) = env("FYKE_BIN").filter(|p| !p.is_empty()) {
        return PathBuf::from(path);
    }
    let name = if cfg!(windows) { "fyke.exe" } else { "fyke" };
    app.parent().map(|dir| dir.join(name)).unwrap_or_else(|| PathBuf::from(name))
}

/// Where an AppImage keeps the daemon it starts. An AppImage runs from a mount that goes
/// away when the app quits, while the daemon, and the service `fyke service install`
/// writes, outlive it; so they run a copy in the user's data directory instead. None
/// outside an AppImage, or when `FYKE_BIN` names the daemon.
pub fn appimage_daemon(env: impl Fn(&str) -> Option<String>) -> Option<PathBuf> {
    let set = |name: &str| env(name).filter(|value| !value.is_empty());
    if set("FYKE_BIN").is_some() || set("APPIMAGE").is_none() {
        return None;
    }
    let data = set("XDG_DATA_HOME").map(PathBuf::from).or_else(|| set("HOME").map(|home| Path::new(&home).join(".local/share")))?;
    Some(data.join("fyke").join("bin").join("fyke"))
}

/// Copies `from` to `to` unless `to` already holds the same bytes. The copy is written
/// beside `to` and renamed over it, so a daemon running the old one keeps running.
pub fn install_copy(from: &Path, to: &Path) -> std::io::Result<()> {
    let bytes = std::fs::read(from)?;
    if std::fs::read(to).is_ok_and(|old| old == bytes) {
        return Ok(());
    }
    let dir = to.parent().ok_or_else(|| std::io::Error::other("no folder"))?;
    std::fs::create_dir_all(dir)?;
    let mut temp = tempfile::NamedTempFile::new_in(dir)?;
    std::io::Write::write_all(&mut temp, &bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        temp.as_file().set_permissions(std::fs::Permissions::from_mode(0o755))?;
    }
    temp.persist(to).map_err(|e| e.error)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        move |name| map.get(name).cloned()
    }

    fn files(pairs: &[(&str, &str)]) -> impl Fn(&Path) -> Option<String> {
        let map: HashMap<PathBuf, String> = pairs.iter().map(|(k, v)| (PathBuf::from(k), v.to_string())).collect();
        move |path| map.get(path).cloned()
    }

    #[test]
    fn fyke_home_wins_everywhere() {
        for system in [System::Windows, System::Other] {
            let home = data_home(system, env(&[("FYKE_HOME", "/tmp/x"), ("HOME", "/h"), ("LOCALAPPDATA", "C:/L")]), files(&[]));
            assert_eq!(home.unwrap(), PathBuf::from("/tmp/x"));
        }
    }

    #[test]
    fn an_empty_fyke_home_is_unset() {
        let home = data_home(System::Other, env(&[("FYKE_HOME", ""), ("HOME", "/h")]), files(&[]));
        assert_eq!(home.unwrap(), PathBuf::from("/h/.fyke"));
    }

    #[test]
    fn other_systems_use_dot_fyke_in_home() {
        assert_eq!(data_home(System::Other, env(&[("HOME", "/home/a")]), files(&[])).unwrap(), PathBuf::from("/home/a/.fyke"));
        assert!(data_home(System::Other, env(&[]), files(&[])).is_err());
    }

    #[test]
    fn windows_uses_local_app_data_and_follows_the_pointer() {
        let anchor = PathBuf::from("C:/Users/a/AppData/Local").join("Fyke");
        let pointer = anchor.join(LOCATION_FILE);
        let plain = data_home(System::Windows, env(&[("LOCALAPPDATA", "C:/Users/a/AppData/Local")]), files(&[]));
        assert_eq!(plain.unwrap(), anchor);
        let moved = data_home(
            System::Windows,
            env(&[("LOCALAPPDATA", "C:/Users/a/AppData/Local")]),
            files(&[(pointer.to_str().unwrap(), "  D:\\Fyke data\r\n")]),
        );
        assert_eq!(moved.unwrap(), PathBuf::from("D:\\Fyke data"));
        let blank =
            data_home(System::Windows, env(&[("LOCALAPPDATA", "C:/Users/a/AppData/Local")]), files(&[(pointer.to_str().unwrap(), " \n")]));
        assert_eq!(blank.unwrap(), anchor);
        assert!(data_home(System::Windows, env(&[("HOME", "/h")]), files(&[])).is_err());
    }

    #[test]
    fn the_daemon_binary_sits_beside_the_app_unless_named() {
        let app = Path::new("/opt/fyke/fyke-app");
        let name = if cfg!(windows) { "fyke.exe" } else { "fyke" };
        assert_eq!(daemon_binary(env(&[]), app), PathBuf::from("/opt/fyke").join(name));
        assert_eq!(daemon_binary(env(&[("FYKE_BIN", "/x/fyke")]), app), PathBuf::from("/x/fyke"));
    }

    #[test]
    fn an_appimage_runs_a_copy_of_the_daemon_that_outlives_it() {
        assert_eq!(appimage_daemon(env(&[("HOME", "/home/a")])), None);
        assert_eq!(
            appimage_daemon(env(&[("HOME", "/home/a"), ("APPIMAGE", "/x/Fyke.AppImage")])),
            Some(PathBuf::from("/home/a/.local/share/fyke/bin/fyke"))
        );
        assert_eq!(
            appimage_daemon(env(&[("HOME", "/home/a"), ("XDG_DATA_HOME", "/d"), ("APPIMAGE", "/x")])),
            Some(PathBuf::from("/d/fyke/bin/fyke"))
        );
        assert_eq!(appimage_daemon(env(&[("HOME", "/h"), ("APPIMAGE", "/x"), ("FYKE_BIN", "/b/fyke")])), None);
    }

    #[test]
    fn the_copy_is_replaced_only_when_it_differs() {
        let dir = tempfile::tempdir().unwrap();
        let from = dir.path().join("fyke");
        let to = dir.path().join("kept/bin/fyke");
        std::fs::write(&from, b"one").unwrap();
        install_copy(&from, &to).unwrap();
        assert_eq!(std::fs::read(&to).unwrap(), b"one");
        let before = std::fs::metadata(&to).unwrap().modified().unwrap();
        install_copy(&from, &to).unwrap();
        assert_eq!(std::fs::metadata(&to).unwrap().modified().unwrap(), before);
        std::fs::write(&from, b"two").unwrap();
        install_copy(&from, &to).unwrap();
        assert_eq!(std::fs::read(&to).unwrap(), b"two");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&to).unwrap().permissions().mode() & 0o777, 0o755);
        }
    }
}
