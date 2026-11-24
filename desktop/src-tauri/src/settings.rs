//! Files, installed fonts and the daemon's existing service and data-move commands.

use crate::{paths, App, Client, RpcError};
use serde::Serialize;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use tauri::{ipc::Channel, AppHandle, Emitter, State, WebviewWindow};
use tauri_plugin_dialog::DialogExt;

/// The daemon accepts hand edits to config.json. Checking the path also sees atomic
/// replacement and follows the anchor after a data move.
pub(crate) fn watch_config(handle: AppHandle, app: App) {
    std::thread::spawn(move || {
        let stamp = || {
            let path = app.client().home().join("config.json");
            std::fs::metadata(path).ok().map(|file| (file.modified().ok(), file.len()))
        };
        let mut previous = stamp();
        loop {
            std::thread::sleep(std::time::Duration::from_millis(750));
            let next = stamp();
            if previous != next {
                previous = next;
                let _ = handle.emit_to("main", "fyke://config", ());
            }
        }
    });
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DesktopPaths {
    data: PathBuf,
    config: PathBuf,
    home: Option<PathBuf>,
    program: PathBuf,
    can_move: bool,
}

fn can_move() -> bool {
    std::env::var_os("FYKE_HOME").is_none_or(|path| path.is_empty())
}

#[tauri::command]
pub(crate) fn desktop_paths(app: State<'_, App>) -> DesktopPaths {
    let client = app.client();
    let data = client.home().canonicalize().unwrap_or_else(|_| client.home().into());
    #[cfg(windows)]
    let data = data.to_str().and_then(|path| path.strip_prefix(r"\\?\")).map_or(data.clone(), PathBuf::from);
    DesktopPaths {
        config: data.join("config.json"),
        data,
        home: std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from),
        program: client.program().into(),
        can_move: can_move(),
    }
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum DataItem {
    Folder,
    Config,
}

#[tauri::command]
pub(crate) fn open_data(app: State<'_, App>, item: DataItem) -> Result<(), String> {
    let client = app.client();
    let path = match item {
        DataItem::Folder => client.home().to_path_buf(),
        DataItem::Config => client.home().join("config.json"),
    };
    crate::external::launch(path.as_os_str())
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum ServiceAction {
    Status,
    Install,
    Uninstall,
}

impl ServiceAction {
    fn argument(self) -> &'static str {
        match self {
            Self::Status => "status",
            Self::Install => "install",
            Self::Uninstall => "uninstall",
        }
    }
}

fn cli(program: &Path) -> Command {
    let mut cmd = Command::new(program);
    cmd.stdin(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    cmd
}

#[tauri::command]
pub(crate) async fn background_service(app: State<'_, App>, action: ServiceAction) -> Result<bool, String> {
    let client = app.client();
    tauri::async_runtime::spawn_blocking(move || {
        let run = |operation| {
            let output = cli(client.program()).args(["service", operation]).output().map_err(|e| e.to_string())?;
            if output.status.success() {
                Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
            } else {
                Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
            }
        };
        let operation = action.argument();
        if operation != "status" {
            run(operation)?;
        }
        Ok(run("status")? == "installed")
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn choose_data_folder(window: WebviewWindow) -> Result<Option<PathBuf>, String> {
    if !can_move() {
        return Err("The data folder is set by FYKE_HOME.".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let selected = window.dialog().file().set_parent(&window).set_title("Choose a new data folder").blocking_pick_folder();
        let Some(path) = selected else { return Ok(None) };
        let mut path = path.into_path().map_err(|e| e.to_string())?;
        let populated = |folder: &Path| -> Result<bool, String> {
            match std::fs::read_dir(folder) {
                Ok(mut contents) => contents.next().transpose().map(|entry| entry.is_some()).map_err(|e| e.to_string()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
                Err(error) => Err(error.to_string()),
            }
        };
        if populated(&path)? {
            path.push("fyke_data");
            if populated(&path)? {
                return Err("That folder already holds a fyke_data folder".into());
            }
        }
        Ok(Some(path))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn move_data(app: State<'_, App>, target: PathBuf, stages: Channel<String>) -> Result<(), RpcError> {
    if !can_move() || !target.is_absolute() {
        return Err(RpcError::new("Choose a new location for the default data folder."));
    }
    let state = app.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _moving = state.move_lock.try_lock().map_err(|_| RpcError::new("The data folder is moving."))?;
        let client = state.client();
        client.set_paused(true);
        if let Some(stream) = state.events.lock().unwrap_or_else(|e| e.into_inner()).take() {
            stream.stop.store(true, Ordering::SeqCst);
        }

        let result = run_move(client.program(), &target, &stages);
        // A move can finish copying and fail while starting. Resolve the actual anchor,
        // on either outcome, before allowing a new connection.
        match paths::current_data_home() {
            Ok(path) => {
                *state.client.lock().unwrap_or_else(|e| e.into_inner()) = Arc::new(Client::new(path, client.program().into()));
            }
            Err(_) => client.set_paused(false),
        }
        result
    })
    .await
    .map_err(|e| RpcError::new(e.to_string()))?
}

fn run_move(program: &Path, target: &Path, stages: &Channel<String>) -> Result<(), RpcError> {
    let mut child = cli(program)
        .args(["data", "move"])
        .arg(target)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| RpcError::new(e.to_string()))?;
    let stderr = child.stderr.take().expect("piped stderr");
    let error_reader = std::thread::spawn(move || {
        let mut message = String::new();
        let _ = BufReader::new(stderr).read_to_string(&mut message);
        message
    });
    let stdout = child.stdout.take().expect("piped stdout");
    let mut moved = false;
    for line in BufReader::new(stdout).lines().map_while(Result::ok) {
        let stage = match line.trim() {
            "stopping" => "Stopping…",
            "moving" => "Moving…",
            "verifying" => "Checking the copy…",
            "linking" => "Linking…",
            "starting" => {
                moved = true;
                "Restarting…"
            }
            _ => continue,
        };
        let _ = stages.send(stage.into());
    }
    let status = child.wait().map_err(|e| RpcError::new(e.to_string()))?;
    let errors = error_reader.join().unwrap_or_default();
    if status.success() {
        Ok(())
    } else if moved {
        Err(RpcError::new("The data moved, but the background service did not restart. Quit and open Fyke again."))
    } else {
        Err(RpcError::new(errors.trim()))
    }
}

#[tauri::command]
pub(crate) async fn font_families() -> Vec<String> {
    tauri::async_runtime::spawn_blocking(|| {
        let mut fonts = installed_fonts();
        fonts.sort_unstable();
        fonts.dedup();
        fonts
    })
    .await
    .unwrap_or_default()
}

#[cfg(target_os = "linux")]
fn installed_fonts() -> Vec<String> {
    Command::new("fc-list")
        .args(["--format", "%{family[0]}\n"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).lines().filter(|line| !line.is_empty()).map(String::from).collect())
        .unwrap_or_default()
}

#[cfg(windows)]
fn installed_fonts() -> Vec<String> {
    use windows_sys::Win32::Graphics::Gdi::{EnumFontFamiliesExW, GetDC, ReleaseDC, DEFAULT_CHARSET, LOGFONTW, TEXTMETRICW};
    unsafe extern "system" fn family(font: *const LOGFONTW, _: *const TEXTMETRICW, _: u32, data: isize) -> i32 {
        // Win32 calls this synchronously while both the font data and the vector are live.
        let (name, families) = unsafe { (&(*font).lfFaceName, &mut *(data as *mut Vec<String>)) };
        let end = name.iter().position(|unit| *unit == 0).unwrap_or(name.len());
        let name = String::from_utf16_lossy(&name[..end]);
        if !name.is_empty() && !name.starts_with('@') {
            families.push(name);
        }
        1
    }

    let mut families: Vec<String> = Vec::new();
    let query = LOGFONTW { lfCharSet: DEFAULT_CHARSET, ..Default::default() };
    // A null HWND selects the screen's device context. Release it on the same thread.
    unsafe {
        let context = GetDC(std::ptr::null_mut());
        if !context.is_null() {
            EnumFontFamiliesExW(context, &query, Some(family), (&mut families as *mut Vec<String>) as isize, 0);
            ReleaseDC(std::ptr::null_mut(), context);
        }
    }
    families
}

#[cfg(target_os = "macos")]
fn installed_fonts() -> Vec<String> {
    Vec::new()
}
