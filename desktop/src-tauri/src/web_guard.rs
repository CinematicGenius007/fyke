//! The page viewer reaches the network through a loopback SOCKS endpoint. Each
//! connection resolves once, rejects non-public answers and dials a validated
//! IP address directly. A page's redirects and subresources use the same boundary.
//!
//! A tunnel that moves no bytes for a while is closed, so long-lived sockets
//! (event streams, beacons, idle keep-alive) cannot hold every slot. When every
//! slot is taken, a new request is answered with a refusal at once rather than
//! left waiting in the listen backlog, so the page fails fast instead of stalling.
//!
//! A webview reports a failed tunnel only as a generic proxy error, so the proxy
//! keeps the latest cause for each host it could not reach (`Failures`), and the
//! viewer names that cause when the page fails.

use serde::Serialize;
use std::collections::HashMap;
use std::io::{self, ErrorKind};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::async_runtime::{self, JoinHandle};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{lookup_host, TcpListener, TcpStream};
use tokio::task::JoinSet;
use tokio::time::{sleep, timeout};
use url::{Host, Url};

const PRIVATE: &str = "This page is on a private address, so it stays out of the app.";
const HANDSHAKE: Duration = Duration::from_secs(12);
/// How long after one address the next is tried, as in RFC 8305 (Happy Eyeballs).
const STAGGER: Duration = Duration::from_millis(250);
/// Idle connections are probed, so a peer that vanished is noticed and its tunnel freed.
const KEEPALIVE: Duration = Duration::from_secs(30);
/// Hosts whose last failure is kept. Past this the record starts again.
const MAX_FAILURES: usize = 64;
/// Requests answered with a refusal while every slot is busy. Beyond this the
/// connection is closed unanswered, which the page also sees as a failure.
const MAX_REFUSING: usize = 32;

fn public_ipv4(ip: Ipv4Addr) -> bool {
    let [a, b, c, _] = ip.octets();
    !(ip.is_private()
        || ip.is_loopback()
        || ip.is_link_local()
        || ip.is_documentation()
        || a == 0
        || a >= 224
        || (a == 100 && (64..=127).contains(&b))
        || (a == 192 && b == 0 && c == 0)
        || (a == 192 && b == 88 && c == 99)
        || (a == 198 && matches!(b, 18 | 19)))
}

fn public_ipv6(ip: Ipv6Addr) -> bool {
    let [first, second, ..] = ip.segments();
    // Allow global unicast, excluding special-use and transition prefixes. A
    // mapped private IPv4 address is outside global unicast too.
    (0x2000..=0x3fff).contains(&first)
        && !(first == 0x2001 && (second < 0x0200 || second == 0x0db8))
        && first != 0x2002
        && !(first == 0x3fff && second < 0x1000)
}

fn public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => public_ipv4(ip),
        IpAddr::V6(ip) => public_ipv6(ip),
    }
}

fn public_host(host: &Host<&str>) -> bool {
    match host {
        Host::Ipv4(ip) => public_ipv4(*ip),
        Host::Ipv6(ip) => public_ipv6(*ip),
        Host::Domain(domain) => {
            let domain = domain.trim_end_matches('.');
            domain.contains('.')
                && ![".localhost", ".local", ".lan", ".internal", ".home.arpa"].iter().any(|suffix| domain.ends_with(suffix))
        }
    }
}

/// Why a page did not open. The window shows one plain sentence for each.
// Some kinds come only from the webview handlers, which the Mac's tests do not build.
#[cfg_attr(not(any(windows, target_os = "linux")), allow(dead_code))]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Failure {
    /// The name did not resolve.
    Dns,
    /// The site's certificate was refused.
    Tls,
    /// The address, or what its name resolved to, is not public.
    Private,
    /// The site refused the connection.
    Refused,
    /// The site did not answer in time.
    Timeout,
    /// The page's process ended.
    Crashed,
    /// The address is a download.
    Download,
    /// The address is not an http or https page Fyke opens.
    Blocked,
    /// A WebView2 environment variable would replace the page's profile or route.
    Isolation,
    /// The viewer itself could not start.
    Setup,
    Unknown,
}

