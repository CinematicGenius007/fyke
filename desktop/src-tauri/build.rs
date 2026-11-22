fn main() {
    const COMMANDS: &[&str] = &[
        "call",
        "subscribe",
        "pause",
        "data_home",
        "test_mode",
        "ready",
        "quit",
        "open_external",
        "import_opml",
        "export_opml",
        "open_viewer",
        "close_viewer",
        "position_viewer",
        "navigate_viewer",
    ];
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(COMMANDS)))
        .expect("build the application capability");
}
