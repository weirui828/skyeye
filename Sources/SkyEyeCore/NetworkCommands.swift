import Foundation

struct CommandResult: Sendable {
    var status: Int32
    var output: String
    /// The command was ended because it ran past its timeout.
    var timedOut: Bool
}

enum Command {
    /// Runs a system tool by absolute path and returns what it printed. A tool that can't start returns "".
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15, mergeStderr: Bool = false) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        do { try process.run() } catch { return CommandResult(status: -1, output: "", timedOut: false) }

        let expired = Expired()
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            expired.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self), timedOut: expired.value)
    }

    private final class Expired: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        var value: Bool { lock.withLock { flag } }

        func set() { lock.withLock { flag = true } }
    }
}

/// Asks a port for a page the way `curl -m 1` would: one GET, no redirects followed, a hard time limit.
final class HTTPProber: @unchecked Sendable {
    private let handler = Handler()
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: handler, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// The status and the start of the body, or nil when nothing answered HTTP in time.
    func get(_ url: URL, timeout: TimeInterval = 1.5) -> (status: Int, body: String)? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let task = session.dataTask(with: request)
        let entry = handler.track(task)
        task.resume()
        if entry.done.wait(timeout: .now() + timeout) == .timedOut { task.cancel() }
        let answer = handler.finish(task)
        guard let status = answer.status else { return nil }
        return (status, String(decoding: answer.body, as: UTF8.self))
    }

    final class Entry {
        var status: Int?
        var body = Data()
        let done = DispatchSemaphore(value: 0)
    }

    private final class Handler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private static let maxBody = 32 * 1024
        private let lock = NSLock()
        private var entries: [Int: Entry] = [:]

        func track(_ task: URLSessionTask) -> Entry {
            let entry = Entry()
            lock.withLock { entries[task.taskIdentifier] = entry }
            return entry
        }

        func finish(_ task: URLSessionTask) -> (status: Int?, body: Data) {
            lock.withLock {
                let entry = entries.removeValue(forKey: task.taskIdentifier)
                return (entry?.status, entry?.body ?? Data())
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)  // a redirect is the answer, not somewhere to go
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            lock.withLock { entries[dataTask.taskIdentifier]?.status = (response as? HTTPURLResponse)?.statusCode }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.withLock {
                guard let entry = entries[dataTask.taskIdentifier], entry.body.count < Self.maxBody else { return }
                entry.body.append(data.prefix(Self.maxBody - entry.body.count))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.withLock { entries[task.taskIdentifier] }?.done.signal()
        }
    }
}
