import Darwin
import Foundation

public enum ServiceLogs {
    public static func archiveDirectory(for log: URL) -> URL {
        log.deletingLastPathComponent().appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent(log.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    /// A stable lock protects an active log even when its writer outlives the app.
    static func lockFile(for log: URL) -> URL { log.appendingPathExtension("lock") }

    public static func archives(for log: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: archiveDirectory(for: log), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        )) ?? []
        return files.filter { isLog($0) }.sorted { modified($0) > modified($1) }
    }

    public static func read(_ log: URL, lines: Int, maxBytes: Int = 512 * 1024) -> String {
        var remaining = max(lines, 0)
        var budget = maxBytes
        var chunks: [String] = []
        for file in [log] + archives(for: log) where remaining > 0 && budget > 0 {
            let text = LogTail.read(file, lines: remaining, maxBytes: budget)
            guard !text.isEmpty else { continue }
            remaining -= text.split(separator: "\n", omittingEmptySubsequences: false).count
            budget -= text.utf8.count
            chunks.insert(text, at: 0)
        }
        return chunks.joined(separator: "\n")
    }

    /// Cleanup never touches active logs, symlinks, or unrelated files.
    public static func cleanup(in directory: URL, retentionDays: Int, protectedNames: Set<String> = [], now: Date = Date()) throws {
        guard retentionDays > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let fm = FileManager.default
        let current = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for log in current where isLog(log) && !protectedNames.contains(log.deletingPathExtension().lastPathComponent) {
            guard modified(log) < cutoff else { continue }
            let fd = open(lockFile(for: log).path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { flock(fd, LOCK_UN) }
            // Check again after acquiring the lock in case a writer just finished.
            if modified(log) < cutoff { try fm.removeItem(at: log) }
        }
        let archiveRoot = directory.appendingPathComponent("archive", isDirectory: true)
        guard (try? archiveRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        guard let enumerator = fm.enumerator(at: archiveRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if isLog(file), modified(file) < cutoff { try fm.removeItem(at: file) }
        }
    }

    private static func isLog(_ url: URL) -> Bool {
        guard url.pathExtension == "log",
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
    }
}

/// Owns the output file; rotation closes and renames it between writes, without truncating a live descriptor.
/// Runs in the bundled log-writer process so keep-running services still log after SkyEye quits.
public final class RotatingLogWriter {
    private let log: URL
    private let lockFD: Int32
    private var handle: FileHandle?
    private var day: Date

    public init(log: URL, now: Date = Date()) throws {
        self.log = log
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        lockFD = open(ServiceLogs.lockFile(for: log).path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw SkyEyeError("Could not lock log: \(log.path)") }
        guard flock(lockFD, LOCK_EX) == 0 else {
            close(lockFD)
            throw SkyEyeError("Could not lock log: \(log.path)")
        }
        let created = (try? FileManager.default.attributesOfItem(atPath: log.path)[.creationDate]) as? Date
        day = Calendar.current.startOfDay(for: created ?? now)
        do { try openCurrent() } catch { close(lockFD); throw error }
    }

    deinit {
        try? handle?.close()
        flock(lockFD, LOCK_UN)
        close(lockFD)
    }

    public func append(_ data: Data, now: Date = Date()) throws {
        let today = Calendar.current.startOfDay(for: now)
        if today > day {
            try handle?.close()
            handle = nil
            let fm = FileManager.default
            let directory = ServiceLogs.archiveDirectory(for: log)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let stamp = formatter.string(from: day)
            let archive = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString).log")
            try fm.moveItem(at: log, to: archive)
            day = today
            try openCurrent()
        }
        try handle?.write(contentsOf: data)
    }

    private func openCurrent() throws {
        let fd = open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SkyEyeError("Could not open log: \(log.path)") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
