//! The remote webview is a child of the main window, with its own profile and no
//! capability. Its network route is installed before the first address loads.
//!
//! Every way a page can fail ends in a `fyke://page` update or a command error
//! that names a `Failure`. The window then hides the native webview and shows the
//! failure in its place, so a webview is never left on screen blank.

use crate::web_guard::{self, Failure, Failures, Proxy};
#[cfg(windows)]
use crate::web_profile;
use serde::{Deserialize, Serialize};
use std::fmt::Display;
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
    fn parts(self) -> Result<(LogicalPosition<f64>, LogicalSize<f64>), Failure> {
        if ![self.x, self.y, self.width, self.height].into_iter().all(|value| value.is_finite() && value >= 0.0) {
            return Err(setup("the page area is invalid"));
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
    error: Option<Failure>,
    can_go_back: bool,
    can_go_forward: bool,
}

fn update(app: &AppHandle, token: u64, url: &str, loading: bool, error: Option<Failure>, history: (bool, bool)) {
    let _ = app.emit_to("main", PAGE_EVENT, Update { token, url, loading, error, can_go_back: history.0, can_go_forward: history.1 });
}

/// The viewer could not start. The detail goes to the log; the window names the kind.
fn setup(error: impl Display) -> Failure {
    eprintln!("fyke-app: page viewer: {error}");
    Failure::Setup
}

/// Why the proxy could not reach `url`'s host, when it could not.
#[cfg_attr(not(any(windows, target_os = "linux")), allow(dead_code))]
fn cause(failures: &Failures, url: &str) -> Option<Failure> {
    let url = Url::parse(url).ok()?;
    failures.of(&url.host()?.to_string())
}

struct Session {
    webview: Webview,
    _proxy: Proxy,
    #[cfg(windows)]
    profile: std::path::PathBuf,
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.webview.close();
        #[cfg(windows)]
        web_profile::discard(self.profile.clone());
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
) -> Result<(), Failure> {
    let (position, size) = bounds.parts()?;
    let address = Url::parse(&url).map_err(|_| Failure::Blocked)?;
    let existing = {
        let mut slot = viewer.slot();
        slot.token = Some(token);
        slot.session.take()
    };
    drop(existing);
    web_guard::check_destination(&address).await?;
    let proxy = Proxy::start().await.map_err(setup)?;
    let failures = proxy.failures.clone();
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
                update(&for_download, token, url.as_str(), false, Some(Failure::Download), (false, false));
            }
            false
        });

    #[cfg(windows)]
    let (builder, directory) = {
        // Environment overrides could replace WebView2's profile or proxy.
        for key in ["WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", "WEBVIEW2_USER_DATA_FOLDER", "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER"] {
            if std::env::var_os(key).is_some() {
                return Err(Failure::Isolation);
            }
        }
        static SWEEP: std::sync::Once = std::sync::Once::new();
        SWEEP.call_once(|| {
            std::thread::spawn(|| web_profile::sweep(&std::env::temp_dir(), std::time::SystemTime::now() - web_profile::STALE));
        });
        let directory = web_profile::create(&std::env::temp_dir()).map_err(setup)?;
        let args = format!(
            "--proxy-server={} --proxy-bypass-list=<-loopback> --disable-quic --force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-features=msWebOOUI,msPdfOOUI",
            proxy.url
        );
        (builder.data_directory(directory.clone()).additional_browser_args(&args), directory)
    };
    #[cfg(target_os = "linux")]
    let builder = builder.proxy_url(proxy.url.clone());

    let parent = app.get_window(window.label()).ok_or_else(|| setup("the reader window closed"))?;
    let webview = match parent.add_child(builder, position, size) {
        Ok(webview) => webview,
        Err(error) => {
            #[cfg(windows)]
            web_profile::discard(directory);
            return Err(setup(error));
        }
    };
    let session = Session {
        webview: webview.clone(),
        _proxy: proxy,
        #[cfg(windows)]
        profile: directory,
    };
    {
        let mut slot = viewer.slot();
        if slot.token != Some(token) {
            return Ok(());
        }
        slot.session = Some(session);
    }

    if let Err(error) = configure(&webview, app, token, failures).await {
        close_viewer(viewer, token);
        return Err(setup(error));
    }
    if viewer.using(token).is_none() {
        return Ok(());
    }
    if let Err(error) = webview.navigate(address) {
        close_viewer(viewer, token);
        return Err(setup(error));
    }
    Ok(())
}

