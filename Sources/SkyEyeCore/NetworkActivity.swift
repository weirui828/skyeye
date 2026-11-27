import Foundation

public struct ActivityNode: Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var pids: [Int32]
}

public struct ActivityLink: Codable, Sendable {
    public var id: String
    public var from: String
    public var to: String
    public var local: Bool
    public var connections: Int
    public var sent: Double
    public var received: Double
    public var ports: [Int]
    public var hosts: [String]
    public var protocols: [String]
}

public struct NetworkActivity: Codable, Sendable {
    public var at: Date
    public var warmingUp: Bool
    public var nodes: [ActivityNode]
    public var links: [ActivityLink]
    public var sent: Double
    public var received: Double
    public var internalRate: Double

    public func chartJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

public enum Activity {
    public struct Identity: Sendable {
        public var id: String
        public var name: String
        public var kind: String

        public init(id: String, name: String, kind: String = "program") {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    private struct Socket: Hashable {
        var pid: Int32
        var proto: String
        var local: String
        var localPort: Int
        var remote: String
        var remotePort: Int

        init(_ flow: Traffic.Flow) {
            pid = flow.pid; proto = flow.proto
            local = flow.localIP; localPort = flow.localPort
            remote = flow.ip; remotePort = flow.port
        }

        var address: Address { Address(proto: proto, ip: local, port: localPort, remote: remote, remotePort: remotePort) }
    }

    private struct Address: Hashable {
        var proto: String
        var ip: String
        var port: Int
        var remote: String
        var remotePort: Int

        var reverse: Address { Address(proto: proto, ip: remote, port: remotePort, remote: ip, remotePort: port) }
    }

    private struct Counter {
        var incoming: UInt64 = 0
        var outgoing: UInt64 = 0
    }

    public struct Recorder {
        private var previous: [Socket: Counter] = [:]
        private var last: Date?

        public init() {}

        public mutating func record(
            _ flows: [Traffic.Flow], identities: [Int32: Identity] = [:],
            owners: [String: Outgoing.Owned] = [:], at now: Date = Date()
        ) -> NetworkActivity {
            let elapsed = last.map { now.timeIntervalSince($0) } ?? 0
            let validInterval = elapsed > 0 && elapsed < 5
            var counters: [Socket: Counter] = [:]
            for flow in flows where flow.state != "Listen" && flow.state != "Closed" {
                let key = Socket(flow)
                counters[key, default: Counter()].incoming += flow.bytesIn
                counters[key, default: Counter()].outgoing += flow.bytesOut
            }
            let addresses = Dictionary(counters.keys.map { ($0.address, $0.pid) }, uniquingKeysWith: min)
            let localIPs = Set(counters.keys.map(\.local).filter { !$0.isEmpty })
            var nodes: [String: ActivityNode] = [:]
            var links: [String: ActivityLink] = [:]
            var upload = 0.0, download = 0.0, internalRate = 0.0

            func program(_ pid: Int32) -> ActivityNode {
                let identity = identities[pid] ?? Identity(id: "pid:\(pid)", name: "Process \(pid)")
                var node = nodes[identity.id] ?? ActivityNode(id: identity.id, name: identity.name, kind: identity.kind, pids: [])
                if !node.pids.contains(pid) { node.pids.append(pid) }
                nodes[node.id] = node
                return node
            }

            for (socket, count) in counters {
                let local = Outgoing.isLoopback(socket.remote) || localIPs.contains(socket.remote)
                let reversePID = local ? addresses[socket.address.reverse] : nil
                // Both socket ends report the same traffic. Keep one end, including for self-connections.
                if let reversePID,
                   socket.pid > reversePID || (socket.pid == reversePID && socket.localPort > socket.remotePort) { continue }
                let source = program(socket.pid)
                let target: ActivityNode
                if let reversePID {
                    target = program(reversePID)
                } else if local {
                    let id = "local:\(socket.proto):\(socket.remote):\(socket.remotePort)"
                    target = ActivityNode(id: id, name: "\(socket.remote):\(socket.remotePort)", kind: "local", pids: [])
                    nodes[id] = target
                } else {
                    let owner = owners[socket.remote]?.owner ?? Outgoing.ownerByPrefix(socket.remote) ?? Outgoing.unknownOwner
                    // Keep unidentified addresses separate, instead of implying one remote service owns them all.
                    let name = owner == Outgoing.unknownOwner ? socket.remote : owner
                    let id = "remote:\(name)"
                    target = ActivityNode(id: id, name: name, kind: "remote", pids: [])
                    nodes[id] = target
                }
                let prior = previous[socket]
                let incoming: Double
                let outgoing: Double
                if validInterval {
                    incoming = Self.rate(count.incoming, prior?.incoming, elapsed)
                    outgoing = Self.rate(count.outgoing, prior?.outgoing, elapsed)
                } else { incoming = 0; outgoing = 0 }
                if local { internalRate += incoming + outgoing }
                else { upload += outgoing; download += incoming }

                let ordered = local && source.id > target.id
                let from = ordered ? target.id : source.id
                let to = ordered ? source.id : target.id
                let key = from + "\u{0}" + to
                var link = links[key] ?? ActivityLink(
                    id: key, from: from, to: to, local: local, connections: 0, sent: 0, received: 0,
                    ports: [], hosts: [], protocols: []
                )
                link.connections += 1
                link.sent += ordered ? incoming : outgoing
                link.received += ordered ? outgoing : incoming
                for port in local ? [socket.localPort, socket.remotePort] : [socket.remotePort] {
                    if !link.ports.contains(port) { link.ports.append(port) }
                }
                let host = owners[socket.remote].flatMap { $0.host.isEmpty ? nil : $0.host } ?? socket.remote
                for address in [socket.remote, host] where !link.hosts.contains(address) { link.hosts.append(address) }
                let proto = socket.proto.hasPrefix("tcp") ? "TCP" : "UDP"
                if !link.protocols.contains(proto) { link.protocols.append(proto) }
                links[key] = link
            }
            previous = counters
            last = now
            return NetworkActivity(
                at: now, warmingUp: !validInterval,
                nodes: nodes.values.map { node in
                    var node = node; node.pids.sort(); return node
                }.sorted { $0.id < $1.id },
                links: links.values.map { link in
                    var link = link
                    link.ports.sort(); link.hosts.sort(); link.protocols.sort()
                    return link
                }.sorted { $0.id < $1.id },
                sent: upload, received: download, internalRate: internalRate
            )
        }

        private static func rate(_ value: UInt64, _ prior: UInt64?, _ interval: Double) -> Double {
            guard let prior else { return Double(value) / interval }
            return value >= prior ? Double(value - prior) / interval : 0
        }
    }
}

/// nettop repeats its CSV header before every sample; byte chunks can split a UTF-8 name.
public struct NettopFrames {
    private var pending = Data()
    private var lines: [String] = []
    private var size = 0
    public private(set) var overflowed = false

