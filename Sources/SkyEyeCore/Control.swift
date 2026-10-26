import Darwin
import Foundation

// The app listens on a Unix socket; the CLI and MCP server send one JSON
// request per connection (newline-terminated) and read one JSON response.

public struct ControlRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case ping, list, get, add, update, remove, start, stop, restart, logs, port
        case killPort = "kill-port"
    }

    public var action: Action
    /// Service name, or `@group` for start/stop/restart.
    public var name: String?
    public var service: ServiceConfig?
    public var lines: Int?
    public var port: Int?

    public init(action: Action, name: String? = nil, service: ServiceConfig? = nil, lines: Int? = nil, port: Int? = nil) {
        self.action = action
        self.name = name
        self.service = service
        self.lines = lines
        self.port = port
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String?
    public var error: String?
    public var services: [ServiceSnapshot]?
    public var service: ServiceSnapshot?
    public var log: String?
    public var listeners: [PortListener]?

    public init(
        ok: Bool, message: String? = nil, error: String? = nil, services: [ServiceSnapshot]? = nil,
        service: ServiceSnapshot? = nil, log: String? = nil, listeners: [PortListener]? = nil
    ) {
        self.ok = ok
        self.message = message
        self.error = error
        self.services = services
        self.service = service
        self.log = log
        self.listeners = listeners
    }

    public static func failure(_ error: Error) -> ControlResponse {
        ControlResponse(ok: false, error: (error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
}

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SkyEyeError("Socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    static func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func configure(_ fd: Int32, timeout: Int) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads until a newline or EOF.
    static func readMessage(_ fd: Int32, maxBytes: Int = 16 * 1024 * 1024) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < maxBytes {
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            data.append(buf, count: n)
            if let i = data.firstIndex(of: 0x0A) { return Data(data[..<i]) }
        }
        return data.isEmpty ? nil : data
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) -> ControlResponse

    private let socketPath: String
    private let handler: Handler
    private var fd: Int32 = -1

    public init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() throws {
        var addr = try UnixSocket.address(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SkyEyeError("socket(): \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        unlink(socketPath)
        guard UnixSocket.withSockaddr(&addr, { bind(fd, $0, $1) }) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw SkyEyeError("Could not listen on \(socketPath): \(message)")
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw SkyEyeError("listen(): \(String(cString: strerror(errno)))")
        }
        self.fd = fd

        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "SkyEye control server"
        thread.start()
    }

    public func stop() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        unlink(socketPath)
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        // Only accept connections from our own user.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        UnixSocket.configure(client, timeout: 10)

        guard let message = UnixSocket.readMessage(client) else { return }
        let response: ControlResponse
        do {
            response = handler(try JSONCoding.decoder.decode(ControlRequest.self, from: message))
        } catch {
            response = ControlResponse(ok: false, error: "Invalid request: \(error)")
        }
        var data = (try? JSONCoding.encoder.encode(response)) ?? Data()
        data.append(0x0A)
        _ = UnixSocket.writeAll(client, data)
    }
}

public struct ControlClient: Sendable {
    public static let bundleIdentifier = "dev.skyeye.SkyEye"

    public var socketPath: String
    /// Launch SkyEye.app in the background if it isn't running.
    public var autoLaunch: Bool

    public init(socketPath: String = SkyEyePaths.standard.socketPath, autoLaunch: Bool = true) {
        self.socketPath = socketPath
        self.autoLaunch = autoLaunch
    }

    private struct NotRunning: Error {}

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        do {
            return try sendOnce(request)
        } catch is NotRunning {
            guard autoLaunch, launchApp() else {
                throw SkyEyeError("SkyEye isn't running. Open SkyEye.app and try again.")
            }
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.5)
                if let response = try? sendOnce(request) { return response }
            }
            throw SkyEyeError("SkyEye was launched but isn't responding yet. Try again in a moment.")
        }
    }

    private func sendOnce(_ request: ControlRequest) throws -> ControlResponse {
        var addr = try UnixSocket.address(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SkyEyeError("socket(): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        UnixSocket.configure(fd, timeout: 30)

        if UnixSocket.withSockaddr(&addr, { connect(fd, $0, $1) }) != 0 {
            if errno == ENOENT || errno == ECONNREFUSED { throw NotRunning() }
            throw SkyEyeError("Could not connect to SkyEye: \(String(cString: strerror(errno)))")
        }
        var data = try JSONCoding.encoder.encode(request)
        data.append(0x0A)
        guard UnixSocket.writeAll(fd, data) else { throw SkyEyeError("Could not send the request to SkyEye.") }
        guard let reply = UnixSocket.readMessage(fd) else { throw SkyEyeError("SkyEye didn't respond.") }
        return try JSONCoding.decoder.decode(ControlResponse.self, from: reply)
    }

    private func launchApp() -> Bool {
        for args in [["-g", "-b", Self.bundleIdentifier], ["-g", "-a", "SkyEye"]] {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = args
            open.standardOutput = FileHandle.nullDevice
            open.standardError = FileHandle.nullDevice
            guard (try? open.run()) != nil else { continue }
            open.waitUntilExit()
            if open.terminationStatus == 0 { return true }
        }
        return false
    }

    /// Polls until the service is no longer starting/stopping, or `timeout` passes.
    public func waitUntilSettled(_ name: String, timeout: TimeInterval = 60) throws -> ServiceSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        let begun = Date()
        while true {
            let response = try send(ControlRequest(action: .get, name: name))
            guard response.ok, let snapshot = response.service else {
                throw SkyEyeError(response.error ?? "Unknown service '\(name)'.")
            }
            // A service without a port counts as running immediately; give it a moment to crash.
            let minimumWait: TimeInterval = snapshot.service.port == nil ? 1.5 : 0.5
            let settled = snapshot.state != .starting && snapshot.state != .stopping
            if (settled && Date().timeIntervalSince(begun) >= minimumWait) || Date() >= deadline {
                return snapshot
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// Expands `@group` into the names of its services.
    public func resolve(_ target: String) throws -> [String] {
        guard target.hasPrefix("@") else { return [target] }
        let group = String(target.dropFirst())
        let all = try send(ControlRequest(action: .list)).services ?? []
        return all.filter { $0.service.group == group }.map(\.service.name)
    }
}
