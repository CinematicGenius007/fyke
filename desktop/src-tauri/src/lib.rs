//! The Fyke desktop app for Windows and Linux. The UI in ../src does everything it can;
//! this side holds what a web page cannot: the daemon's socket, the data folder, the
//! window, and the system.

pub mod events;
pub mod external;
mod opml;
pub mod paths;
pub mod rpc;
pub mod socket;
pub mod testmode;

use rpc::{Client, RpcError};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, State};

/// The event the UI listens to for the daemon's changes.
pub const EVENT: &str = "fyke://event";

struct App {
    client: Arc<Client>,
    events: Mutex<Option<Arc<events::Stream>>>,
}

#[tauri::command]
async fn call(app: State<'_, App>, method: String, params: Option<Value>, slow: Option<bool>) -> Result<Value, RpcError> {
    let client = app.client.clone();
    let params = params.unwrap_or_else(|| Value::Object(Default::default()));
    tauri::async_runtime::spawn_blocking(move || {
        if slow.unwrap_or(false) {
            client.call_slow(&method, &params)
        } else {
            client.call(&method, &params)
        }
    })
    .await
    .map_err(|e| RpcError::new(e.to_string()))?
}

/// Starts the event stream from `since`, replacing any running one.
#[tauri::command]
fn subscribe(handle: AppHandle, app: State<'_, App>, since: i64) {
    let stream = events::Stream::new(since);
    if let Some(old) = app.events.lock().unwrap_or_else(|e| e.into_inner()).replace(stream.clone()) {
        old.stop.store(true, std::sync::atomic::Ordering::SeqCst);
    }
    let client = app.client.clone();
    std::thread::spawn(move || {
        events::run(client, stream, |event| {
            let _ = handle.emit_to("main", EVENT, event);
        })
    });
}

#[tauri::command]
fn pause(app: State<'_, App>, paused: bool) {
    app.client.set_paused(paused);
}

#[tauri::command]
fn data_home(app: State<'_, App>) -> String {
    app.client.home().display().to_string()
}

#[tauri::command]
fn test_mode() -> BTreeMap<String, String> {
    testmode::variables(std::env::vars())
}

/// Shows the window once the UI has drawn, so it never flashes empty. A headless test
/// run keeps it hidden.
#[tauri::command]
fn ready(handle: AppHandle) {
    if testmode::headless() {
        return;
    }
    if let Some(window) = handle.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// Opens a web address in the system browser (http and https only).
#[tauri::command]
fn open_external(url: String) -> Result<(), String> {
    external::open(&url)
}

#[tauri::command]
fn quit(handle: AppHandle, code: Option<i32>) {
    handle.exit(code.unwrap_or(0));
}

pub fn run() {
    let home = match paths::current_data_home() {
        Ok(home) => home,
        Err(message) => {
            eprintln!("fyke-app: {message}");
            std::process::exit(1);
        }
    };
    let exe = std::env::current_exe().unwrap_or_default();
    let program = paths::daemon_binary(|name| std::env::var(name).ok(), &exe);
    let state = App { client: Arc::new(Client::new(home, program)), events: Mutex::new(None) };

    tauri::Builder::default()
        // A second launch brings the running app forward instead of opening another.
        .plugin(tauri_plugin_single_instance::init(|handle, _args, _cwd| {
            if let Some(window) = handle.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(state)
        .invoke_handler(tauri::generate_handler![
            call,
            subscribe,
            pause,
            data_home,
            test_mode,
            ready,
            quit,
            open_external,
            opml::import_opml,
            opml::export_opml
        ])
        .run(tauri::generate_context!())
        .expect("the window could not open");
}