impl From<&io::Error> for Failure {
    fn from(error: &io::Error) -> Self {
        match error.kind() {
            ErrorKind::PermissionDenied => Self::Private,
            ErrorKind::NotFound => Self::Dns,
            ErrorKind::ConnectionRefused => Self::Refused,
            ErrorKind::TimedOut => Self::Timeout,
            _ => Self::Unknown,
        }
    }
}

pub fn allowed_url(url: &Url) -> Result<(), Failure> {
    if !matches!(url.scheme(), "http" | "https") || !url.username().is_empty() || url.password().is_some() {
        return Err(Failure::Blocked);
    }
    if url.host().is_none_or(|host| !public_host(&host)) {
        return Err(Failure::Private);
    }
    Ok(())
}

fn denied() -> io::Error {
    io::Error::new(ErrorKind::PermissionDenied, PRIVATE)
}

async fn addresses(host: Host<&str>, port: u16, public_only: bool) -> io::Result<Vec<SocketAddr>> {
    if port == 0 || (public_only && !public_host(&host)) {
        return Err(denied());
    }
    let resolved: Vec<SocketAddr> = match host {
        // The root dot keeps the resolver from applying local search domains.
        Host::Domain(name) => lookup_host((format!("{}.", name.trim_end_matches('.')).as_str(), port))
            .await
            .map_err(|error| io::Error::new(ErrorKind::NotFound, error))?
            .collect(),
        Host::Ipv4(ip) => vec![SocketAddr::new(ip.into(), port)],
        Host::Ipv6(ip) => vec![SocketAddr::new(ip.into(), port)],
    };
    if resolved.is_empty() {
        return Err(io::Error::new(ErrorKind::NotFound, "The name has no address."));
    }
    if public_only && resolved.iter().any(|address| !public_ip(address.ip())) {
        return Err(denied());
    }
    Ok(resolved)
}

pub async fn check_destination(url: &Url) -> Result<(), Failure> {
    allowed_url(url)?;
    timeout(HANDSHAKE, addresses(url.host().expect("URL guard checks this"), url.port_or_known_default().unwrap_or(0), true))
        .await
        .map_err(|_| Failure::Timeout)?
        .map(|_| ())
        .map_err(|error| Failure::from(&error))
}

/// The latest reason the proxy could not reach each host, keyed as `url::Host`
/// prints it. A later tunnel that opens clears the host's entry.
#[derive(Clone, Default)]
pub struct Failures(Arc<Mutex<HashMap<String, Failure>>>);

impl Failures {
    pub fn of(&self, host: &str) -> Option<Failure> {
        self.0.lock().unwrap_or_else(|error| error.into_inner()).get(host).copied()
    }

    fn record(&self, host: &str, failure: Option<Failure>) {
        let mut hosts = self.0.lock().unwrap_or_else(|error| error.into_inner());
        match failure {
            Some(failure) => {
                if hosts.len() >= MAX_FAILURES && !hosts.contains_key(host) {
                    hosts.clear();
                }
                hosts.insert(host.to_owned(), failure);
            }
            None => {
                hosts.remove(host);
            }
        }
    }
}

/// How many tunnels the proxy holds open, and when a quiet one is closed.
#[derive(Clone, Copy)]
pub struct Limits {
    pub connections: usize,
    pub idle: Duration,
    /// Tests reach a listener on this machine; the app never sets it.
    #[cfg(test)]
    local: bool,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            connections: 256,
            idle: Duration::from_secs(90),
            #[cfg(test)]
            local: false,
        }
    }
}

pub struct Proxy {
    pub url: Url,
    pub failures: Failures,
    task: JoinHandle<()>,
}

impl Proxy {
    pub async fn start() -> io::Result<Self> {
        Self::with(Limits::default()).await
    }

