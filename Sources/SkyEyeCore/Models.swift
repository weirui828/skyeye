import CryptoKit
import Foundation

public struct SkyEyeError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// One service as stored in config.json.
public struct ServiceConfig: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var port: Int?
    /// Shell command that starts the service. `nil` means monitor-only.
    public var command: String?
    public var directory: String?
    public var env: [String: String]
    /// HTTP path (or full URL) that must answer 2xx/3xx before the service counts as up.
    public var healthPath: String?
    public var group: String?
    /// Services that must be ready before this service starts.
    public var dependencies: [String]
    public var autoRestart: Bool
    /// Fingerprint of the command, directory and env the user last approved.
    public var approvedFingerprint: String?

    public var id: String { name }

    public init(
        name: String, port: Int? = nil, command: String? = nil, directory: String? = nil,
        env: [String: String] = [:], healthPath: String? = nil, group: String? = nil,
        autoRestart: Bool = false, approvedFingerprint: String? = nil, dependencies: [String] = []
    ) {
        self.name = name
        self.port = port
        self.command = command
        self.directory = directory
        self.env = env
        self.healthPath = healthPath
        self.group = group
        self.dependencies = dependencies
        self.autoRestart = autoRestart
        self.approvedFingerprint = approvedFingerprint
    }

    enum CodingKeys: String, CodingKey {
        case name, port, command, directory, env, healthPath, group, dependencies, autoRestart, approvedFingerprint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        healthPath = try c.decodeIfPresent(String.self, forKey: .healthPath)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        autoRestart = try c.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? false
        approvedFingerprint = try c.decodeIfPresent(String.self, forKey: .approvedFingerprint)
    }

    /// Changes whenever anything that affects what gets executed changes.
    public var fingerprint: String {
        var parts = [command ?? "", directory ?? ""]
        parts += env.keys.sorted().map { "\($0)=\(env[$0]!)" }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public var isApproved: Bool { command == nil || approvedFingerprint == fingerprint }

    public var url: String? { port.map { "http://localhost:\($0)" } }

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix(".")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// Trims fields, turns empty strings into nil and expands `~` in the directory.
    public func normalized() -> ServiceConfig {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        var s = self
        s.name = name.trimmingCharacters(in: .whitespaces)
        s.command = clean(command)
        s.directory = clean(directory).map { ($0 as NSString).expandingTildeInPath }
        s.healthPath = clean(healthPath)
        s.group = clean(group)
        var seen = Set<String>()
        s.dependencies = dependencies.compactMap(clean).filter { seen.insert($0).inserted }
        return s
    }
}

public enum AutoStartMode: String, Codable, CaseIterable, Sendable {
    case none, selected, all
}

public struct Settings: Codable, Hashable, Sendable {
    /// Commands added or changed through the CLI/MCP must be approved in the menu bar.
    public var requireApproval = true
    public var notifications = true
    /// Shell used to run commands. Defaults to the user's login shell.
    public var shell: String?
    /// Run commands with `-i -l` so nvm/asdf/mise and PATH from your dotfiles work.
    public var loadShellProfile = true
    /// Leave services running when SkyEye quits and take them back over on the next launch.
    public var keepRunningOnQuit = false
    /// Zero keeps logs forever; otherwise retain this many days.
    public var logRetentionDays = 7
    public var autoStartMode: AutoStartMode = .none
    public var autoStartServices: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case requireApproval, notifications, shell, loadShellProfile, keepRunningOnQuit, logRetentionDays, autoStartMode, autoStartServices }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? true
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        shell = try c.decodeIfPresent(String.self, forKey: .shell)
        loadShellProfile = try c.decodeIfPresent(Bool.self, forKey: .loadShellProfile) ?? true
        keepRunningOnQuit = try c.decodeIfPresent(Bool.self, forKey: .keepRunningOnQuit) ?? false
        logRetentionDays = try c.decodeIfPresent(Int.self, forKey: .logRetentionDays) ?? 7
        autoStartMode = try c.decodeIfPresent(AutoStartMode.self, forKey: .autoStartMode) ?? .none
        autoStartServices = try c.decodeIfPresent([String].self, forKey: .autoStartServices) ?? []
    }
}

public struct SkyEyeConfig: Codable, Sendable {
    public var version = 1
    public var settings = Settings()
    public var services: [ServiceConfig] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case version, settings, services }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        services = try c.decodeIfPresent([ServiceConfig].self, forKey: .services) ?? []
    }
}

public enum ServiceState: String, Codable, Sendable {
    case stopped, starting, running, unhealthy, stopping, crashed
    /// The port is in use by a process SkyEye didn't start.
    case external
    case pendingApproval = "pending-approval"

    public var label: String {
        switch self {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .unhealthy: "unhealthy"
        case .stopping: "stopping"
        case .crashed: "crashed"
        case .external: "running outside SkyEye"
        case .pendingApproval: "waiting for approval"
        }
    }

    /// A process started by SkyEye is alive.
    public var isActive: Bool { [.starting, .running, .unhealthy, .stopping].contains(self) }
}

public struct ExitStatus: Codable, Hashable, Sendable, CustomStringConvertible {
    public var code: Int32?
    public var signal: Int32?

    public init(rawWaitStatus raw: Int32) {
        let sig = raw & 0x7f
        if sig == 0 { code = (raw >> 8) & 0xff } else { signal = sig }
    }

    /// For a process SkyEye re-attached to after a relaunch: it isn't our child, so its status can't be collected.
    public static var unknown: ExitStatus {
        var status = ExitStatus(rawWaitStatus: 0)
        status.code = nil
        return status
    }

    public var isSuccess: Bool { code == 0 }

    public var description: String {
        if let code { return "exit code \(code)" }
        guard let sig = signal else { return "exit status unknown" }
        let name = String(cString: strsignal(sig))
        return "killed by signal \(sig) (\(name))"
    }
}

/// A service plus its live status, as reported to the UI, CLI and MCP.
public struct ServiceSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var service: ServiceConfig
    public var state: ServiceState
    public var detail: String?
    public var pid: Int32?
    public var startedAt: Date?
    public var lastExit: String?
    public var autoRestarts: Int
    public var approved: Bool
    public var logFile: String
    /// CPU (100 = one core) and resident memory of the service and everything it spawned, while it runs.
    public var cpuPercent: Double? = nil
    public var memoryBytes: UInt64? = nil

    public var id: String { service.name }

    /// "3.1% CPU · 145 MB", or nil when not running.
    public var usageSummary: String? {
        guard let memoryBytes else { return nil }
        let memory = ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
        guard let cpuPercent else { return memory }
        return String(format: "%.1f%% CPU · ", cpuPercent) + memory
    }
}

/// A service left running when SkyEye quit, saved so the next launch can take it back over.
struct DetachedService: Codable {
    var name: String
    var pid: Int32
    /// Kernel start time of `pid`, so a recycled pid isn't mistaken for the service.
    var processStart: UInt64
    var startedAt: Date
    var everReady: Bool
}

public struct PortListener: Codable, Hashable, Sendable, CustomStringConvertible {
    public var pid: Int32
    public var command: String
    public var port: Int

    public var description: String { "\(command) (pid \(pid))" }
}

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
