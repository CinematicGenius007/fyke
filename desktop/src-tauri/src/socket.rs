//! The daemon's AF_UNIX socket. Windows 10 1803 and later have AF_UNIX too, so every
//! system speaks to the same `fyked.sock` the same way.

use std::io;
use std::path::Path;
use std::time::Duration;

#[cfg(unix)]
pub use std::os::unix::net::{UnixListener as Listener, UnixStream as Stream};
#[cfg(windows)]
pub use uds_windows::{UnixListener as Listener, UnixStream as Stream};

/// Connects, with `timeout` as the read timeout. None means no read timeout, for the
/// event stream, which is quiet whenever nothing happens.
pub fn connect(path: &Path, timeout: Option<Duration>) -> io::Result<Stream> {
    let stream = Stream::connect(path)?;
    stream.set_read_timeout(timeout)?;
    Ok(stream)
}
