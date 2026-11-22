//! Calls to the daemon: newline-delimited JSON-RPC 2.0 over its socket (docs/api.md),
//! as gui/Sources/Reader/Daemon.swift makes them.
//!
//! Quick calls share one connection with a 35 second read timeout. Slow calls, the ones
//! that touch the network, open their own with 120 seconds, so they cannot hold up the
//! rest. A read-only call whose connection drops is sent once more on a new connection.
//! Any other call whose reply is lost fails as "outcome unknown" and is never sent
//! again: the daemon may have done it.

use crate::socket::{self, Stream};
use serde::Serialize;
use serde_json::{json, Value};
use std::io::{self, BufRead, BufReader, ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

/// The daemon closes a connection whose request line is longer (`max_request` in src/daemon.zig).
pub const MAX_REQUEST: usize = 1 << 20;
pub const QUICK_TIMEOUT: Duration = Duration::from_secs(35);
pub const SLOW_TIMEOUT: Duration = Duration::from_secs(120);

/// Methods that change nothing, so sending one twice is harmless.
const READ_ONLY: &[&str] = &[
    "ai.checks",
    "answers.get",
    "artifacts.get",
    "artifacts.list",
    "briefs.get",
    "briefs.list",
    "config.get",
    "db.query",
    "entries.get",
    "entries.list",
    "entries.search",
    "entries.similar",
    "events.since",
    "feeds.get",
    "feeds.list",
    "folders.list",
    "jobs.list",
    "lenses.list",
    "ops.list",
    "recipes.get",
    "recipes.history",
    "recipes.list",
    "routines.get",
    "routines.list",
    "routines.runs",
    "schema.describe",
    "stats.get",
    "storage.get",
    "stories.get",
    "stories.list",
    "views.get",
    "views.list",
    "views.preview",
    "writers.list",
];

pub fn is_read_only(method: &str) -> bool {
    READ_ONLY.contains(&method)
}

/// Why a call failed, as the UI receives it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RpcError {
    pub message: String,
    /// The daemon's name for a refusal (`data.kind`), such as `RevisionConflict`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    /// The request may have reached the daemon and been done; nobody knows.
    pub unknown: bool,
}

impl RpcError {
    pub fn new(message: impl Into<String>) -> RpcError {
        RpcError { message: message.into(), kind: None, code: None, data: None, unknown: false }
    }

    fn unknown(method: &str) -> RpcError {
        RpcError {
            message: format!("The connection to the background service dropped, so Fyke cannot tell whether {method} was done"),
            kind: Some("outcome_unknown".into()),
            unknown: true,
            ..RpcError::new("")
        }
    }
}

/// The line sent for one request, newline included.
pub fn request_line(id: u64, method: &str, params: &Value) -> Result<Vec<u8>, RpcError> {
    let request = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
    let mut line = serde_json::to_vec(&request).map_err(|e| RpcError::new(e.to_string()))?;
    line.push(b'\n');
    if line.len() > MAX_REQUEST {
        return Err(RpcError { kind: Some("too_large".into()), ..RpcError::new("The request is larger than 1 MiB") });
    }
    Ok(line)
}

/// The result of a reply line, or the daemon's refusal.
pub fn parse_reply(line: &[u8]) -> Result<Value, RpcError> {
    let reply: Value = serde_json::from_slice(line).map_err(|_| RpcError::new("The daemon sent a reply Fyke cannot read"))?;
    if let Some(error) = reply.get("error").filter(|e| !e.is_null()) {
        let data = error.get("data").filter(|d| !d.is_null()).cloned();
        return Err(RpcError {
            message: error.get("message").and_then(Value::as_str).unwrap_or("The daemon refused").to_string(),
            kind: data.as_ref().and_then(|d| d.get("kind")).and_then(Value::as_str).map(String::from),
            code: error.get("code").and_then(Value::as_i64),
            data,
            unknown: false,
        });
    }
    match reply.get("result") {
        Some(result) if !result.is_null() || reply.as_object().is_some_and(|o| o.contains_key("result")) => Ok(result.clone()),
        _ => Err(RpcError::new("The daemon sent an empty reply")),
    }
}

/// One open connection. Replies come in request order.
pub struct Connection {
    writer: Stream,
    reader: BufReader<Stream>,
}

impl Connection {
    pub fn open(path: &Path, timeout: Option<Duration>) -> io::Result<Connection> {
        let stream = socket::connect(path, timeout)?;
        let reader = BufReader::new(stream.try_clone()?);
        Ok(Connection { writer: stream, reader })
    }

