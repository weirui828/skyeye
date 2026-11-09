import Foundation

/// One address a program exchanged bytes with.
public struct TrafficPeer: Codable, Hashable, Sendable {
    public var owner: String
    /// The reverse DNS name when one is known, else the address.
    public var host: String
    public var bytesIn: UInt64
    public var bytesOut: UInt64
}

/// What a program sent to and received from other machines over its open connections.
public struct TrafficProgram: Codable, Hashable, Sendable {
    public var name: String
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var peers: [TrafficPeer]
}

/// A program in the map of connections inside this Mac.
public struct LocalNode: Codable, Hashable, Sendable {
    public var id: String
    /// The project, "Apps", "macOS" or "Other": what the map groups by.
    public var group: String
    /// The SkyEye service this program is, if any.
    public var service: String?
}

/// Connections from one program to a port another program listens on, on this Mac.
public struct LocalLink: Codable, Hashable, Sendable {
    public var from: String
    public var to: String
    public var port: Int
    public var count: Int
    public var bytes: UInt64
    /// When both ends are SkyEye services: whether `from` lists `to` as a dependency. Nil otherwise.
    public var declared: Bool?
}

public struct LocalMap: Codable, Hashable, Sendable {
    public var nodes: [LocalNode] = []
    public var links: [LocalLink] = []

    public init() {}
}

/// A process in the tree that leads from launchd to each listening program.
public struct ProcessNode: Codable, Hashable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    /// The ports it listens on; empty for the wrappers and apps above a listener.
    public var ports: [Int]
    public var risk: PortRisk?
    public var section: ProgramSection?
}

/// Bytes per second for each program over the last few minutes.
public struct TrafficHistory: Codable, Sendable {
    public struct Series: Codable, Hashable, Sendable {
        public var name: String
        /// One value per entry of `times`.
        public var rates: [Double]
    }

    public var times: [Date] = []
    public var series: [Series] = []

    public init() {}

    /// JSON for the chart page: dates as milliseconds since 1970.
    public func chartJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Reading nettop, and turning its flows into who sent how much to whom.
/// Plain text in, plain data out: `NetworkScanner` runs the command and knows the processes.
public enum Traffic {
    public struct Flow: Equatable, Sendable {
        public var pid: Int32
        /// tcp4, tcp6, udp4 or udp6.
        public var proto: String
        public var localPort: Int
        public var ip: String
        public var port: Int
        public var state: String
        public var bytesIn: UInt64
        public var bytesOut: UInt64

        public init(
            pid: Int32, proto: String = "tcp4", localPort: Int = 0, ip: String, port: Int,
            state: String = "Established", bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        ) {
            self.pid = pid
            self.proto = proto
            self.localPort = localPort
            self.ip = ip
            self.port = port
            self.state = state
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
        }

        public var bytes: UInt64 { bytesIn + bytesOut }
    }

    /// A program that connects to another on this Mac.
    public struct Client: Equatable, Sendable {
        public var id: String
        public var group: String
        public var service: String?

        public init(id: String, group: String, service: String? = nil) {
            self.id = id
            self.group = group
            self.service = service
        }
    }

