import Darwin
import Foundation

public struct ProbeTarget: Sendable {
    public var name: String
    public var port: Int
    public var healthPath: String?
    /// Look up which process holds the port (only needed when SkyEye didn't start it).
    public var wantOwner: Bool
}

public struct ProbeResult: Sendable {
    public var portOpen: Bool
    public var healthy: Bool?
    public var owner: PortListener?
}

public enum PortProbe {
    /// True if something accepts TCP connections on localhost (IPv4 or IPv6).
    public static func isListening(_ port: Int, timeout: TimeInterval = 0.25) -> Bool {
        connect(port: port, ipv6: false, timeout: timeout) || connect(port: port, ipv6: true, timeout: timeout)
    }

    private static func connect(port: Int, ipv6: Bool, timeout: TimeInterval) -> Bool {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let rc: Int32
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    /// Processes listening on `port`, via lsof.
    public static func listeners(on port: Int) -> [PortListener] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var result: [PortListener] = []
        var pid: Int32?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("c"), let p = pid, !result.contains(where: { $0.pid == p }) {
                result.append(PortListener(pid: p, command: String(line.dropFirst()), port: port))
            }
        }
        return result
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// GETs the health URL; 2xx and 3xx count as healthy.
    public static func healthCheck(port: Int, path: String, timeout: TimeInterval = 2) -> Bool {
        let urlString = path.hasPrefix("http://") || path.hasPrefix("https://")
            ? path
            : "http://localhost:\(port)\(path.hasPrefix("/") ? path : "/" + path)"
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"

        final class Box: @unchecked Sendable { var ok = false }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse { box.ok = (200..<400).contains(http.statusCode) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 0.5)
        return box.ok
    }

    /// Probes all targets concurrently.
    public static func probe(_ targets: [ProbeTarget]) -> [String: ProbeResult] {
        let lock = NSLock()
        var results: [String: ProbeResult] = [:]
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in
            let t = targets[i]
            let open = isListening(t.port)
            let healthy = open ? t.healthPath.map { healthCheck(port: t.port, path: $0) } : nil
            let owner = open && t.wantOwner ? listeners(on: t.port).first : nil
            lock.withLock { results[t.name] = ProbeResult(portOpen: open, healthy: healthy, owner: owner) }
        }
        return results
    }
}

public enum LogTail {
    /// The last `lines` lines of a log file (reads at most the final `maxBytes`).
    public static func read(_ url: URL, lines: Int, maxBytes: Int = 512 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        var all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if start > 0, !all.isEmpty { all.removeFirst() }  // partial first line
        if all.last == "" { all.removeLast() }
        return all.suffix(max(lines, 0)).joined(separator: "\n")
    }

    public static func append(_ text: String, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data(text.utf8))
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}")

    /// Removes terminal color/control sequences.
    public static func stripANSI(_ text: String) -> String {
        ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