    pub fn send(&mut self, line: &[u8]) -> io::Result<()> {
        self.writer.write_all(line)?;
        self.writer.flush()
    }

    /// Whether the daemon still has this connection open. Checked before reuse, so a
    /// daemon that restarted since is noticed before a request is lost to it.
    pub fn is_open(&mut self) -> bool {
        if !self.reader.buffer().is_empty() || self.writer.set_nonblocking(true).is_err() {
            return false;
        }
        let open = matches!(self.reader.fill_buf(), Err(error) if error.kind() == ErrorKind::WouldBlock);
        open && self.writer.set_nonblocking(false).is_ok()
    }

    pub fn read_line(&mut self) -> io::Result<Vec<u8>> {
        let mut line = Vec::new();
        let count = self.reader.read_until(b'\n', &mut line)?;
        if count == 0 || line.last() != Some(&b'\n') {
            return Err(io::Error::new(ErrorKind::UnexpectedEof, "the daemon closed the connection"));
        }
        line.pop();
        Ok(line)
    }
}

/// A send that failed because the other end had already gone, so nothing was read.
fn peer_was_gone(error: &io::Error) -> bool {
    matches!(error.kind(), ErrorKind::BrokenPipe | ErrorKind::ConnectionReset | ErrorKind::NotConnected | ErrorKind::ConnectionAborted)
}

/// Every call from this app.
pub struct Client {
    home: PathBuf,
    program: PathBuf,
    shared: Mutex<Option<Connection>>,
    next_id: AtomicU64,
    paused: AtomicBool,
}

impl Client {
    pub fn new(home: PathBuf, program: PathBuf) -> Client {
        Client { home, program, shared: Mutex::new(None), next_id: AtomicU64::new(1), paused: AtomicBool::new(false) }
    }

    pub fn home(&self) -> &Path {
        &self.home
    }

    pub fn program(&self) -> &Path {
        &self.program
    }

    pub fn socket_path(&self) -> PathBuf {
        self.home.join(crate::paths::SOCKET_FILE)
    }

    /// While the data folder moves, a missing daemon is expected and must not be restarted.
    pub fn set_paused(&self, paused: bool) {
        self.paused.store(paused, Ordering::SeqCst);
        if paused {
            *self.shared.lock().unwrap_or_else(|e| e.into_inner()) = None;
        }
    }

    /// A connection, starting the daemon when nothing answers.
    pub fn open(&self, timeout: Option<Duration>) -> Result<Connection, RpcError> {
        let path = self.socket_path();
        if let Ok(connection) = Connection::open(&path, timeout) {
            return Ok(connection);
        }
        if self.paused.load(Ordering::SeqCst) {
            return Err(RpcError::new("The data folder is moving"));
        }
        self.start_daemon()?;
        for _ in 0..300 {
            if let Ok(connection) = Connection::open(&path, timeout) {
                return Ok(connection);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        Err(RpcError::new("The background service did not start"))
    }

    fn start_daemon(&self) -> Result<(), RpcError> {
        let missing = || RpcError::new(format!("Cannot find the fyke program at {}", self.program.display()));
        if !is_executable(&self.program) {
            return Err(missing());
        }
        std::fs::create_dir_all(&self.home).map_err(|e| RpcError::new(format!("Cannot make {}: {e}", self.home.display())))?;
        let mut command = Command::new(&self.program);
        command.args(["daemon", "--log"]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            // CREATE_NO_WINDOW | DETACHED_PROCESS: no console flashes up, and the
            // daemon outlives the app.
            command.creation_flags(0x0800_0000 | 0x0000_0008);
        }
        command.spawn().map(drop).map_err(|_| missing())
    }

    fn id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::Relaxed)
    }

    /// A call on the shared connection.
    pub fn call(&self, method: &str, params: &Value) -> Result<Value, RpcError> {
        let mut shared = self.shared.lock().unwrap_or_else(|e| e.into_inner());
        let read_only = is_read_only(method);
        let mut attempts = 0;
        loop {
            attempts += 1;
            let line = request_line(self.id(), method, params)?;
            if shared.as_mut().is_some_and(|connection| !connection.is_open()) {
                *shared = None;
            }
            let connection = match shared.as_mut() {
                Some(connection) => connection,
                None => shared.insert(self.open(Some(QUICK_TIMEOUT))?),
            };
            let outcome = exchange(connection, &line);
            match outcome {
                Ok(reply) => return parse_reply(&reply),
                Err(Lost::BeforeSending(_)) if attempts == 1 => *shared = None,
                Err(Lost::AfterSending(_)) if attempts == 1 && read_only => *shared = None,
                Err(Lost::TimedOut) => {
                    *shared = None;
                    return Err(if read_only {
                        RpcError::new("The background service did not answer in time")
                    } else {
                        RpcError::unknown(method)
                    });
                }
                Err(Lost::BeforeSending(error)) => {
                    *shared = None;
                    return Err(RpcError::new(format!("Cannot reach the background service: {error}")));
                }
                Err(Lost::AfterSending(error)) => {
                    *shared = None;
                    return Err(if read_only {
                        RpcError::new(format!("Cannot reach the background service: {error}"))
                    } else {
                        RpcError::unknown(method)
                    });
                }
            }
        }
    }

