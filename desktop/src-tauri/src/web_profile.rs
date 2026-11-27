//! The WebView2 profile folder of each page session. WebView2 keeps files in it
//! open for a moment after the webview closes, so removal runs on its own thread
//! and tries again with growing waits. Folders carry `PREFIX`, so one left by a
//! run that ended early is found and removed when a later run opens its first page.

// Only Windows keeps a profile folder; other platforms build this module for its tests.
#![cfg_attr(not(windows), allow(dead_code))]

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};
use std::{fs, io, thread};

pub const PREFIX: &str = "fyke-page-";
/// The waits between tries, about six seconds in all.
const WAITS: [Duration; 7] = [
    Duration::from_millis(50),
    Duration::from_millis(100),
    Duration::from_millis(200),
    Duration::from_millis(400),
    Duration::from_millis(800),
    Duration::from_millis(1600),
    Duration::from_millis(3200),
];
/// A folder untouched for this long belongs to no open page.
pub const STALE: Duration = Duration::from_secs(60 * 60);

pub fn create(parent: &Path) -> io::Result<PathBuf> {
    tempfile::Builder::new().prefix(PREFIX).tempdir_in(parent).map(tempfile::TempDir::keep)
}

/// Removes `path`, trying again after each wait. A folder that is already gone counts as removed.
pub fn remove(path: &Path, waits: &[Duration]) -> bool {
    for wait in std::iter::once(&Duration::ZERO).chain(waits) {
        thread::sleep(*wait);
        match fs::remove_dir_all(path) {
            Ok(()) => return true,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return true,
            Err(_) => {}
        }
    }
    false
}

pub fn discard(path: PathBuf) {
    thread::spawn(move || remove(&path, &WAITS));
}

/// Removes this app's profile folders in `parent` last changed before `before`,
/// and returns how many it removed.
pub fn sweep(parent: &Path, before: SystemTime) -> usize {
    let Ok(entries) = fs::read_dir(parent) else { return 0 };
    entries
        .flatten()
        .filter(|entry| entry.file_name().to_str().is_some_and(|name| name.starts_with(PREFIX)))
        .filter(|entry| entry.metadata().is_ok_and(|metadata| metadata.is_dir() && metadata.modified().is_ok_and(|time| time < before)))
        .filter(|entry| fs::remove_dir_all(entry.path()).is_ok())
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_profile_folder_is_named_for_the_app() {
        let parent = tempfile::tempdir().unwrap();
        let folder = create(parent.path()).unwrap();
        assert!(folder.is_dir());
        assert!(folder.file_name().unwrap().to_str().unwrap().starts_with(PREFIX));
    }

    #[test]
    #[cfg(unix)]
    fn removal_tries_again_until_the_folder_lets_go() {
        use std::os::unix::fs::PermissionsExt;
        let parent = tempfile::tempdir().unwrap();
        let folder = create(parent.path()).unwrap();
        fs::write(folder.join("Cookies"), b"").unwrap();
        // A folder whose entries cannot be unlinked stands in for files WebView2 still holds.
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o500)).unwrap();
        let held = folder.clone();
        let release = thread::spawn(move || {
            thread::sleep(Duration::from_millis(150));
            fs::set_permissions(&held, fs::Permissions::from_mode(0o700)).unwrap();
        });
        assert!(remove(&folder, &[Duration::from_millis(100); 5]));
        release.join().unwrap();
        assert!(!folder.exists());
    }

    #[test]
    #[cfg(unix)]
    fn removal_gives_up_after_the_last_wait_and_a_missing_folder_counts_as_removed() {
        use std::os::unix::fs::PermissionsExt;
        let parent = tempfile::tempdir().unwrap();
        let folder = create(parent.path()).unwrap();
        fs::write(folder.join("Cookies"), b"").unwrap();
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o500)).unwrap();
        assert!(!remove(&folder, &[Duration::from_millis(1); 2]));
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(remove(&folder, &[]));
        assert!(remove(&folder, &[]));
    }

    #[test]
    fn the_sweep_removes_only_old_folders_of_this_app() {
        let parent = tempfile::tempdir().unwrap();
        let ours = create(parent.path()).unwrap();
        let other = parent.path().join("other-app");
        fs::create_dir(&other).unwrap();
        let file = parent.path().join(format!("{PREFIX}note"));
        fs::write(&file, b"").unwrap();
        assert_eq!(sweep(parent.path(), SystemTime::now() - STALE), 0);
        assert!(ours.exists());
        assert_eq!(sweep(parent.path(), SystemTime::now() + Duration::from_secs(1)), 1);
        assert!(!ours.exists() && other.exists() && file.exists());
    }
}
