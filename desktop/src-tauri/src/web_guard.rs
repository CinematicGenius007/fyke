//! The page viewer reaches the network through a loopback SOCKS endpoint. Each
//! connection resolves once, rejects non-public answers and dials a validated
//! IP address directly. A page's redirects and subresources use the same boundary.

use std::io::{self, ErrorKind};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;
use tauri::async_runtime::{self, JoinHandle};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{lookup_host, TcpListener, TcpStream};
use tokio::task::JoinSet;
use tokio::time::timeout;
use url::{Host, Url};

pub const PRIVATE: &str = "This page is on a private address, so it stays out of the app.";
const HANDSHAKE: Duration = Duration::from_secs(12);
const MAX_CONNECTIONS: usize = 128;

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

pub fn allowed_url(url: &Url) -> Result<(), &'static str> {
    if !matches!(url.scheme(), "http" | "https") || !url.username().is_empty() || url.password().is_some() {
        return Err("Only public web addresses can open in Fyke.");
    }
    if url.host().is_none_or(|host| !public_host(&host)) {
        return Err(PRIVATE);
    }
    Ok(())
}

fn denied() -> io::Error {
    io::Error::new(ErrorKind::PermissionDenied, PRIVATE)
}

async fn addresses(host: Host<&str>, port: u16) -> io::Result<Vec<SocketAddr>> {
    if port == 0 || !public_host(&host) {
        return Err(denied());
    }
    let resolved = match host {
        // The root dot keeps the resolver from applying local search domains.
        Host::Domain(name) => lookup_host((format!("{}.", name.trim_end_matches('.')).as_str(), port)).await?.collect(),
        Host::Ipv4(ip) => vec![SocketAddr::new(ip.into(), port)],
        Host::Ipv6(ip) => vec![SocketAddr::new(ip.into(), port)],
    };
    if resolved.is_empty() || resolved.iter().any(|address| !public_ip(address.ip())) {
        return Err(denied());
    }
    Ok(resolved)
}

pub async fn check_destination(url: &Url) -> Result<(), String> {
    allowed_url(url)?;
    timeout(HANDSHAKE, addresses(url.host().expect("URL guard checks this"), url.port_or_known_default().unwrap_or(0)))
        .await
        .map_err(|_| "The lookup timed out.".to_string())?
        .map(|_| ())
        .map_err(|error| error.to_string())
}

pub struct Proxy {
    pub url: Url,
    task: JoinHandle<()>,
}

impl Proxy {
    pub async fn start() -> io::Result<Self> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let url = Url::parse(&format!("socks5://{}", listener.local_addr()?)).expect("valid local SOCKS address");
        let task = async_runtime::spawn(async move {
            let mut active = JoinSet::new();
            loop {
                tokio::select! {
                    ready = listener.accept(), if active.len() < MAX_CONNECTIONS => {
                        let Ok((socket, _)) = ready else { break };
                        active.spawn(async move { let _ = forward(socket).await; });
                    }
                    _ = active.join_next(), if !active.is_empty() => {}
                }
            }
        });
        Ok(Self { url, task })
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn forward(mut from: TcpStream) -> io::Result<()> {
    let target = timeout(HANDSHAKE, handshake(&mut from)).await;
    match target {
        Ok(Ok(mut target)) => {
            // BND.ADDR and BND.PORT are unused for CONNECT.
            from.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            tokio::io::copy_bidirectional(&mut from, &mut target).await?;
        }
        _ => from.write_all(&[5, 2, 0, 1, 0, 0, 0, 0, 0, 0]).await?,
    }
    Ok(())
}

async fn handshake(from: &mut TcpStream) -> io::Result<TcpStream> {
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
    let port = from.read_u16().await?;
    let target = addresses(
        match &host {
            Host::Domain(name) => Host::Domain(name.as_str()),
            Host::Ipv4(ip) => Host::Ipv4(*ip),
            Host::Ipv6(ip) => Host::Ipv6(*ip),
        },
        port,
    )
    .await?;
    TcpStream::connect(target.as_slice()).await
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

    #[test]
    fn proxy_never_connects_to_a_local_address() {
        async_runtime::block_on(async {
            assert!(check_destination(&Url::parse("http://127.0.0.1").unwrap()).await.is_err());
            let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
            let port = target.local_addr().unwrap().port().to_be_bytes();
            let proxy = Proxy::start().await.unwrap();
            let mut tunnel = TcpStream::connect((Ipv4Addr::LOCALHOST, proxy.url.port().unwrap())).await.unwrap();
            tunnel.write_all(&[5, 1, 0]).await.unwrap();
            assert_eq!(tunnel.read_u16().await.unwrap(), 5 << 8);
            tunnel.write_all(&[5, 1, 0, 1, 127, 0, 0, 1, port[0], port[1]]).await.unwrap();
            assert_eq!(tunnel.read_u16().await.unwrap(), (5 << 8) | 2);
            assert!(timeout(Duration::from_millis(100), target.accept()).await.is_err());
        });
    }
}