    pub async fn with(limits: Limits) -> io::Result<Self> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let url = Url::parse(&format!("socks5://{}", listener.local_addr()?)).expect("valid local SOCKS address");
        let failures = Failures::default();
        let record = failures.clone();
        let task = async_runtime::spawn(async move {
            let mut active = JoinSet::new();
            let mut refusing = JoinSet::new();
            loop {
                tokio::select! {
                    ready = listener.accept() => {
                        let Ok((socket, _)) = ready else { break };
                        if active.len() < limits.connections {
                            let record = record.clone();
                            active.spawn(async move { let _ = forward(socket, limits, record).await; });
                        } else if refusing.len() < MAX_REFUSING {
                            refusing.spawn(async move { let _ = refuse(socket).await; });
                        }
                        // Otherwise the socket drops here, and the page sees it close.
                    }
                    _ = active.join_next(), if !active.is_empty() => {}
                    _ = refusing.join_next(), if !refusing.is_empty() => {}
                }
            }
        });
        Ok(Self { url, failures, task })
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Why a request got no tunnel, as the SOCKS reply code (RFC 1928, section 6) tells it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Refusal {
    General = 1,
    NotAllowed = 2,
    HostUnreachable = 4,
    ConnectionRefused = 5,
    TimedOut = 6,
}

impl From<&io::Error> for Refusal {
    fn from(error: &io::Error) -> Self {
        match error.kind() {
            ErrorKind::PermissionDenied => Self::NotAllowed,
            ErrorKind::NotFound | ErrorKind::HostUnreachable | ErrorKind::NetworkUnreachable => Self::HostUnreachable,
            ErrorKind::ConnectionRefused => Self::ConnectionRefused,
            ErrorKind::TimedOut => Self::TimedOut,
            _ => Self::General,
        }
    }
}

async fn reply(to: &mut TcpStream, code: u8) -> io::Result<()> {
    // BND.ADDR and BND.PORT are unused for CONNECT.
    to.write_all(&[5, code, 0, 1, 0, 0, 0, 0, 0, 0]).await
}

async fn forward(mut from: TcpStream, limits: Limits, failures: Failures) -> io::Result<()> {
    let (host, port) = match timeout(HANDSHAKE, request(&mut from)).await {
        Ok(Ok(destination)) => destination,
        Ok(Err(error)) => return reply(&mut from, Refusal::from(&error) as u8).await,
        Err(_) => return reply(&mut from, Refusal::TimedOut as u8).await,
    };
    let name = host.to_string();
    // The cause is recorded before the reply, so it is there when the page reports the failure.
    let target = match timeout(HANDSHAKE, connect(host, port, limits)).await {
        Ok(Ok(target)) => target,
        Ok(Err(error)) => {
            failures.record(&name, Some(Failure::from(&error)));
            return reply(&mut from, Refusal::from(&error) as u8).await;
        }
        Err(_) => {
            failures.record(&name, Some(Failure::Timeout));
            return reply(&mut from, Refusal::TimedOut as u8).await;
        }
    };
    failures.record(&name, None);
    reply(&mut from, 0).await?;
    relay(from, target, limits.idle).await
}

/// Answers a request with "connection refused" while every slot is busy.
async fn refuse(mut from: TcpStream) -> io::Result<()> {
    timeout(HANDSHAKE, async {
        request(&mut from).await?;
        reply(&mut from, Refusal::ConnectionRefused as u8).await
    })
    .await?
}

/// Copies both ways until both sides finish, or until no byte has moved in either
/// direction for `idle`. Each direction runs on its own, so a full buffer one way
/// never stalls the other.
async fn relay(client: TcpStream, target: TcpStream, idle: Duration) -> io::Result<()> {
    let started = Instant::now();
    let moved = AtomicU64::new(0);
    let (client_read, client_write) = client.into_split();
    let (target_read, target_write) = target.into_split();
    let both =
        async { tokio::try_join!(pipe(client_read, target_write, &moved, started), pipe(target_read, client_write, &moved, started)) };
    tokio::pin!(both);
    let check = (idle / 4).max(Duration::from_millis(10));
    loop {
        tokio::select! {
            done = &mut both => return done.map(|_| ()),
            _ = sleep(check) => {
                let quiet = started.elapsed().saturating_sub(Duration::from_millis(moved.load(Ordering::Relaxed)));
                if quiet >= idle {
                    return Err(io::Error::new(ErrorKind::TimedOut, "The connection was idle."));
                }
            }
        }
    }
}

async fn pipe(mut from: impl AsyncRead + Unpin, mut to: impl AsyncWrite + Unpin, moved: &AtomicU64, started: Instant) -> io::Result<()> {
    let mut buffer = vec![0u8; 16 * 1024];
    loop {
        let size = from.read(&mut buffer).await?;
        if size == 0 {
            return to.shutdown().await;
        }
        moved.store(started.elapsed().as_millis() as u64, Ordering::Relaxed);
        to.write_all(&buffer[..size]).await?;
        moved.store(started.elapsed().as_millis() as u64, Ordering::Relaxed);
    }
}

/// Reads the greeting and the CONNECT request, and returns the destination.
async fn request(from: &mut TcpStream) -> io::Result<(Host, u16)> {
    let mut greeting = [0u8; 2];
    from.read_exact(&mut greeting).await?;
    if greeting[0] != 5 || greeting[1] == 0 {
        return Err(denied());
    }
    let mut methods = [0u8; 255];
    let methods = &mut methods[..greeting[1].into()];
    from.read_exact(methods).await?;
    if !methods.contains(&0) {
        from.write_all(&[5, 255]).await?;
        return Err(denied());
    }
    from.write_all(&[5, 0]).await?;

    let mut request = [0u8; 4];
    from.read_exact(&mut request).await?;
    if request[..3] != [5, 1, 0] {
        return Err(denied());
    }
    let host = match request[3] {
        1 => Host::Ipv4(Ipv4Addr::from(from.read_u32().await?)),
        4 => Host::Ipv6(Ipv6Addr::from(from.read_u128().await?)),
        3 => {
            let mut name = [0u8; 255];
            let size: usize = from.read_u8().await?.into();
            from.read_exact(&mut name[..size]).await?;
            let name = std::str::from_utf8(&name[..size]).map_err(|_| denied())?;
            // The WHATWG parser canonicalizes numeric IPv4, IPv6 and DNS names.
            Host::parse(name).map_err(|_| denied())?
        }
        _ => return Err(denied()),
    };
    Ok((host, from.read_u16().await?))
}

/// Resolves the destination and opens a connection to its first address that answers.
async fn connect(host: Host, port: u16, limits: Limits) -> io::Result<TcpStream> {
    #[cfg(test)]
    let public_only = !limits.local;
    #[cfg(not(test))]
    let public_only = {
        let _ = limits;
        true
    };
    let host = match &host {
        Host::Domain(name) => Host::Domain(name.as_str()),
        Host::Ipv4(ip) => Host::Ipv4(*ip),
        Host::Ipv6(ip) => Host::Ipv6(*ip),
    };
    let target = connect_first(&addresses(host, port, public_only).await?, STAGGER).await?;
    let keepalive = socket2::TcpKeepalive::new().with_time(KEEPALIVE);
    let _ = socket2::SockRef::from(&target).set_tcp_keepalive(&keepalive);
    Ok(target)
}

/// The order to try addresses in: families alternate, starting with the family
/// the resolver put first (RFC 8305, section 4).
fn interleave(addresses: &[SocketAddr]) -> Vec<SocketAddr> {
    let first_v6 = addresses.first().is_some_and(SocketAddr::is_ipv6);
    let (mut preferred, mut other): (Vec<SocketAddr>, Vec<SocketAddr>) =
        addresses.iter().partition(|address| address.is_ipv6() == first_v6);
    preferred.reverse();
    other.reverse();
    let mut ordered = Vec::with_capacity(addresses.len());
    while !preferred.is_empty() || !other.is_empty() {
        ordered.extend(preferred.pop());
        ordered.extend(other.pop());
    }
    ordered
}

/// Starts a connection to each address in turn, `stagger` apart or as soon as the
/// previous one fails, and keeps the first that succeeds. A dead IPv6 route then
/// costs a quarter second, not a full connect timeout.
async fn connect_first(addresses: &[SocketAddr], stagger: Duration) -> io::Result<TcpStream> {
    let mut waiting = interleave(addresses).into_iter();
    let mut attempts = JoinSet::new();
    let mut last_error = io::Error::new(ErrorKind::NotFound, "The name has no address.");
    if let Some(address) = waiting.next() {
        attempts.spawn(TcpStream::connect(address));
    }
    while !attempts.is_empty() {
        let more = waiting.len() > 0;
        tokio::select! {
            Some(done) = attempts.join_next() => match done {
                Ok(Ok(stream)) => return Ok(stream),
                Ok(Err(error)) => {
                    last_error = error;
                    if let Some(address) = waiting.next() {
                        attempts.spawn(TcpStream::connect(address));
                    }
                }
                Err(error) => last_error = io::Error::other(error),
            },
            _ = sleep(stagger), if more => {
                if let Some(address) = waiting.next() {
                    attempts.spawn(TcpStream::connect(address));
                }
            }
        }
    }
    Err(last_error)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn navigation_refuses_local_literals_names_and_non_web_schemes() {
        for url in [
            "file:///tmp/private",
            "http://intranet/",
            "http://metadata.google.internal/",
            "http://localhost./",
            "http://a.localhost/",
            "http://192.168.1.4/",
            "http://0x7f000001/",
            "http://100.64.1.4/",
            "http://[::ffff:127.0.0.1]/",
            "http://[fc00::1]/",
            "https://user@example.com/",
        ] {
            assert!(allowed_url(&Url::parse(url).unwrap()).is_err(), "{url}");
        }
        for url in ["https://example.com/", "http://8.8.8.8/", "https://[2606:4700:4700::1111]/"] {
            assert!(allowed_url(&Url::parse(url).unwrap()).is_ok(), "{url}");
        }
    }

    /// Opens a tunnel through the proxy to 127.0.0.1:`port` and returns it with the reply code.
    async fn tunnel(proxy: &Proxy, port: u16) -> (TcpStream, u8) {
        let mut tunnel = TcpStream::connect((Ipv4Addr::LOCALHOST, proxy.url.port().unwrap())).await.unwrap();
        tunnel.write_all(&[5, 1, 0]).await.unwrap();
        assert_eq!(tunnel.read_u16().await.unwrap(), 5 << 8);
        let port = port.to_be_bytes();
        tunnel.write_all(&[5, 1, 0, 1, 127, 0, 0, 1, port[0], port[1]]).await.unwrap();
        let mut answer = [0u8; 10];
        tunnel.read_exact(&mut answer).await.unwrap();
        (tunnel, answer[1])
    }

    fn local(connections: usize, idle: Duration) -> Limits {
        Limits { connections, idle, local: true }
    }

    #[test]
    fn proxy_never_connects_to_a_local_address() {
        async_runtime::block_on(async {
            assert!(check_destination(&Url::parse("http://127.0.0.1").unwrap()).await.is_err());
            let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
            let proxy = Proxy::start().await.unwrap();
            let (_tunnel, code) = tunnel(&proxy, target.local_addr().unwrap().port()).await;
            assert_eq!(code, Refusal::NotAllowed as u8);
            assert!(timeout(Duration::from_millis(100), target.accept()).await.is_err());
        });
    }

    #[test]
    fn a_tunnel_with_no_traffic_closes_and_a_busy_one_stays() {
        async_runtime::block_on(async {
            let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
            let port = target.local_addr().unwrap().port();
            let proxy = Proxy::with(local(4, Duration::from_millis(300))).await.unwrap();

            let (mut quiet, code) = tunnel(&proxy, port).await;
            assert_eq!(code, 0);
            let (_held, _) = target.accept().await.unwrap();
            let closed = timeout(Duration::from_secs(3), quiet.read_u8()).await.expect("the idle tunnel closes");
            assert!(closed.is_err(), "the tunnel ends without data");

            let (mut busy, _) = tunnel(&proxy, port).await;
            let (mut echo, _) = target.accept().await.unwrap();
            for _ in 0..8 {
                busy.write_u8(1).await.unwrap();
                assert_eq!(echo.read_u8().await.unwrap(), 1);
                sleep(Duration::from_millis(100)).await;
            }
            echo.write_u8(2).await.unwrap();
            assert_eq!(busy.read_u8().await.unwrap(), 2, "traffic keeps the tunnel open past the idle time");
        });
    }

    #[test]
    fn a_full_proxy_refuses_at_once_and_a_freed_slot_is_reused() {
        async_runtime::block_on(async {
            let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
            let port = target.local_addr().unwrap().port();
            let proxy = Proxy::with(local(1, Duration::from_secs(60))).await.unwrap();

            let (first, code) = tunnel(&proxy, port).await;
            assert_eq!(code, 0);
            let (held, _) = target.accept().await.unwrap();

            let started = Instant::now();
            let (_second, code) = tunnel(&proxy, port).await;
            assert_eq!(code, Refusal::ConnectionRefused as u8);
            assert!(started.elapsed() < Duration::from_secs(1));

            drop(first);
            drop(held);
            let reopened = async {
                loop {
                    let (stream, code) = tunnel(&proxy, port).await;
                    if code == 0 {
                        return stream;
                    }
                    sleep(Duration::from_millis(20)).await;
                }
            };
            timeout(Duration::from_secs(3), reopened).await.expect("the slot frees once the tunnel ends");
        });
    }

    #[test]
    fn addresses_alternate_families_starting_with_the_first() {
        let v6 = |n: u16| SocketAddr::new(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, n).into(), 443);
        let v4 = |n: u8| SocketAddr::new(Ipv4Addr::new(192, 0, 2, n).into(), 443);
        assert_eq!(interleave(&[v6(1), v6(2), v4(1), v4(2), v4(3)]), [v6(1), v4(1), v6(2), v4(2), v4(3)]);
        assert_eq!(interleave(&[v4(1), v6(1)]), [v4(1), v6(1)]);
        assert!(interleave(&[]).is_empty());
    }

