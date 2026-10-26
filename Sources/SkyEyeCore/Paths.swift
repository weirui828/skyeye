import Foundation

public struct SkyEyePaths: Sendable {
    public var root: URL
    public var logsDir: URL

    public init(root: URL, logsDir: URL) {
        self.root = root
        self.logsDir = logsDir
    }

    /// `~/Library/Application Support/SkyEye` and `~/Library/Logs/SkyEye`,
    /// or `$SKYEYE_HOME` (with logs in `$SKYEYE_HOME/logs`) when set.
    public static var standard: SkyEyePaths {
        if let home = ProcessInfo.processInfo.environment["SKYEYE_HOME"], !home.isEmpty {
            let root = URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
            return SkyEyePaths(root: root, logsDir: root.appendingPathComponent("logs", isDirectory: true))
        }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return SkyEyePaths(
            root: library.appendingPathComponent("Application Support/SkyEye", isDirectory: true),
            logsDir: library.appendingPathComponent("Logs/SkyEye", isDirectory: true)
        )
    }

    public var configFile: URL { root.appendingPathComponent("config.json") }
    public var detachedFile: URL { root.appendingPathComponent("detached.json") }
    public var socketPath: String { root.appendingPathComponent("skyeye.sock").path }

    public func logFile(for name: String) -> URL { logsDir.appendingPathComponent("\(name).log") }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
}