/// Closes the open page as the app quits. On Windows it then waits a few seconds
/// for profile folders still being removed, since their threads end with the process.
pub(crate) fn shutdown(app: &AppHandle) {
    let session = {
        let viewer = app.state::<Viewer>();
        let mut slot = viewer.slot();
        slot.token = None;
        slot.session.take()
    };
    drop(session);
    #[cfg(windows)]
    web_profile::finish(std::time::Duration::from_secs(7));
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
pub(crate) fn position_viewer(viewer: State<'_, Viewer>, token: u64, bounds: Bounds, visible: bool) -> Result<(), Failure> {
    let Some(webview) = viewer.using(token) else { return Ok(()) };
    let (position, size) = bounds.parts()?;
    webview.set_bounds(tauri::Rect { position: position.into(), size: size.into() }).map_err(setup)?;
    if visible { webview.show() } else { webview.hide() }.map_err(setup)
}

#[tauri::command]
pub(crate) fn navigate_viewer(viewer: State<'_, Viewer>, token: u64, action: &str) -> Result<(), Failure> {
    let Some(webview) = viewer.using(token) else { return Ok(()) };
    let script = match action {
        "back" => "history.back()",
        "forward" => "history.forward()",
        "reload" => "location.reload()",
        _ => return Err(setup(format!("unknown page action {action:?}"))),
    };
    webview.eval(script).map_err(setup)
}

#[cfg(target_os = "linux")]
async fn configure(view: &Webview, app: AppHandle, token: u64, failures: Failures) -> Result<(), String> {
    use webkit2gtk::{LoadEvent, NetworkError, PermissionRequestExt, PolicyError, SettingsExt, WebProcessTerminationReason, WebViewExt};
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
        let refused = started.clone();
        let for_failure = app.clone();
        let for_tls = app.clone();
        let for_crash = app.clone();
        page.connect_load_failed(move |page, _, uri, error| {
            // A load replaced by another, or stopped by the navigation and download
            // handlers (which report it themselves), is not a failure of the page.
            if error.matches(NetworkError::Cancelled) || error.matches(PolicyError::FrameLoadInterruptedByPolicyChange) {
                return false;
            }
            failed.set(true);
            let failure = cause(&failures, uri).unwrap_or(Failure::Unknown);
            update(&for_failure, token, uri, false, Some(failure), (page.can_go_back(), page.can_go_forward()));
            true
        });
        page.connect_load_failed_with_tls_errors(move |page, uri, _, _| {
            refused.set(true);
            update(&for_tls, token, uri, false, Some(Failure::Tls), (page.can_go_back(), page.can_go_forward()));
            true
        });
        page.connect_web_process_terminated(move |page, reason| {
            if reason != WebProcessTerminationReason::TerminatedByApi {
                let uri = page.uri().unwrap_or_default();
                update(&for_crash, token, uri.as_str(), false, Some(Failure::Crashed), (false, false));
            }
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
async fn configure(view: &Webview, app: AppHandle, token: u64, failures: Failures) -> Result<(), String> {
    use webview2_com::Microsoft::Web::WebView2::Win32::*;
    use webview2_com::{take_pwstr, NavigationCompletedEventHandler, PermissionRequestedEventHandler, ProcessFailedEventHandler};

    /// Names a failed navigation. Certificate errors reach the webview as they are;
    /// a failed tunnel reaches it only as a proxy error, so the proxy's record of the
    /// host comes before the webview's own status.
    fn failure(status: COREWEBVIEW2_WEB_ERROR_STATUS, failures: &Failures, url: &str) -> Failure {
        let certificate = [
            COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_COMMON_NAME_IS_INCORRECT,
            COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_EXPIRED,
            COREWEBVIEW2_WEB_ERROR_STATUS_CLIENT_CERTIFICATE_CONTAINS_ERRORS,
            COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_REVOKED,
            COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_IS_INVALID,
        ];
        if certificate.contains(&status) {
            return Failure::Tls;
        }
        cause(failures, url).unwrap_or(if status == COREWEBVIEW2_WEB_ERROR_STATUS_HOST_NAME_NOT_RESOLVED {
            Failure::Dns
        } else if status == COREWEBVIEW2_WEB_ERROR_STATUS_TIMEOUT {
            Failure::Timeout
        } else {
            Failure::Unknown
        })
    }

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
                let for_crash = app.clone();
                page.add_ProcessFailed(
                    &ProcessFailedEventHandler::create(Box::new(move |page, details| {
                        let Some(details) = details else { return Ok(()) };
                        let mut kind = COREWEBVIEW2_PROCESS_FAILED_KIND::default();
                        details.ProcessFailedKind(&mut kind)?;
                        // Other processes (GPU, utilities, a subframe's renderer) restart on their own.
                        let fatal = [
                            COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED,
                            COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED,
                            COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_UNRESPONSIVE,
                        ];
                        if !fatal.contains(&kind) {
                            return Ok(());
                        }
                        let mut source = Default::default();
                        let url = match page.map(|page| page.Source(&mut source)) {
                            Some(Ok(())) => take_pwstr(source),
                            _ => String::new(),
                        };
                        update(&for_crash, token, &url, false, Some(Failure::Crashed), (false, false));
                        Ok(())
                    })),
                    &mut event_token,
                )?;
                page.add_NavigationCompleted(
                    &NavigationCompletedEventHandler::create(Box::new(move |page, details| {
                        let (Some(page), Some(details)) = (page, details) else { return Ok(()) };
                        let mut success = Default::default();
                        details.IsSuccess(&mut success)?;
                        let mut status = COREWEBVIEW2_WEB_ERROR_STATUS::default();
                        details.WebErrorStatus(&mut status)?;
                        // A navigation replaced by another, or stopped by the navigation and
                        // download handlers (which report it themselves), is not a failure.
                        if !success.as_bool() && status == COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED {
                            return Ok(());
                        }
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
                            (!success.as_bool()).then(|| failure(status, &failures, &url)),
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