    #[test]
    fn a_silent_address_does_not_hold_up_the_next() {
        async_runtime::block_on(async {
            let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
            let reachable = target.local_addr().unwrap();
            // A documentation address: nothing answers, or the route fails at once.
            let silent = SocketAddr::new(Ipv4Addr::new(192, 0, 2, 1).into(), reachable.port());
            let started = Instant::now();
            let stream = timeout(Duration::from_secs(2), connect_first(&[silent, reachable], Duration::from_millis(50)))
                .await
                .expect("the second address is tried")
                .unwrap();
            assert_eq!(stream.peer_addr().unwrap(), reachable);
            assert!(started.elapsed() < Duration::from_secs(1));
        });
    }

    #[test]
    fn refusals_name_their_cause() {
        assert_eq!(Refusal::from(&denied()), Refusal::NotAllowed);
        assert_eq!(Refusal::from(&io::Error::from(ErrorKind::ConnectionRefused)), Refusal::ConnectionRefused);
        assert_eq!(Refusal::from(&io::Error::from(ErrorKind::NotFound)), Refusal::HostUnreachable);
        assert_eq!(Refusal::from(&io::Error::from(ErrorKind::TimedOut)), Refusal::TimedOut);
        assert_eq!(Refusal::from(&io::Error::other("other")), Refusal::General);
        assert_eq!(Failure::from(&denied()), Failure::Private);
        assert_eq!(Failure::from(&io::Error::from(ErrorKind::ConnectionRefused)), Failure::Refused);
        assert_eq!(Failure::from(&io::Error::from(ErrorKind::NotFound)), Failure::Dns);
        assert_eq!(Failure::from(&io::Error::from(ErrorKind::TimedOut)), Failure::Timeout);
        assert_eq!(Failure::from(&io::Error::other("other")), Failure::Unknown);
        assert_eq!(allowed_url(&Url::parse("ftp://example.com/").unwrap()), Err(Failure::Blocked));
        assert_eq!(allowed_url(&Url::parse("http://192.168.1.4/").unwrap()), Err(Failure::Private));
    }

