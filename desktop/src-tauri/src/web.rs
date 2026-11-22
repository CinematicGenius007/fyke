//! The remote webview is a child of the main window, with its own profile and no
//! capability. Its network route is installed before the first address loads.

use crate::web_guard::{self, Proxy};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::webview::{DownloadEvent, NewWindowResponse, WebviewBuilder};
use tauri::{AppHandle, Emitter, LogicalPosition, LogicalSize, Manager, State, Webview, WebviewUrl, WebviewWindow};
use url::Url;

const PAGE_EVENT: &str = "fyke://page";

#[derive(Clone, Copy, Deserialize)]
pub(crate) struct Bounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl Bounds {
    fn parts(self) -> Result<(LogicalPosition<f64>, LogicalSize<f64>), String> {
        if ![self.x, self.y, self.width, self.height].into_iter().all(|value| value.is_finite() && value >= 0.0) {
            return Err("The page area is invalid.".into());
        }
        Ok((LogicalPosition::new(self.x, self.y), LogicalSize::new(self.width.max(1.0), self.height.max(1.0))))
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Update<'a> {
    token: u64,
    url: &'a str,
    loading: bool,
    error: Option<&'a str>,
    can_go_back: bool,
    can_go_forward: bool,
}

fn update(app: &AppHandle, token: u64, url: &str, loading: bool, error: Option<&str>, history: (bool, bool)) {
    let _ = app.emit_to("main", PAGE_EVENT, Update { token, url, loading, error, can_go_back: history.0, can_go_forward: history.1 });
}

struct Session {
    webview: Webview,
    _proxy: Proxy,
    #[cfg(windows)]
    _directory: tempfile::TempDir,
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.webview.close();
    }
}

#[derive(Default)]
struct Slot {
    token: Option<u64>,
    session: Option<Session>,
}

#[derive(Default)]
pub(crate) struct Viewer(Mutex<Slot>);

impl Viewer {
    fn slot(&self) -> std::sync::MutexGuard<'_, Slot> {
        self.0.lock().unwrap_or_else(|error| error.into_inner())
    }

    fn using(&self, token: u64) -> Option<Webview> {
        let slot = self.slot();
        if slot.token != Some(token) {
            return None;
        }
        slot.session.as_ref().map(|session| session.webview.clone())
    }
}

#[tauri::command]
pub(crate) async fn open_viewer(
    window: WebviewWindow,
    viewer: State<'_, Viewer>,
    token: u64,
    url: String,
    bounds: Bounds,
) -> Result<(), String> {
    let (position, size) = bounds.parts()?;
    let address = Url::parse(&url).map_err(|error| error.to_string())?;
    let existing = {
        let mut slot = viewer.slot();
        slot.token = Some(token);
        slot.session.take()
    };
    drop(existing);
    web_guard::check_destination(&address).await?;
    let proxy = Proxy::start().await.map_err(|error| error.to_string())?;
    if viewer.slot().token != Some(token) {
        return Ok(());
    }

    let app = window.app_handle().clone();
    let label = format!("remote-page-{token}");
    let for_navigation = app.clone();
    let for_new_window = app.clone();
    let for_download = app.clone();
    let target_label = label.clone();
    // about:blank is an empty initial document. No external address is loaded
    // until the platform-specific permission and navigation handlers are installed.
    let builder = WebviewBuilder::new(label, WebviewUrl::External(Url::parse("about:blank").expect("valid initial URL")))
        .incognito(true)
        .devtools(false)
        .zoom_hotkeys_enabled(false)
        .browser_extensions_enabled(false)
        .on_navigation(move |url| {
            if url.as_str() == "about:blank" {
                return true;
            }
            match web_guard::allowed_url(url) {
                Ok(()) => {
                    update(&for_navigation, token, url.as_str(), true, None, (false, false));
                    true
                }
                Err(error) => {
                    update(&for_navigation, token, url.as_str(), false, Some(error), (false, false));
                    false
                }
            }
        })
        .on_new_window(move |url, _features| {
            if let Err(error) = web_guard::allowed_url(&url) {
                update(&for_new_window, token, url.as_str(), false, Some(error), (false, false));
            } else {
                let app = for_new_window.clone();
                let label = target_label.clone();
                tauri::async_runtime::spawn(async move {
                    if let Some(page) = app.get_webview(&label) {
                        let _ = page.navigate(url);
                    }
                });
            }
            NewWindowResponse::Deny
        })
        .on_download(move |_webview, event| {
            if let DownloadEvent::Requested { url, .. } = event {
                update(&for_download, token, url.as_str(), false, Some("This address is a download, not a page."), (false, false));
            }
            false
        });

    #[cfg(windows)]
    let (builder, directory) = {
        // Environment overrides could replace WebView2's profile or proxy.
        for key in ["WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", "WEBVIEW2_USER_DATA_FOLDER", "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER"] {
            if std::env::var_os(key).is_some() {
                return Err("Fyke could not isolate the page from this WebView2 configuration.".into());
            }
        }
        let directory = tempfile::tempdir().map_err(|error| error.to_string())?;
        let args = format!(
            "--proxy-server={} --proxy-bypass-list=<-loopback> --disable-quic --force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-features=msWebOOUI,msPdfOOUI",
            proxy.url
        );
        (builder.data_directory(directory.path().to_path_buf()).additional_browser_args(&args), directory)
    };
    #[cfg(target_os = "linux")]
    let builder = builder.proxy_url(proxy.url.clone());

    let parent = app.get_window(window.label()).ok_or_else(|| "The reader window closed.".to_string())?;
    let webview = parent.add_child(builder, position, size).map_err(|error| error.to_string())?;
    let session = Session {
        webview: webview.clone(),
        _proxy: proxy,
        #[cfg(windows)]
        _directory: directory,
    };
    {
        let mut slot = viewer.slot();
        if slot.token != Some(token) {
            return Ok(());
        }
        slot.session = Some(session);
    }

    if let Err(error) = configure(&webview, app, token).await {
        close_viewer(viewer, token);
        return Err(error);
    }
    if viewer.using(token).is_none() {
        return Ok(());
    }
    if let Err(error) = webview.navigate(address) {
        close_viewer(viewer, token);
        return Err(error.to_string());
    }
    Ok(())
}

