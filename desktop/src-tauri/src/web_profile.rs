//! The WebView2 profile folder of each page session. Every one lives in a folder
//! of Fyke's own in the temporary folder (`home`), so cleanup never reaches
//! anything else there. WebView2 keeps files in a profile open for a moment after
//! the webview closes, so removal runs on its own thread and tries again with
//! growing waits. One left by a run that ended early is removed when a later run
//! opens its first page.

// Only Windows keeps a profile folder; other platforms build this module for its tests.
#![cfg_attr(not(windows), allow(dead_code))]

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};
use std::{fs, io, thread};

/// Removals still running. Quitting waits for them (`finish`), because a thread
/// ends with the process and would leave its folder behind.
static PENDING: Mutex<Vec<thread::JoinHandle<bool>>> = Mutex::new(Vec::new());
/// Folders made and not yet discarded, including one whose page is still opening.
static OPEN: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

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

/// The folder that holds every page profile, made if missing.
pub fn home() -> io::Result<PathBuf> {
    let home = std::env::temp_dir().join("fyke-pages");
    fs::create_dir_all(&home)?;
    Ok(home)
}

pub fn create(parent: &Path) -> io::Result<PathBuf> {
    let folder = tempfile::Builder::new().prefix(PREFIX).tempdir_in(parent).map(tempfile::TempDir::keep)?;
    OPEN.lock().unwrap_or_else(|error| error.into_inner()).push(folder.clone());
    Ok(folder)
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
    OPEN.lock().unwrap_or_else(|error| error.into_inner()).retain(|open| *open != path);
    let removal = thread::spawn(move || remove(&path, &WAITS));
    let mut pending = PENDING.lock().unwrap_or_else(|error| error.into_inner());
    pending.retain(|removal| !removal.is_finished());
    pending.push(removal);
}

/// Discards every folder still open, then waits up to `limit` for the removals
/// `discard` started. Returns false if one was still running at the limit; the
/// next run's `sweep` removes what it leaves.
pub fn finish(limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    let open = std::mem::take(&mut *OPEN.lock().unwrap_or_else(|error| error.into_inner()));
    for folder in open {
        discard(folder);
    }
    let pending = std::mem::take(&mut *PENDING.lock().unwrap_or_else(|error| error.into_inner()));
    for removal in pending {
        while !removal.is_finished() {
            if Instant::now() >= deadline {
                return false;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let _ = removal.join();
    }
    true
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

    /// `finish` discards every open folder, so the tests that make folders take turns.
    static SERIAL: Mutex<()> = Mutex::new(());

    fn serial() -> std::sync::MutexGuard<'static, ()> {
        SERIAL.lock().unwrap_or_else(|error| error.into_inner())
    }

    #[test]
    fn a_profile_folder_is_named_for_the_app() {
        let _turn = serial();
        let parent = tempfile::tempdir().unwrap();
        let folder = create(parent.path()).unwrap();
        assert!(folder.is_dir());
        assert!(folder.file_name().unwrap().to_str().unwrap().starts_with(PREFIX));
    }

    #[test]
    #[cfg(unix)]
    fn removal_tries_again_until_the_folder_lets_go() {
        let _turn = serial();
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
        let _turn = serial();
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
    #[cfg(unix)]
    fn quitting_waits_for_a_removal_in_progress_up_to_a_limit() {
        let _turn = serial();
        use std::os::unix::fs::PermissionsExt;
        let parent = tempfile::tempdir().unwrap();
        let folder = create(parent.path()).unwrap();
        fs::write(folder.join("Cookies"), b"").unwrap();
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o500)).unwrap();
        discard(folder.clone());
        assert!(!finish(Duration::from_millis(100)), "the held folder outlasts a short limit");

        let second = create(parent.path()).unwrap();
        fs::write(second.join("Cookies"), b"").unwrap();
        fs::set_permissions(&second, fs::Permissions::from_mode(0o500)).unwrap();
        discard(second.clone());
        let held = second.clone();
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(200));
            fs::set_permissions(&held, fs::Permissions::from_mode(0o700)).unwrap();
        });
        assert!(finish(Duration::from_secs(5)));
        assert!(!second.exists(), "finish returns only once the removal is done");
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn the_sweep_removes_only_old_folders_of_this_app() {
        let _turn = serial();
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
