//! Routine notifications (docs/desktop-parity.md D15, F42), as gui/Sources/Reader/
//! Features.swift `Notifier` posts them. A running app posts one for each
//! `routine.notify` event it receives. With no app running, the daemon starts this one
//! with `--notify` (src/notify.zig): it posts, opens no window, and quits, unless the
//! notification is clicked, which opens Fyke as a normal launch would.

use crate::testmode;
use std::time::Duration;
use tauri::{AppHandle, Manager, Runtime, WebviewWindowBuilder};
use tauri_plugin_notification::NotificationExt;

/// The Mac's words, the same on every system.
pub const TITLE: &str = "Fyke";
pub const BODY: &str = "A routine has something for you";
pub const FLAG: &str = "--notify";
/// Marks the copy a `--notify` launch hands over to (see [`hand_over`]).
pub const DETACHED: &str = "--detached";
pub const EVENT_TYPE: &str = "routine.notify";

/// How long a `--notify` launch stays to answer a click before it quits. On Linux it
/// also quits as soon as the notification closes, since the server removes it when the
/// connection that posted it goes away.
pub const WAIT: Duration = Duration::from_secs(60);

/// Whether a command line (with the program first) asks to post and quit.
pub fn requested<S: AsRef<str>>(args: &[S]) -> bool {
    args.iter().skip(1).any(|arg| arg.as_ref() == FLAG)
}

/// The daemon waits for the program it starts, from one of its job workers. A `--notify`
/// launch stays for up to [`WAIT`] to answer a click, so it starts a copy of itself to do
/// that and exits at once. Returns whether the caller is that copy, or the copy could not
/// start and the caller should post itself.
pub fn hand_over<S: AsRef<str>>(args: &[S]) -> bool {
    if args.iter().any(|arg| arg.as_ref() == DETACHED) {
        return true;
    }
    let Ok(program) = std::env::current_exe() else { return true };
    let started = std::process::Command::new(program)
        .args([FLAG, DETACHED])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
    started.is_err()
}

/// Whether a daemon event is one to post.
pub fn wanted(event: &serde_json::Value) -> bool {
    event.get("type").and_then(|t| t.as_str()) == Some(EVENT_TYPE)
}

/// Posts the routine notification. A headless check never reaches the notifications of
/// the person at the computer.
pub fn post<R: Runtime>(handle: &AppHandle<R>) -> bool {
    if testmode::headless() {
        return false;
    }
    let builder = handle.notification().builder().title(TITLE).body(BODY);
    #[cfg(target_os = "linux")]
    let builder = {
        let handle = handle.clone();
        builder.on_close(move || quit_unless_open(&handle))
    };
    builder.show().is_ok()
}

/// A click on a notification opens Fyke.
pub fn on_click<R: Runtime>(handle: &AppHandle<R>) -> tauri_plugin_notification::Result<()> {
    let app = handle.clone();
    handle.notification().on_action(move |action| {
        if action.action_id() == "tap" {
            open(&app);
        }
    })
}

/// A `--notify` launch quits after [`WAIT`] unless a click opened the window.
pub fn quit_later<R: Runtime>(handle: AppHandle<R>) {
    std::thread::spawn(move || {
        std::thread::sleep(WAIT);
        quit_unless_open(&handle);
    });
}

fn quit_unless_open<R: Runtime>(handle: &AppHandle<R>) {
    if handle.get_webview_window("main").is_none() {
        handle.exit(0);
    }
}

/// Brings the window forward, or opens it in a `--notify` launch that has none. The
/// UI shows a new window once it has drawn (`ready`).
pub fn open<R: Runtime>(handle: &AppHandle<R>) {
    if let Some(window) = handle.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    // Creating a window on the event loop's own thread can deadlock on Windows.
    let handle = handle.clone();
    std::thread::spawn(move || {
        let _ = create_window(&handle);
    });
}

/// The main window, from `app.windows` in tauri.conf.json, where it has `create: false`
/// so that a `--notify` launch opens none.
pub fn create_window<R: Runtime, M: Manager<R>>(manager: &M) -> tauri::Result<()> {
    let config = manager.config().app.windows.iter().find(|w| w.label == "main").cloned();
    if let Some(config) = config {
        WebviewWindowBuilder::from_config(manager, &config)?.build()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_the_flag_after_the_program_asks_to_post() {
        assert!(requested(&["Fyke.App.exe", "--notify"]));
        assert!(!requested(&["Fyke.App.exe"]));
        assert!(!requested(&["--notify"]));
        assert!(!requested(&["fyke-app", "--notify=1"]));
        assert!(requested(&["fyke-app", FLAG, DETACHED]));
        assert!(hand_over(&["fyke-app", FLAG, DETACHED]));
    }

    #[test]
    fn only_routine_notify_events_post() {
        assert!(wanted(&json!({"type": "routine.notify", "seq": 4})));
        assert!(!wanted(&json!({"type": "routine.changed"})));
        assert!(!wanted(&json!({"seq": 4})));
    }

    #[test]
    fn the_main_window_is_not_created_from_the_config() {
        let config: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        let main = &config["app"]["windows"][0];
        assert_eq!(main["label"], "main");
        assert_eq!(main["create"], false);
    }
}
