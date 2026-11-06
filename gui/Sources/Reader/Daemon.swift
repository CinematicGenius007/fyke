// The app's only way to the data: newline-delimited JSON-RPC over the daemon's
// Unix socket. See docs/api.md. The app never opens the database.
import Foundation

struct RPCFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One blocking connection. Each is used by one thread at a time.
private final class Connection {
    private let fd: Int32
    private var buffer = Data()

    init(path: String, timeoutSeconds: Int) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        // A hung daemon must surface as an error, not as a frozen app.
        var limit = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The only close. It also runs when `init` throws, since every property is set by then.
    deinit { Darwin.close(fd) }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard sent > 0 else { throw POSIXError(.EPIPE) }
                offset += sent
            }
        }
    }

    func readLine() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[(newline + 1)...])
                return line
            }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { throw POSIXError(.ECONNRESET) }
            buffer.append(chunk, count: count)
        }
    }
}

private struct Request<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: P
}

private struct Response<R: Decodable>: Decodable {
    struct Failure: Decodable { let message: String }
    let result: R?
    let error: Failure?
}

struct NoParams: Encodable, Sendable {}

struct Event: Decodable, Sendable {
    let seq: Int64
    let type: String
}

/// All calls to the daemon. Quick calls share one connection on a serial queue.
/// Calls that touch the network get their own, so they cannot delay the rest.
final class Daemon: @unchecked Sendable {
    static let shared = Daemon()

    let home: URL
    private var socketPath: String { home.appending(path: "rssd.sock").path }
    private let queue = DispatchQueue(label: "daemon.calls")
    private var shared: Connection?

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private init() {
        if let path = ProcessInfo.processInfo.environment["RSS_HOME"] {
            home = URL(filePath: path)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/rss_")
        }
    }

    func call<P: Encodable & Sendable, R: Decodable & Sendable>(_ method: String, _ params: P) async throws -> R {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.callShared(method, params) })
            }
        }
    }

    func call<R: Decodable & Sendable>(_ method: String) async throws -> R {
        try await call(method, NoParams())
    }

    /// For operations that wait on the network.
    func callSlow<P: Encodable & Sendable, R: Decodable & Sendable>(_ method: String, _ params: P) async throws -> R {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let connection = try self.open(timeoutSeconds: 120)
                    return try Self.exchange(connection, method, params)
                })
            }
        }
    }

    private func callShared<P: Encodable, R: Decodable>(_ method: String, _ params: P) throws -> R {
        do {
            if shared == nil { shared = try open(timeoutSeconds: 35) }
            return try Self.exchange(shared!, method, params)
        } catch let failure as RPCFailure {
            throw failure
        } catch {
            // The daemon may have restarted. Reconnect once.
            shared = try open(timeoutSeconds: 35)
            return try Self.exchange(shared!, method, params)
        }
    }

    private static func exchange<P: Encodable, R: Decodable>(_ connection: Connection, _ method: String, _ params: P) throws -> R {
        var data = try encoder().encode(Request(id: 1, method: method, params: params))
        data.append(10)
        try connection.send(data)
        let response = try decoder().decode(Response<R>.self, from: connection.readLine())
        if let failure = response.error { throw RPCFailure(message: failure.message) }
        guard let result = response.result else { throw RPCFailure(message: "The daemon sent an empty reply") }
        return result
    }

    private func open(timeoutSeconds: Int) throws -> Connection {
        if let connection = try? Connection(path: socketPath, timeoutSeconds: timeoutSeconds) { return connection }
        try startDaemon()
        for _ in 0..<300 {
            if let connection = try? Connection(path: socketPath, timeoutSeconds: timeoutSeconds) { return connection }
            usleep(10_000)
        }
        throw RPCFailure(message: "The background service did not start")
    }

    /// The `rss` binary ships beside this one in the app bundle.
    var programPath: String {
        ProcessInfo.processInfo.environment["RSS_BIN"] ?? Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "rss").path
    }

    private func startDaemon() throws {
        let path = programPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw RPCFailure(message: "Cannot find the rss program at \(path)")
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = ["daemon", "--log"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Live changes from the daemon, reconnecting whenever the stream drops.
    func events(since: Int64) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let thread = Thread { [self] in
                var seq = since
                struct Subscribe: Encodable { let sinceSeq: Int64 }
                while !Thread.current.isCancelled {
                    do {
                        // The stream is quiet when nothing happens, so no read timeout.
                        let connection = try open(timeoutSeconds: 0)
                        var data = try Self.encoder().encode(Request(id: 1, method: "events.subscribe", params: Subscribe(sinceSeq: seq)))
                        data.append(10)
                        try connection.send(data)
                        _ = try connection.readLine()
                        struct Message: Decodable { let params: Event? }
                        while !Thread.current.isCancelled {
                            let line = try connection.readLine()
                            if let event = try Self.decoder().decode(Message.self, from: line).params {
                                seq = event.seq
                                continuation.yield(event)
                            }
                        }
                    } catch {
                        sleep(1)
                    }
                }
            }
            // The stream lasts as long as the app, so the thread needs no cancelling.
            thread.start()
        }
    }
}
