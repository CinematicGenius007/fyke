//! The Fyke desktop app for Windows and Linux. The UI in ../src does everything it can;
//! this side holds what a web page cannot: the daemon's socket, the data folder, the
//! window, and the system.

mod browser;
pub mod events;
pub mod external;
pub mod notify;
mod opml;
pub mod paths;
pub mod rpc;
mod settings;
pub mod socket;
pub mod testmode;
#[cfg(any(windows, target_os = "linux"))]
mod web;
#[cfg(any(windows, target_os = "linux", test))]
mod web_guard;
#[cfg(any(windows, test))]
mod web_profile;

use rpc::{Client, RpcError};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, State};

/// The event the UI listens to for the daemon's changes.
pub const EVENT: &str = "fyke://event";

#[derive(Clone)]
struct App {
    client: Arc<Mutex<Arc<Client>>>,
    events: Arc<Mutex<Option<Arc<events::Stream>>>>,
    move_lock: Arc<Mutex<()>>,
}

impl App {
    fn client(&self) -> Arc<Client> {
        self.client.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

#[tauri::command]
async fn call(app: State<'_, App>, method: String, params: Option<Value>, slow: Option<bool>) -> Result<Value, RpcError> {
    let client = app.client();
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
    let client = app.client();
    std::thread::spawn(move || {
        events::run(client, stream, |event| {
            // The daemon counts this app as having posted it (`notifies: true`).
            if notify::wanted(&event) {
                notify::post(&handle);
            }
            let _ = handle.emit_to("main", EVENT, event);
        })
    });
}

#[tauri::command]
fn pause(app: State<'_, App>, paused: bool) {
    app.client().set_paused(paused);
}

#[tauri::command]
fn data_home(app: State<'_, App>) -> String {
    app.client().home().display().to_string()
}

#[tauri::command]
fn test_mode() -> BTreeMap<String, String> {
    testmode::variables(std::env::vars())
}

/// Shows the window once the UI has drawn, so it never flashes empty. A headless test
/// run keeps it hidden.
#[tauri::command]
fn ready(handle: AppHandle) {
    if let Some(stay) = testmode::measure() {
        use std::io::Write;
        let mut out = std::io::stdout();
        let _ = writeln!(out, "ready");
        let _ = out.flush();
        std::thread::spawn(move || {
            std::thread::sleep(stay);
            handle.exit(0);
        });
        return;
    }
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
    let args: Vec<String> = std::env::args().collect();
    let notify_only = notify::requested(&args);
    if notify_only && (testmode::headless() || !notify::hand_over(&args)) {
        return;
    }
    let home = match paths::current_data_home() {
        Ok(home) => home,
        Err(message) => {
            eprintln!("fyke-app: {message}");
            std::process::exit(1);
        }
    };
    let exe = std::env::current_exe().unwrap_or_default();
    let mut program = paths::daemon_binary(|name| std::env::var(name).ok(), &exe);
    if let Some(copy) = paths::appimage_daemon(|name| std::env::var(name).ok()) {
        if paths::install_copy(&program, &copy).is_ok() {
            program = copy;
        }
    }
    let state = App {
        client: Arc::new(Mutex::new(Arc::new(Client::new(home, program)))),
        events: Arc::new(Mutex::new(None)),
        move_lock: Arc::new(Mutex::new(())),
    };

    let builder = tauri::Builder::default();
    #[cfg(any(windows, target_os = "linux"))]
    let builder = builder.manage(web::Viewer::default());
    builder
        // A second launch brings the running app forward instead of opening another,
        // and a `--notify` launch has the running app post instead.
        .plugin(tauri_plugin_single_instance::init(|handle, args, _cwd| {
            if notify::requested(&args) {
                notify::post(handle);
            } else {
                notify::open(handle);
            }
        }))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(state)
        .setup(move |app| {
            notify::on_click(app.handle())?;
            if notify_only {
                // Post, open no window, and quit unless the notification is clicked.
                if !notify::post(app.handle()) {
                    app.handle().exit(0);
                }
                notify::quit_later(app.handle().clone());
            } else {
                notify::create_window(app)?;
            }
            settings::watch_config(app.handle().clone(), app.state::<App>().inner().clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            call,
            subscribe,
            pause,
            data_home,
            test_mode,
            ready,
            quit,
            open_external,
            browser::default_browser,
            settings::desktop_paths,
            settings::open_data,
            settings::background_service,
            settings::choose_data_folder,
            settings::move_data,
            settings::font_families,
            opml::import_opml,
            opml::export_opml,
            #[cfg(any(windows, target_os = "linux"))]
            web::open_viewer,
            #[cfg(any(windows, target_os = "linux"))]
            web::close_viewer,
            #[cfg(any(windows, target_os = "linux"))]
            web::position_viewer,
            #[cfg(any(windows, target_os = "linux"))]
            web::navigate_viewer
        ])
        .run(tauri::generate_context!())
        .expect("the window could not open");
}
