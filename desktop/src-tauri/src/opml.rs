//! Native file panels keep the export path in the shell. The daemon parses and
//! generates OPML, so subscriptions and their folder hierarchy have one format.

use crate::{App, RpcError};
use serde_json::json;
use std::io::Write;
use tauri::{State, WebviewWindow};
use tauri_plugin_dialog::DialogExt;

#[tauri::command]
pub(crate) async fn import_opml(window: WebviewWindow, app: State<'_, App>) -> Result<bool, RpcError> {
    let client = app.client.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let path = window.dialog().file().set_parent(&window).add_filter("OPML", &["opml", "xml"]).blocking_pick_file();
        let Some(path) = path else { return Ok(false) };
        let path = path.into_path().map_err(|e| RpcError::new(e.to_string()))?;
        let path = path.to_str().ok_or_else(|| RpcError::new("This file's path is not valid Unicode."))?;
        client.call_slow("opml.import", &json!({ "path": path }))?;
        Ok(true)
    })
    .await
    .map_err(|e| RpcError::new(e.to_string()))?
}

#[tauri::command]
pub(crate) async fn export_opml(window: WebviewWindow, app: State<'_, App>) -> Result<(), RpcError> {
    let client = app.client.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let path =
            window.dialog().file().set_parent(&window).add_filter("OPML", &["opml"]).set_file_name("feeds.opml").blocking_save_file();
        let Some(path) = path else { return Ok(()) };
        let path = path.into_path().map_err(|e| RpcError::new(e.to_string()))?;
        let document = client.call("opml.export", &json!({}))?;
        let text = document["opml"].as_str().ok_or_else(|| RpcError::new("Fyke did not return an OPML document."))?;
        let directory = path.parent().ok_or_else(|| RpcError::new("Choose a folder for the export."))?;

        // Staging beside the destination keeps an earlier export intact if the write fails.
        let mut file = tempfile::NamedTempFile::new_in(directory).map_err(|e| RpcError::new(e.to_string()))?;
        file.write_all(text.as_bytes()).map_err(|e| RpcError::new(e.to_string()))?;
        file.persist(path).map_err(|e| RpcError::new(e.to_string()))?;
        Ok(())
    })
    .await
    .map_err(|e| RpcError::new(e.to_string()))?
}
