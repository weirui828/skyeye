import Foundation

/// How far a listening port can be reached from.
public enum Exposure: String, Codable, CaseIterable, Sendable {
    /// This Mac only.
    case loopback
    /// One network interface.
    case lan
    /// Every interface.
    case all

    var rank: Int {
        switch self {
        case .loopback: 0
        case .lan: 1
        case .all: 2
        }
    }
}

public enum PortRisk: String, Codable, CaseIterable, Sendable {
    case high, medium, low, info

    var rank: Int {
        switch self {
        case .info: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }
}

public enum ProgramSection: String, Codable, Sendable {
    /// Started by you, an agent or a tool: dev servers, databases, daemons.
    case servers
    /// Helpers of installed apps.
    case apps
    /// macOS's own.
    case system
}

public enum ProgramKind: String, Codable, Sendable {
    case debugger, database, web, service
}

public struct ListeningPort: Codable, Hashable, Sendable {
    public var port: Int
    public var address: String
    public var exposure: Exposure
    /// What an HTTP GET / answered, when it answered.
    public var status: Int?
    public var title: String?
    public var isDebugger: Bool

    public init(
        port: Int, address: String, exposure: Exposure? = nil,
        status: Int? = nil, title: String? = nil, isDebugger: Bool = false
    ) {
        self.port = port
        self.address = address
        self.exposure = exposure ?? PortScan.exposure(of: address)
        self.status = status
        self.title = title
        self.isDebugger = isDebugger
    }
}

/// One program with listening TCP ports.
public struct ListeningProgram: Codable, Hashable, Identifiable, Sendable {
    public var pid: Int32
    /// What the row is called: the page title, the app, or the script.
    public var name: String
    /// The process, short: next-server, python3.14.
    public var process: String
    public var command: String
    public var ports: [ListeningPort]
    public var exposure: Exposure
    public var section: ProgramSection
    public var kind: ProgramKind
    public var risk: PortRisk
    /// Why it got that risk, in plain words.
    public var reasons: [String]
    public var project: String?
    /// Where in the project (or under ~) it runs.
    public var place: String
    public var folder: String?
    /// "SkyEye", "Claude session", "terminal", an app, or "launchd".
    public var startedBy: String
    public var startedAt: Date
    public var rssKb: Int
    public var cpu: Double
    /// What Stop ends: the listener and the wrappers that started it (npm, uv run, sh -c).
    public var stopPids: [Int32]
    /// The SkyEye service this program belongs to, if any.
    public var service: String?
    /// SkyEye started it, so Stop goes through the service.
    public var managed: Bool

    public var id: Int32 { pid }
}

public struct ConnectionFlag: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable {
        /// Worth acting on.
        case alert
        /// Worth knowing.
        case note
    }

    public var level: Level
    public var text: String

    public init(_ level: Level, _ text: String) {
        self.level = level
        self.text = text
    }
}

/// One service a program talks to: its connections, ports and addresses.
public struct Peer: Codable, Hashable, Sendable {
    public var owner: String
    public var count: Int
    public var ports: [Int]
    public var ips: [String]
    public var hosts: [String]
    /// Connections that came in to a port the program listens on.
    public var inbound: Int
}

/// A program with connections to other machines.
public struct Talker: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var section: ProgramSection
    public var path: String
    public var pids: [Int32]
    /// "Google LLC", "Apple", "ad-hoc", "unsigned", or nil before it is checked.
    public var signer: String?
    public var peers: [Peer]
    public var count: Int
    public var flags: [ConnectionFlag]
    public var firstSeen: Date
    /// Services it talked to in the last day but not now.
    public var earlier: [String]

    public var id: String { name }
    public var hasAlert: Bool { flags.contains { $0.level == .alert } }
}

public struct ListeningScan: Sendable {
    public var programs: [ListeningProgram]
    /// The macOS application firewall; nil when its state couldn't be read.
    public var firewall: Bool?
    public var scannedAt: Date
    public var tree: [ProcessNode] = []
}

/// What nettop adds to a scan: bytes per program and address, and the connections inside this Mac.
public struct TrafficScan: Sendable {
    public var programs: [TrafficProgram] = []
    public var local = LocalMap()
    /// Each program's bytes over its open connections, for the traffic history.
    public var totals: [String: UInt64] = [:]

    public init() {}
}

public struct NetworkScan: Codable, Sendable {
    public var programs: [ListeningProgram]
    public var outgoing: [Talker]
    public var firewall: Bool?
    public var scannedAt: Date
    /// The processes that lead from launchd to each listening program.
    public var tree: [ProcessNode]
    /// Bytes each program exchanged with other machines over its open connections.
    public var traffic: [TrafficProgram]
    /// Connections between programs on this Mac.
    public var local: LocalMap

    public init(
        programs: [ListeningProgram], outgoing: [Talker], firewall: Bool?, scannedAt: Date,
        tree: [ProcessNode] = [], traffic: [TrafficProgram] = [], local: LocalMap = LocalMap()
    ) {
        self.programs = programs
        self.outgoing = outgoing
        self.firewall = firewall
        self.scannedAt = scannedAt
        self.tree = tree
        self.traffic = traffic
        self.local = local
    }

    /// High-risk programs plus programs whose connections raised an alert.
    public var attentionCount: Int {
        programs.filter { $0.risk == .high }.count + outgoing.filter(\.hasAlert).count
    }

    /// JSON for the chart page: dates as milliseconds since 1970.
    public func chartJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// A regular expression that is compiled once and reused.
struct Pattern: @unchecked Sendable {
    private let regex: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func test(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Capture groups of the first match; index 0 is the whole match.
    func first(_ text: String) -> [String?]? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { groups($0, in: text) }
    }

    func all(_ text: String) -> [[String?]] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { groups($0, in: text) }
    }

    func replacing(_ text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private func groups(_ match: NSTextCheckingResult, in text: String) -> [String?] {
        (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
