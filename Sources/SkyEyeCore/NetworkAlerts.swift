import Foundation

/// Something on the network worth telling the user about, from one background scan.
public struct NetworkAlert: Codable, Hashable, Identifiable, Sendable {
    /// The program and the reason: the same alert in the next scan has the same id.
    public var id: String
    public var program: String
    public var text: String
    public var at: Date

    public init(program: String, text: String, at: Date) {
        id = program + "\u{0}" + text
        self.program = program
        self.text = text
        self.at = at
    }
}

/// What the alerts remember between scans and launches: what was already said, what the user trusts or
/// muted, and how much each program usually uploads.
public struct AlertState: Codable, Equatable, Sendable {
    /// When each alert last made a notification.
    public var notified: [String: Date] = [:]
    /// Programs the user trusts: they raise no alerts.
    public var trusted: Set<String> = []
    /// Programs whose alerts make no notification until then.
    public var mutedUntil: [String: Date] = [:]
    /// Each program's usual upload, in bytes per minute.
    public var typicalUpload: [String: Double] = [:]
    public var uploadSamples: [String: Int] = [:]
    /// Bytes each program had sent over its open connections at the last scan.
    public var lastSent: [String: UInt64] = [:]
    public var lastScan: Date?

    public init() {}
}

public enum NetworkAlerts {
    /// Remote ports that ordinary programs have little reason to use, and what usually listens there.
    public static let riskyPorts: [Int: String] = [
        4444: "a common backdoor port", 1337: "a common backdoor port", 31337: "a common backdoor port",
        6666: "IRC, often used to control malware", 6667: "IRC, often used to control malware",
        6697: "IRC, often used to control malware",
        9001: "Tor", 9030: "Tor", 9050: "Tor", 9051: "Tor", 9150: "Tor Browser",
    ]
    /// An alert that is still true is said again after this long.
    public static let repeatAfter: TimeInterval = 24 * 60 * 60
    public static let muteFor: TimeInterval = 24 * 60 * 60
    /// An upload spike is at least this many bytes per minute, and this many times the program's usual.
    static let spikeFloor = 50.0 * 1_000_000
    static let spikeFactor = 10.0
    /// Scans before a program's usual upload is known; until then only a very large upload counts.
    static let learningScans = 5
    static let learningCeiling = 500.0 * 1_000_000

    public struct Result: Sendable {
        /// Every alert that holds now, trusted programs left out.
        public var current: [NetworkAlert]
        /// The ones to notify about now.
        public var fresh: [NetworkAlert]
        public var state: AlertState
    }

    /// The alerts in one scan: the scan's own alert flags, risky ports, and upload spikes.
    public static func evaluate(talkers: [Talker], traffic: [TrafficProgram], state: AlertState, now: Date) -> Result {
        var state = state
        var alerts: [NetworkAlert] = []
        for talker in talkers {
            for flag in talker.flags where flag.level == .alert {
                alerts.append(NetworkAlert(program: talker.name, text: flag.text, at: now))
            }
            for peer in talker.peers where peer.inbound == 0 {
                for port in peer.ports.sorted() {
                    guard let what = riskyPorts[port] else { continue }
                    alerts.append(NetworkAlert(program: talker.name, text: "Connects to \(peer.owner) on port \(port), \(what)", at: now))
                }
            }
        }

        // Upload since the last scan, per minute. A long gap (sleep, the setting turned off) starts over.
        let interval = state.lastScan.map { now.timeIntervalSince($0) } ?? 0
        let comparable = interval >= 10 && interval <= 15 * 60
        var sent: [String: UInt64] = [:]
        for program in traffic { sent[program.name, default: 0] += program.bytesOut }
        for (name, bytes) in sent {
            defer { state.lastSent[name] = bytes }
            // Connections that closed take their bytes with them: a drop says nothing.
            guard comparable, let before = state.lastSent[name], bytes > before else { continue }
            let perMinute = Double(bytes - before) / interval * 60
            let samples = state.uploadSamples[name, default: 0]
            let typical = state.typicalUpload[name]
            let spike = samples < learningScans
                ? perMinute > learningCeiling
                : perMinute > max(spikeFloor, spikeFactor * (typical ?? 0))
            if spike {
                let usual = typical.map { " (usually \(Self.bytes($0)) a minute)" } ?? ""
                alerts.append(NetworkAlert(program: name, text: "Uploading \(Self.bytes(perMinute)) a minute\(usual)", at: now))
            } else {
                // A spike does not become the new usual.
                state.typicalUpload[name] = typical.map { $0 * 0.9 + perMinute * 0.1 } ?? perMinute
                state.uploadSamples[name] = samples + 1
            }
        }
        state.lastSent = state.lastSent.filter { sent[$0.key] != nil }
        state.lastScan = now

        let current = alerts.filter { !state.trusted.contains($0.program) }
        var fresh: [NetworkAlert] = []
        for alert in current {
            if let until = state.mutedUntil[alert.program], until > now { continue }
            if let last = state.notified[alert.id], now.timeIntervalSince(last) < repeatAfter { continue }
            state.notified[alert.id] = now
            fresh.append(alert)
        }
        // Forget what was said long ago, and mutes that ran out.
        state.notified = state.notified.filter { now.timeIntervalSince($0.value) < 7 * repeatAfter }
        state.mutedUntil = state.mutedUntil.filter { $0.value > now }
        return Result(current: current, fresh: fresh, state: state)
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .file)
    }

    /// JSON for the Monitoring page: the alerts and what the user can do about them.
    public static func chartJSON(_ alerts: [NetworkAlert], muted: [String: Date], now: Date) -> String {
        struct Item: Encodable { var id, program, text: String; var at: Date; var muted: Bool }
        let items = alerts.map { Item(id: $0.id, program: $0.program, text: $0.text, at: $0.at, muted: (muted[$0.program] ?? .distantPast) > now) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(["alerts": items])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