    public init() {}

    public static func sampledAt(_ frame: String, near now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let row = frame.split(separator: "\n").dropFirst().first,
              let time = row.split(separator: ",").first else { return nil }
        let parts = time.split(separator: ":")
        guard parts.count == 3, let hour = Int(parts[0]), let minute = Int(parts[1]), let second = Double(parts[2]),
              (0..<24).contains(hour), (0..<60).contains(minute), second >= 0, second < 60,
              let day = calendar.date(bySettingHour: hour, minute: minute, second: Int(second), of: now) else { return nil }
        var date = day.addingTimeInterval(second - floor(second))
        if date.timeIntervalSince(now) > 43_200 { date = calendar.date(byAdding: .day, value: -1, to: date) ?? date }
        else if now.timeIntervalSince(date) > 43_200 { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var frames: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            if line.hasPrefix("time,,interface,state,bytes_in,bytes_out,") {
                if !lines.isEmpty { frames.append(lines.joined(separator: "\n")) }
                lines = [line]
                size = line.utf8.count
            } else if !lines.isEmpty {
                lines.append(line)
                size += line.utf8.count
            }
            if size > 8 * 1024 * 1024 { overflowed = true; lines = []; size = 0 }
        }
        if pending.count > 8 * 1024 * 1024 { overflowed = true; pending.removeAll() }
        return frames
    }
}