    /// A call on its own connection, for work that waits on the network.
    pub fn call_slow(&self, method: &str, params: &Value) -> Result<Value, RpcError> {
        let line = request_line(self.id(), method, params)?;
        let mut connection = self.open(Some(SLOW_TIMEOUT))?;
        match exchange(&mut connection, &line) {
            Ok(reply) => parse_reply(&reply),
            Err(Lost::BeforeSending(error)) => Err(RpcError::new(format!("Cannot reach the background service: {error}"))),
            Err(_) if is_read_only(method) => Err(RpcError::new("The background service did not answer in time")),
            Err(_) => Err(RpcError::unknown(method)),
        }
    }
}

enum Lost {
    /// The daemon had closed the connection before this request, so it never saw it.
    BeforeSending(io::Error),
    AfterSending(io::Error),
    TimedOut,
}

fn exchange(connection: &mut Connection, line: &[u8]) -> Result<Vec<u8>, Lost> {
    connection.send(line).map_err(|error| if peer_was_gone(&error) { Lost::BeforeSending(error) } else { Lost::AfterSending(error) })?;
    connection.read_line().map_err(|error| match error.kind() {
        ErrorKind::WouldBlock | ErrorKind::TimedOut => Lost::TimedOut,
        _ => Lost::AfterSending(error),
    })
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::socket::Listener;
    use std::io::Read;
    use std::sync::Arc;
    use std::thread;

    fn scratch(name: &str) -> PathBuf {
        // Short, because socket paths are limited to about 100 bytes.
        let dir = std::env::temp_dir().join(format!("fk-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A daemon stand-in. `answer` gets each request and says what to write back:
    /// Some(line) answers, None closes the connection without answering.
    fn serve(home: &Path, answer: impl Fn(Value) -> Option<String> + Send + Sync + 'static) -> Arc<AtomicU64> {
        let listener = Listener::bind(home.join("fyked.sock")).unwrap();
        let seen = Arc::new(AtomicU64::new(0));
        let counter = seen.clone();
        let answer = Arc::new(answer);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let answer = answer.clone();
                let counter = counter.clone();
                thread::spawn(move || {
                    let mut writer = stream.try_clone().unwrap();
                    let mut reader = BufReader::new(stream);
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 {
                            return;
                        }
                        counter.fetch_add(1, Ordering::SeqCst);
                        let request: Value = serde_json::from_str(&line).unwrap();
                        match answer(request) {
                            Some(reply) => writer.write_all(format!("{reply}\n").as_bytes()).unwrap(),
                            None => return,
                        }
                    }
                });
            }
        });
        seen
    }

    fn client(home: &Path) -> Client {
        Client::new(home.to_path_buf(), home.join("no-such-fyke"))
    }

    #[test]
    fn requests_are_json_rpc_lines() {
        let line = request_line(7, "feeds.list", &json!({})).unwrap();
        assert_eq!(String::from_utf8(line).unwrap(), "{\"id\":7,\"jsonrpc\":\"2.0\",\"method\":\"feeds.list\",\"params\":{}}\n");
    }

    #[test]
    fn a_request_over_one_mebibyte_is_refused_before_sending() {
        let big = "x".repeat(MAX_REQUEST);
        let error = request_line(1, "notes.add", &json!({ "text": big })).unwrap_err();
        assert_eq!(error.kind.as_deref(), Some("too_large"));
        let fits = "x".repeat(MAX_REQUEST - 200);
        assert!(request_line(1, "notes.add", &json!({ "text": fits })).is_ok());
    }

    #[test]
    fn replies_give_the_result_or_the_refusal() {
        assert_eq!(parse_reply(br#"{"jsonrpc":"2.0","id":1,"result":{"a":1}}"#).unwrap(), json!({"a":1}));
        assert_eq!(parse_reply(br#"{"jsonrpc":"2.0","id":1,"result":null}"#).unwrap(), Value::Null);
        let refusal =
            parse_reply(br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Taken","data":{"kind":"in_use","views":[2]}}}"#)
                .unwrap_err();
        assert_eq!(refusal.message, "Taken");
        assert_eq!(refusal.kind.as_deref(), Some("in_use"));
        assert_eq!(refusal.code, Some(-32000));
        assert!(!refusal.unknown);
        assert_eq!(parse_reply(br#"{"jsonrpc":"2.0","id":1}"#).unwrap_err().message, "The daemon sent an empty reply");
    }

    #[test]
    fn calls_share_one_connection() {
        let home = scratch("share");
        serve(&home, |request| Some(json!({"jsonrpc":"2.0","id":request["id"],"result":request["method"]}).to_string()));
        let client = client(&home);
        assert_eq!(client.call("feeds.list", &json!({})).unwrap(), json!("feeds.list"));
        assert_eq!(client.call("entries.mark", &json!({"id":1})).unwrap(), json!("entries.mark"));
        assert!(client.shared.lock().unwrap().is_some());
    }

    #[test]
    fn a_lost_reply_to_a_change_is_outcome_unknown_and_not_sent_again() {
        let home = scratch("unknown");
        let seen = serve(&home, |request| {
            if request["method"] == "entries.mark" {
                None
            } else {
                Some(json!({"jsonrpc":"2.0","id":request["id"],"result":true}).to_string())
            }
        });
        let client = client(&home);
        let error = client.call("entries.mark", &json!({"id":1})).unwrap_err();
        assert!(error.unknown);
        assert_eq!(error.kind.as_deref(), Some("outcome_unknown"));
        assert_eq!(seen.load(Ordering::SeqCst), 1);
        // The next call opens a new connection and works.
        assert_eq!(client.call("feeds.list", &json!({})).unwrap(), json!(true));
    }

    #[test]
    fn a_lost_reply_to_a_read_is_sent_once_more() {
        let home = scratch("retry");
        let first = Arc::new(AtomicBool::new(true));
        let flag = first.clone();
        let seen = serve(&home, move |request| {
            if flag.swap(false, Ordering::SeqCst) {
                None
            } else {
                Some(json!({"jsonrpc":"2.0","id":request["id"],"result":[1]}).to_string())
            }
        });
        let client = client(&home);
        assert_eq!(client.call("feeds.list", &json!({})).unwrap(), json!([1]));
        assert_eq!(seen.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn a_closed_connection_is_reopened_before_a_change_is_sent() {
        let home = scratch("stale");
        let seen = serve(&home, |request| Some(json!({"jsonrpc":"2.0","id":request["id"],"result":"ok"}).to_string()));
        let client = client(&home);
        client.call("feeds.list", &json!({})).unwrap();
        // The daemon restarts: the cached connection's far end is gone.
        {
            let mut shared = client.shared.lock().unwrap();
            let stale = shared.as_mut().unwrap();
            stale.writer.shutdown(std::net::Shutdown::Both).unwrap();
        }
        assert_eq!(client.call("entries.mark", &json!({"id":1})).unwrap(), json!("ok"));
        assert_eq!(seen.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn no_daemon_and_no_program_says_where_it_looked() {
        let home = scratch("missing");
        let error = client(&home).call("feeds.list", &json!({})).unwrap_err();
        assert!(error.message.starts_with("Cannot find the fyke program at "), "{}", error.message);
    }

    #[test]
    fn a_paused_client_does_not_start_the_daemon() {
        let home = scratch("paused");
        let client = client(&home);
        client.set_paused(true);
        assert_eq!(client.call("feeds.list", &json!({})).unwrap_err().message, "The data folder is moving");
    }

    #[test]
    fn a_slow_call_has_its_own_connection() {
        let home = scratch("slow");
        serve(&home, |request| Some(json!({"jsonrpc":"2.0","id":request["id"],"result":"fetched"}).to_string()));
        let client = client(&home);
        assert_eq!(client.call_slow("entries.fetch_full", &json!({"id":3})).unwrap(), json!("fetched"));
        assert!(client.shared.lock().unwrap().is_none());
    }

    #[test]
    fn a_daemon_that_closes_mid_line_is_an_error() {
        let home = scratch("partial");
        let listener = Listener::bind(home.join("fyked.sock")).unwrap();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0u8; 256];
            let _ = stream.read(&mut buffer);
            stream.write_all(b"{\"jsonrpc\":\"2.0\"").unwrap();
        });
        let error = client(&home).call("entries.mark", &json!({})).unwrap_err();
        assert!(error.unknown);
    }
}