    private static let processLine = Pattern(#"^[^,]*,(.*)\.(\d+),,,"#)
    private static let socketLine = Pattern(#"^[^,]*,(tcp|udp)([46]) ([^ ,]+)<->([^ ,]+),"#)

    private enum Endpoint {
        /// "*:*", or a listening socket's "*:8080".
        case any
        case address(ip: String, port: Int)
        /// Not something nettop prints for a socket.
        case invalid
    }

    /// `nettop -L 1 -x -n`: a header, then for each process a "name.pid" line followed by its sockets,
    /// "tcp4 10.0.0.2:5123<->17.1.2.3:443,en0,Established,bytes_in,bytes_out,…". Sockets with no far end are skipped.
    ///
    /// A program picks its own name, and could pick one with a comma in it or one that reads like a socket line,
    /// so that its sockets are counted under the program listed before it. A line therefore only starts a process
    /// when `kernelName` has that name for that pid, and after any line that is neither that nor a well-formed
    /// socket, sockets are dropped until the next process the kernel vouches for.
    public static func parseNettop(_ text: String, kernelName: (Int32) -> String?) -> [Flow] {
        var flows: [Flow] = []
        var pid: Int32?
        for line in text.split(separator: "\n").dropFirst() {
            let line = String(line)
            if let match = processLine.first(line), let name = match[1], let owner = match[2].flatMap({ Int32($0) }),
               let known = kernelName(owner), name == known || (name.count >= 15 && known.hasPrefix(name)) {
                pid = owner
                continue
            }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let match = socketLine.first(line), let proto = match[1], let family = match[2],
                  let near = match[3], let far = match[4], fields.count > 5 else {
                pid = nil
                continue
            }
            let local = endpoint(near, v6: family == "6")
            switch (local, endpoint(far, v6: family == "6")) {
            case (.invalid, _), (_, .invalid):
                pid = nil
            case (_, .address(let ip, let port)):
                guard let pid else { continue }
                var localPort = 0
                if case .address(_, let number) = local { localPort = number }
                flows.append(Flow(
                    pid: pid, proto: proto + family, localPort: localPort, ip: ip, port: port,
                    state: String(fields[3]), bytesIn: UInt64(fields[4]) ?? 0, bytesOut: UInt64(fields[5]) ?? 0
                ))
            case (_, .any):
                break
            }
        }
        return flows
    }

    /// "17.1.2.3:443" or, for IPv6, "2606:4700::6810:922.443"; "*" stands for any address or any port.
    private static func endpoint(_ text: String, v6: Bool) -> Endpoint {
        guard let split = text.lastIndex(of: v6 ? "." : ":") else { return .invalid }
        var host = text[..<split]
        let port = text[text.index(after: split)...]
        if host == "*" { return port == "*" || Int(port) != nil ? .any : .invalid }
        if let scope = host.firstIndex(of: "%") { host = host[..<scope] }
        guard let number = Int(port), (0...65535).contains(number), Outgoing.isAddress(String(host)),
              host.contains(":") == v6 else { return .invalid }
        return .address(ip: String(host), port: number)
    }

    private static let multicast = Pattern(#"^(22[4-9]|23\d|255)\.|^ff"#, .caseInsensitive)

    /// Bytes exchanged with other machines, per program and then per address, largest first.
    public static func programs(
        flows: [Flow], names: [Int32: String], owners: [String: Outgoing.Owned], lan: [String] = []
    ) -> [TrafficProgram] {
        var order: [String] = []
        var byName: [String: [String: TrafficPeer]] = [:]
        for flow in flows where !Outgoing.isLoopback(flow.ip) && flow.bytes > 0 {
            let name = names[flow.pid] ?? "pid \(flow.pid)"
            let known = owners[flow.ip]
            let owner = multicast.test(flow.ip) ? Outgoing.localNetwork
                : known?.owner ?? Outgoing.ownerByPrefix(flow.ip, lan: lan) ?? Outgoing.unknownOwner
            let host = known.flatMap { $0.host.isEmpty ? nil : $0.host } ?? flow.ip
            if byName[name] == nil {
                byName[name] = [:]
                order.append(name)
            }
            var peer = byName[name]?[host] ?? TrafficPeer(owner: owner, host: host, bytesIn: 0, bytesOut: 0)
            peer.bytesIn += flow.bytesIn
            peer.bytesOut += flow.bytesOut
            byName[name]?[host] = peer
        }
        return order.map { name in
            let peers = (byName[name] ?? [:]).values.sorted {
                let (a, b) = ($0.bytesIn + $0.bytesOut, $1.bytesIn + $1.bytesOut)
                return a != b ? a > b : $0.host < $1.host
            }
            return TrafficProgram(
                name: name, bytesIn: peers.reduce(0) { $0 + $1.bytesIn }, bytesOut: peers.reduce(0) { $0 + $1.bytesOut },
                peers: peers
            )
        }
        .sorted {
            let (a, b) = ($0.bytesIn + $0.bytesOut, $1.bytesIn + $1.bytesOut)
            return a != b ? a > b : $0.name < $1.name
        }
    }

    /// What the map groups a listening program under.
    public static func group(of program: ListeningProgram) -> String {
        switch program.section {
        case .apps: "Apps"
        case .system: "macOS"
        case .servers: program.project ?? "Other"
        }
    }

    /// One name per listening program: its service or its own name, with the port added where two would collide.
    public static func labels(for programs: [ListeningProgram]) -> [Int32: String] {
        let plain = programs.map { $0.service ?? $0.name }
        var seen: [String: Int] = [:]
        for name in plain { seen[name, default: 0] += 1 }
        var labels: [Int32: String] = [:]
        for (program, name) in zip(programs, plain) {
            let port = program.ports.first.map { " :\($0.port)" } ?? ""
            labels[program.pid] = seen[name] == 1 ? name : name + port
        }
        return labels
    }

    /// Who connects to whom on this Mac. `client` names the program behind a pid that isn't itself a listener.
    /// `dependencies` maps each SkyEye service to the services it declares it needs.
    public static func localMap(
        flows: [Flow], programs: [ListeningProgram], dependencies: [String: [String]] = [:],
        client: (Int32) -> Client?
    ) -> LocalMap {
        let labels = labels(for: programs)
        var listener: [Int: ListeningProgram] = [:]
        for program in programs {
            for port in program.ports where listener[port.port] == nil { listener[port.port] = program }
        }
        var nodes: [String: LocalNode] = [:]
        for program in programs where program.section == .servers {
            let id = labels[program.pid] ?? program.name
            nodes[id] = LocalNode(id: id, group: group(of: program), service: program.service)
        }

        var order: [String] = []
        var links: [String: LocalLink] = [:]
        // A connection shows up twice, once per end. The client's end is the one whose far port is a listening port.
        for flow in flows where Outgoing.isLoopback(flow.ip) && flow.state != "Listen" {
            guard let server = listener[flow.port], server.pid != flow.pid, let from = client(flow.pid) else { continue }
            let to = LocalNode(id: labels[server.pid] ?? server.name, group: group(of: server), service: server.service)
            guard from.id != to.id else { continue }
            if nodes[from.id] == nil { nodes[from.id] = LocalNode(id: from.id, group: from.group, service: from.service) }
            if nodes[to.id] == nil { nodes[to.id] = to }
            let key = from.id + "\u{0}" + to.id
            if links[key] == nil {
                let declared = from.service.flatMap { a in to.service.map { b in dependencies[a]?.contains(b) == true } }
                links[key] = LocalLink(from: from.id, to: to.id, port: flow.port, count: 0, bytes: 0, declared: declared)
                order.append(key)
            }
            links[key]?.count += 1
            links[key]?.bytes += flow.bytes
        }
        var map = LocalMap()
        map.nodes = nodes.values.sorted {
            let groups = $0.group.localizedStandardCompare($1.group)
            return groups != .orderedSame ? groups == .orderedAscending : $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
        map.links = order.compactMap { links[$0] }.sorted {
            $0.count != $1.count ? $0.count > $1.count : ($0.from, $0.to) < ($1.from, $1.to)
        }
        return map
    }

    /// What a process is called in the tree and the map: the app, the script, or the executable.
    /// `executable` is the file the kernel reports; the command line stands in for it only when that isn't known.
    public static func displayName(_ command: String, executable: String? = nil) -> String {
        let path = executable ?? command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
        if let app = PortScan.app(of: executable ?? command) { return PortScan.plain(app) }
        let process = path.split(separator: "/").last.map(String.init) ?? path
        return PortScan.plain(PortScan.script(of: command, process: process))
    }

    /// Every listening program and the chain of processes that leads to it from launchd.
    /// `paths` holds each process's executable, where it is known.
    public static func tree(
        programs: [ListeningProgram], procs: [Int32: PortScan.Proc], paths: [Int32: String] = [:]
    ) -> [ProcessNode] {
        var nodes: [Int32: ProcessNode] = [1: ProcessNode(pid: 1, ppid: 0, name: "launchd", ports: [], risk: nil, section: nil)]
        for program in programs {
            nodes[program.pid] = ProcessNode(
                pid: program.pid, ppid: procs[program.pid]?.ppid ?? 1, name: program.name,
                ports: program.ports.map(\.port), risk: program.risk, section: program.section
            )
        }
        for program in programs {
            var at = procs[program.pid]?.ppid
            for _ in 0..<24 {
                guard let pid = at, pid > 1, nodes[pid] == nil, let proc = procs[pid] else { break }
                nodes[pid] = ProcessNode(
                    pid: pid, ppid: proc.ppid, name: displayName(proc.command, executable: paths[pid]),
                    ports: [], risk: nil, section: nil
                )
                at = proc.ppid
            }
        }
        // A parent that ps didn't list: hang the process from launchd so the tree stays whole.
        return nodes.values.map { node in
            var node = node
            if node.pid != 1, nodes[node.ppid] == nil { node.ppid = 1 }
            return node
        }
        .sorted { $0.pid < $1.pid }
    }

    /// Turns the byte counts of successive samples into rates, and keeps the last `capacity` of them.
    public struct Recorder: Sendable {
        public private(set) var history = TrafficHistory()
        private var last: (at: Date, totals: [String: UInt64])?
        private let capacity: Int

        public init(capacity: Int = 36) {
            self.capacity = capacity
        }

        /// `totals` is each program's bytes over its open connections. A total that fell means connections closed,
        /// not that bytes were un-sent: that counts as nothing new.
        public mutating func record(_ totals: [String: UInt64], at now: Date) {
            defer { last = (now, totals) }
            guard let last, now > last.at else { return }
            let seconds = now.timeIntervalSince(last.at)
            var rates = Dictionary(uniqueKeysWithValues: history.series.map { ($0.name, $0.rates) })
            for name in Set(rates.keys).union(totals.keys) {
                let before = last.totals[name]
                let after = totals[name] ?? 0
                let rate = before.map { after > $0 ? Double(after - $0) / seconds : 0 } ?? 0
                rates[name, default: Array(repeating: 0, count: history.times.count)].append(rate)
            }
            history.times.append(now)
            if history.times.count > capacity {
                history.times.removeFirst()
                for name in rates.keys { rates[name]?.removeFirst() }
            }
            history.series = rates
                .filter { $0.value.contains { $0 > 0 } }
                .map { TrafficHistory.Series(name: $0.key, rates: $0.value) }
                .sorted { $0.name < $1.name }
        }
    }
}
