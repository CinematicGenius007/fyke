//! Live changes from the daemon (`events.subscribe`, docs/api.md), on a second
//! connection that carries nothing else. When it drops, the stream waits a second and
//! resumes from the last sequence number it passed on.

use crate::rpc::{parse_reply, request_line, Client};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Duration;

pub struct Stream {
    pub last_seq: AtomicI64,
    pub stop: AtomicBool,
}

impl Stream {
    pub fn new(since: i64) -> Arc<Stream> {
        Arc::new(Stream { last_seq: AtomicI64::new(since), stop: AtomicBool::new(false) })
    }
}

/// Runs on its own thread until `stream.stop` is set, giving `emit` each event's params.
pub fn run(client: Arc<Client>, stream: Arc<Stream>, emit: impl Fn(Value)) {
    while !stream.stop.load(Ordering::SeqCst) {
        let _ = follow(&client, &stream, &emit);
        if stream.stop.load(Ordering::SeqCst) {
            return;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

fn follow(client: &Client, stream: &Stream, emit: &impl Fn(Value)) -> Result<(), String> {
    // The stream is quiet when nothing happens, so no read timeout.
    let mut connection = client.open(None).map_err(|e| e.message)?;
    // The app posts routine notifications itself, so the daemon leaves them to it.
    let params = json!({ "since_seq": stream.last_seq.load(Ordering::SeqCst), "notifies": true });
    connection.send(&request_line(1, "events.subscribe", &params).map_err(|e| e.message)?).map_err(|e| e.to_string())?;
    parse_reply(&connection.read_line().map_err(|e| e.to_string())?).map_err(|e| e.message)?;
    while !stream.stop.load(Ordering::SeqCst) {
        let line = connection.read_line().map_err(|e| e.to_string())?;
        let Ok(message) = serde_json::from_slice::<Value>(&line) else { continue };
        let Some(event) = message.get("params").filter(|p| p.is_object()) else { continue };
        if let Some(seq) = event.get("seq").and_then(Value::as_i64) {
            stream.last_seq.store(seq, Ordering::SeqCst);
        }
        emit(event.clone());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::socket::Listener;
    use std::io::{BufRead, BufReader, Write};
    use std::sync::mpsc;
    use std::thread;

    #[test]
    fn events_flow_and_resume_from_the_last_seq_after_a_drop() {
        let home = std::env::temp_dir().join(format!("fk-{}-events", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let listener = Listener::bind(home.join("fyked.sock")).unwrap();
        let (asked, asks) = mpsc::channel::<Value>();
        thread::spawn(move || {
            for (round, stream) in listener.incoming().enumerate() {
                let stream = stream.unwrap();
                let mut writer = stream.try_clone().unwrap();
                let mut line = String::new();
                BufReader::new(stream).read_line(&mut line).unwrap();
                asked.send(serde_json::from_str(&line).unwrap()).unwrap();
                writer.write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"seq\":0}}\n").unwrap();
                let first = 10 * (round as i64 + 1);
                for seq in [first, first + 1] {
                    writer
                        .write_all(
                            format!("{{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{{\"seq\":{seq},\"type\":\"entry.new\"}}}}\n")
                                .as_bytes(),
                        )
                        .unwrap();
                }
                // Dropping the connection makes the app reconnect.
            }
        });
        let client = Arc::new(Client::new(home.clone(), home.join("no-such-fyke")));
        let stream = Stream::new(5);
        let (sent, received) = mpsc::channel::<Value>();
        let running = stream.clone();
        thread::spawn(move || run(client, running, move |event| sent.send(event).unwrap()));

        let first = asks.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(first["method"], "events.subscribe");
        assert_eq!(first["params"], json!({"since_seq": 5, "notifies": true}));
        let seqs: Vec<i64> = (0..2).map(|_| received.recv_timeout(Duration::from_secs(5)).unwrap()["seq"].as_i64().unwrap()).collect();
        assert_eq!(seqs, [10, 11]);
        let second = asks.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(second["params"]["since_seq"], 11);
        assert_eq!(received.recv_timeout(Duration::from_secs(5)).unwrap()["seq"], 20);
        stream.stop.store(true, Ordering::SeqCst);
    }
}