    #[test]
    fn the_proxy_keeps_why_a_host_failed_until_it_opens() {
        async_runtime::block_on(async {
            let closed = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
            let closed_port = closed.local_addr().unwrap().port();
            drop(closed);
            let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
            let proxy = Proxy::with(local(4, Duration::from_secs(5))).await.unwrap();
            assert_eq!(proxy.failures.of("127.0.0.1"), None);

            let (_refused, code) = tunnel(&proxy, closed_port).await;
            assert_eq!(code, Refusal::ConnectionRefused as u8);
            assert_eq!(proxy.failures.of("127.0.0.1"), Some(Failure::Refused));

            let (_open, code) = tunnel(&proxy, target.local_addr().unwrap().port()).await;
            assert_eq!(code, 0);
            assert_eq!(proxy.failures.of("127.0.0.1"), None);
        });
    }

    #[test]
    fn the_failure_record_stays_bounded() {
        let failures = Failures::default();
        for host in 0..MAX_FAILURES + 1 {
            failures.record(&format!("host{host}.example"), Some(Failure::Dns));
        }
        assert_eq!(failures.of(&format!("host{MAX_FAILURES}.example")), Some(Failure::Dns));
        assert_eq!(failures.of("host0.example"), None);
        assert!(failures.0.lock().unwrap().len() <= MAX_FAILURES);
    }
}