#[tauri::command]
pub(crate) fn close_viewer(viewer: State<'_, Viewer>, token: u64) {
    let session = {
        let mut slot = viewer.slot();
        if slot.token != Some(token) {
            return;
        }
        slot.token = None;
        slot.session.take()
    };
    drop(session);
}

#[tauri::command]
pub(crate) fn position_viewer(viewer: State<'_, Viewer>, token: u64, bounds: Bounds, visible: bool) -> Result<(), String> {
    let Some(webview) = viewer.using(token) else { return Ok(()) };
    let (position, size) = bounds.parts()?;
    webview.set_bounds(tauri::Rect { position: position.into(), size: size.into() }).map_err(|error| error.to_string())?;
    if visible { webview.show() } else { webview.hide() }.map_err(|error| error.to_string())
}

#[tauri::command]
pub(crate) fn navigate_viewer(viewer: State<'_, Viewer>, token: u64, action: &str) -> Result<(), String> {
    let Some(webview) = viewer.using(token) else { return Ok(()) };
    let script = match action {
        "back" => "history.back()",
        "forward" => "history.forward()",
        "reload" => "location.reload()",
        _ => return Err("Unknown page action.".into()),
    };
    webview.eval(script).map_err(|error| error.to_string())
}

#[cfg(target_os = "linux")]
async fn configure(view: &Webview, app: AppHandle, token: u64) -> Result<(), String> {
    use webkit2gtk::{LoadEvent, PermissionRequestExt, SettingsExt, WebViewExt};
    let (send, receive) = tokio::sync::oneshot::channel();
    view.with_webview(move |native| {
        let page = native.inner();
        if let Some(settings) = page.settings() {
            settings.set_enable_webrtc(false);
        }
        page.connect_permission_request(|_, request| {
            request.deny();
            true
        });
        let started = std::rc::Rc::new(std::cell::Cell::new(false));
        let failed = started.clone();
        let for_failure = app.clone();
        page.connect_load_failed(move |page, _, uri, _| {
            failed.set(true);
            update(&for_failure, token, uri, false, Some("The page could not be reached."), (page.can_go_back(), page.can_go_forward()));
            true
        });
        page.connect_load_changed(move |page, event| {
            if event == LoadEvent::Started {
                started.set(false);
            }
            if event == LoadEvent::Finished && !started.get() {
                if let Some(uri) = page.uri().filter(|uri| uri.as_str() != "about:blank") {
                    update(&app, token, uri.as_str(), false, None, (page.can_go_back(), page.can_go_forward()));
                }
            }
        });
        let _ = send.send(());
    })
    .map_err(|error| error.to_string())?;
    receive.await.map_err(|error| error.to_string())
}

#[cfg(windows)]
async fn configure(view: &Webview, app: AppHandle, token: u64) -> Result<(), String> {
    use webview2_com::Microsoft::Web::WebView2::Win32::COREWEBVIEW2_PERMISSION_STATE_DENY;
    use webview2_com::{take_pwstr, NavigationCompletedEventHandler, PermissionRequestedEventHandler};

    let (send, receive) = tokio::sync::oneshot::channel();
    view.with_webview(move |native| {
        let result = unsafe {
            (|| {
                let page = native.controller().CoreWebView2()?;
                let mut event_token = 0;
                page.add_PermissionRequested(
                    &PermissionRequestedEventHandler::create(Box::new(|_, details| {
                        if let Some(details) = details {
                            details.SetState(COREWEBVIEW2_PERMISSION_STATE_DENY)?;
                        }
                        Ok(())
                    })),
                    &mut event_token,
                )?;
                page.add_NavigationCompleted(
                    &NavigationCompletedEventHandler::create(Box::new(move |page, details| {
                        let (Some(page), Some(details)) = (page, details) else { return Ok(()) };
                        let mut success = Default::default();
                        details.IsSuccess(&mut success)?;
                        let mut source = Default::default();
                        page.Source(&mut source)?;
                        let url = take_pwstr(source);
                        if url == "about:blank" {
                            return Ok(());
                        }
                        let mut back = Default::default();
                        let mut forward = Default::default();
                        page.CanGoBack(&mut back)?;
                        page.CanGoForward(&mut forward)?;
                        update(
                            &app,
                            token,
                            &url,
                            false,
                            (!success.as_bool()).then_some("The page could not be reached."),
                            (back.as_bool(), forward.as_bool()),
                        );
                        Ok(())
                    })),
                    &mut event_token,
                )?;
                Ok::<_, webview2_com::Error>(())
            })()
        };
        let _ = send.send(result.map_err(|error| error.to_string()));
    })
    .map_err(|error| error.to_string())?;
    receive.await.map_err(|error| error.to_string())?
}
