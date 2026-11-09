import Foundation

/// Runs the commands and HTTP probes behind the ports page and keeps what stays true between scans:
/// what each port answered, who owns each address, each program's signature, and the connection history.
/// Use one scanner from one queue; a scan blocks until its commands finish.
public final class NetworkScanner: @unchecked Sendable {
    /// A SkyEye service, so its listener can be shown as that service.
    public struct Service: Sendable {
        public var name: String
        /// The process SkyEye started for it, when it is running.
        public var pid: Int32?
        public var port: Int?
        /// The services it declares it needs.
        public var dependencies: [String]

        public init(name: String, pid: Int32? = nil, port: Int? = nil, dependencies: [String] = []) {
            self.name = name
            self.pid = pid
            self.port = port
            self.dependencies = dependencies
        }
    }

    private struct OwnerRecord: Codable {
        var owner: String
        var host: String
        var at: Date
        /// The public registries were asked, not only reverse DNS.
        var whois: Bool
    }

    private struct Store: Codable {
        var owners: [String: OwnerRecord] = [:]
        var history = Outgoing.History()
    }

    fileprivate struct Probe {
        var status: Int?
        var title: String?
        var isDebugger = false
    }

    private static let lookupsPerScan = 8
    private static let signaturesPerScan = 6
    /// A program can open ports faster than they can be asked what they are: the rest wait for the next scan.
    private static let probesPerScan = 48
    private static let ownerTTL: TimeInterval = 30 * PortScan.day
    private static let maxOwners = 2000
    /// Folders macOS asks permission for; looking inside them would raise a prompt.
    private static let protectedFolders: Set<String> = ["Documents", "Desktop", "Downloads", "Library"]

    private let storeURL: URL?
    private let home: String
    private let prober = HTTPProber()
    private var store = Store()
    /// What a port answered, per pid:port. A program's ports do not change what they are, so each is asked once.
    private var probed: [String: Probe] = [:]
    /// Each executable's signature, checked once per launch.
    private var signatures: [String: Outgoing.Signature] = [:]
    private var roots: [String: String] = [:]
    /// From the last listening and outgoing scans, for the traffic scan that follows them.
    private var procs: [Int32: PortScan.Proc] = [:]
    private var services: [Service] = []
    private var lan: [String] = []

    /// `storeURL` keeps address owners and the connection history between launches; nil keeps them in memory only.
    public init(storeURL: URL? = nil, home: String = NSHomeDirectory()) {
        self.storeURL = storeURL
        self.home = home
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONCoding.decoder.decode(Store.self, from: data) {
            store = saved
        }
    }

    // MARK: Listening

    public func scanListening(services: [Service] = [], now: Date = Date()) -> ListeningScan {
        let commands: [(String, [String])] = [
            ("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]),
            ("/bin/ps", ["-axww", "-o", "pid=,ppid=,etime=,rss=,%cpu=,command="]),
            ("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]),
        ]
        let outputs = Self.parallel(commands.count) { Command.run(commands[$0].0, commands[$0].1).output }
        let listening = PortScan.parseLsof(outputs[0])
        let procs = PortScan.parsePs(outputs[1])
        self.procs = procs
        self.services = services
        let state = outputs[2].lowercased()
        let firewall: Bool? = state.contains("enabled") ? true : state.contains("disabled") ? false : nil

        // What each listener and each process above it really is: the file it runs, from the kernel.
        // Its command line is its own to write, so that only ever names a script.
        var paths: [Int32: String] = [:]
        var kernelNames: [Int32: String] = [:]
        for listener in listening {
            var at: Int32? = listener.pid
            for _ in 0..<24 {
                guard let pid = at, pid > 1, paths[pid] == nil, let path = ProcessTable.executable(pid) else { break }
                paths[pid] = path
                kernelNames[pid] = ProcessTable.name(pid)
                at = procs[pid]?.ppid
            }
        }
        let names = listening.map { kernelNames[$0.pid] ?? $0.process }
        let sections = listening.enumerated().map { i, listener in
            PortScan.section(of: paths[listener.pid] ?? "", process: names[i])
        }

        var ports = listening.map { $0.ports.map { ListeningPort(port: $0.port, address: $0.address) } }
        var pending: [(listener: Int, port: Int, key: String, command: String)] = []
        for (i, listener) in listening.enumerated() {
            let command = procs[listener.pid]?.command ?? names[i]
            for (j, port) in ports[i].enumerated() {
                let key = "\(listener.pid):\(port.port)"
                if let known = probed[key] {
                    ports[i][j].apply(known)
                } else if sections[i] != .system, !PortScan.isDatabasePort(port.port, process: names[i]) {
                    // A database speaks its own protocol: an HTTP request only fills its log.
                    pending.append((i, j, key, command))
                }
            }
        }
        // The servers you started first, then app helpers.
        let jobs = Array(pending.filter { sections[$0.listener] == .servers }.prefix(Self.probesPerScan))
            + pending.filter { sections[$0.listener] != .servers }.prefix(Self.probesPerScan / 2)
        let targets = jobs.map { ports[$0.listener][$0.port] }
        let answers = Self.parallel(jobs.count) { [prober] in Self.probe(targets[$0], command: jobs[$0].command, with: prober) }
        for (job, answer) in zip(jobs, answers) {
            probed[job.key] = answer
            ports[job.listener][job.port].apply(answer)
        }
        // A pid gone: forget what its ports answered.
        let live = Set(listening.map { String($0.pid) })
        probed = probed.filter { live.contains(String($0.key.prefix { $0 != ":" })) }

        let managed = Dictionary(services.compactMap { s in s.pid.map { ($0, s.name) } }, uniquingKeysWith: { first, _ in first })
        let programs = listening.enumerated().map { i, listener -> ListeningProgram in
            let proc = procs[listener.pid]
            let process = names[i]
            let command = proc?.command ?? process
            let section = sections[i]
            let name = PortScan.name(of: command, executable: paths[listener.pid] ?? "", process: process, ports: ports[i])
            let assessment = PortScan.assess(name: name, process: process, section: section, ports: ports[i])
            let folder = ProcessTable.workingDirectory(listener.pid)
            let place = PortScan.place(of: folder, root: folder.map(workspaceRoot) ?? "", home: home)
            let ours = PortScan.ancestor(of: listener.pid, in: managed, procs)
            // A port SkyEye watches but didn't start: a monitor-only service, or one started outside SkyEye.
            let watched = services.first { s in s.pid == nil && ports[i].contains { $0.port == s.port } }?.name
            return ListeningProgram(
                pid: listener.pid, name: name, process: process, command: String(command.prefix(300)),
                ports: ports[i], exposure: assessment.exposure, section: section, kind: assessment.kind,
                risk: assessment.risk, reasons: assessment.reasons, project: place.project, place: place.place,
                folder: folder,
                startedBy: ours != nil ? "SkyEye" : PortScan.startedBy(listener.pid, procs, paths: paths, names: kernelNames),
                startedAt: now.addingTimeInterval(-Double(proc?.seconds ?? 0)), rssKb: proc?.rssKb ?? 0,
                cpu: proc?.cpu ?? 0, stopPids: PortScan.stopPids(listener.pid, procs),
                service: ours ?? watched, managed: ours != nil
            )
        }
        return ListeningScan(
            programs: programs.sorted(by: PortScan.byRisk), firewall: firewall, scannedAt: now,
            tree: Traffic.tree(programs: programs, procs: procs, paths: paths)
        )
    }

    private static func probe(_ port: ListeningPort, command: String, with prober: HTTPProber) -> Probe {
        var answer = Probe()
        answer.isDebugger = PortScan.hasDebuggerFlag(command, port: port.port)
        guard let url = PortScan.probeURL(port), let home = prober.get(url) else { return answer }
        answer.status = home.status
        answer.title = PortScan.pageTitle(home.body)
        if !answer.isDebugger, let version = PortScan.probeURL(port, path: "/json/version").flatMap({ prober.get($0) }) {
            answer.isDebugger = version.body.contains("webSocketDebuggerUrl")
        }
        return answer
    }

    /// The folder that holds the repository `folder` is in, so the repository's name is the project. "" when there is none.
    private func workspaceRoot(for folder: String) -> String {
        if let known = roots[folder] { return known }
        var repository: String?
        if let worktree = folder.range(of: "/.claude/worktrees/") {
            repository = String(folder[..<worktree.lowerBound])
        } else if folder.hasPrefix(home + "/"),
                  let top = folder.dropFirst(home.count + 1).split(separator: "/").first,
                  !Self.protectedFolders.contains(String(top)) {
            var directory = folder
            while directory.count > home.count {
                if FileManager.default.fileExists(atPath: directory + "/.git") {
                    repository = directory
                    break
                }
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        let root = repository.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        roots[folder] = root
        return root
    }

    // MARK: Outgoing

    /// `whois` also asks the public registries about addresses that reverse DNS doesn't name.
    public func scanOutgoing(programs: [ListeningProgram], whois: Bool = false, now: Date = Date()) -> [Talker] {
        let commands: [(String, [String])] = [
            ("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fpcn"]),
            ("/usr/sbin/lsof", ["-nP", "-iUDP", "-Fpcn"]),
            ("/sbin/ifconfig", []),
        ]
        let outputs = Self.parallel(commands.count) { Command.run(commands[$0].0, commands[$0].1).output }
        var links = Outgoing.parseLinks(outputs[0], proto: .tcp) + Outgoing.parseLinks(outputs[1], proto: .udp)
        let lan = Outgoing.localPrefixes(outputs[2])
        self.lan = lan
        guard !links.isEmpty else { return [] }
        // Each program's file and name from the kernel: exact, where lsof escapes what it prints.
        var paths: [Int32: String] = [:]
        var names: [Int32: String] = [:]
        for pid in Set(links.map(\.pid)) {
            paths[pid] = ProcessTable.executable(pid)
            names[pid] = ProcessTable.name(pid)
        }
        for i in links.indices { links[i].process = names[links[i].pid] ?? links[i].process }

        // Owners: the table answers at once; a few others are looked up per scan.
        var changed = false
        var unknown: [String] = []
        var seen = Set<String>()
        for ip in links.map(\.ip) where seen.insert(ip).inserted {
            let known = Outgoing.ownerByPrefix(ip, lan: lan)
            // The network the Mac is on changes: its own /64 is checked every scan.
            if let cached = store.owners[ip], isFresh(cached, whois: whois, now: now), known == nil || cached.owner == known {
                continue
            }
            if let known {
                store.owners[ip] = OwnerRecord(owner: known, host: "", at: now, whois: false)
                changed = true
            } else {
                unknown.append(ip)
            }
        }
        let lookups = Array(unknown.prefix(Self.lookupsPerScan))
        let found = Self.parallel(lookups.count) { Self.lookUp(lookups[$0], whois: whois) }
        for (ip, owned) in zip(lookups, found) {
            store.owners[ip] = OwnerRecord(owner: owned.owner, host: owned.host, at: now, whois: whois)
            changed = true
        }
        if store.owners.count > Self.maxOwners {
            let oldest = store.owners.sorted { $0.value.at < $1.value.at }.prefix(store.owners.count - Self.maxOwners)
            for (ip, _) in oldest { store.owners[ip] = nil }
        }

        let unchecked = Set(paths.values.map(Outgoing.bundle)).filter { $0.hasPrefix("/") && signatures[$0] == nil }
        let bundles = Array(unchecked.sorted().prefix(Self.signaturesPerScan))
        let checked = Self.parallel(bundles.count) { [home] in Self.checkSignature(bundles[$0], home: home) }
        for (bundle, signature) in zip(bundles, checked) { signatures[bundle] = signature }

        let talkers = Outgoing.buildTalkers(
            links: links, paths: paths,
            owners: store.owners.mapValues { Outgoing.Owned(owner: $0.owner, host: $0.host) },
            signatures: signatures,
            listening: Dictionary(programs.map { ($0.pid, $0.ports.map(\.port)) }, uniquingKeysWith: { first, _ in first }),
            history: store.history, now: now
        )
        let history = Outgoing.remember(store.history, talkers, now: now)
        if changed || history != store.history {
            store.history = history
            save()
        }
        return talkers
    }

    // MARK: Traffic

    /// Bytes per program and address, and the connections inside this Mac. Call it after the listening and
    /// outgoing scans: it names processes and addresses from what they found.
    public func scanTraffic(programs: [ListeningProgram], talkers: [Talker]) -> TrafficScan {
        // SkyEye's own probes and health checks are not something the user's programs did.
        let own = getpid()
        let flows = Traffic.parseNettop(
            Command.run("/usr/bin/nettop", ["-L", "1", "-x", "-n"], timeout: 10).output, kernelName: ProcessTable.name
        )
        .filter { $0.pid != own }
        let labels = Traffic.labels(for: programs)
        let listeners = Dictionary(programs.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let managed = Dictionary(services.compactMap { s in s.pid.map { ($0, s.name) } }, uniquingKeysWith: { first, _ in first })
        let procs = procs

        // The name the outgoing list uses, so a program reads the same everywhere on the page.
        var names: [Int32: String] = [:]
        for talker in talkers {
            for pid in talker.pids { names[pid] = talker.name }
        }
        for pid in Set(flows.map(\.pid)) where names[pid] == nil {
            if let program = PortScan.ancestor(of: pid, in: listeners, procs), let label = labels[program.pid] {
                names[pid] = label
            } else if let path = ProcessTable.executable(pid) {
                // Named from the file it runs, like the outgoing list: its arguments could say anything.
                let command = procs[pid]?.command ?? path
                names[pid] = Outgoing.talkerName(process: Traffic.displayName(command, executable: path), path: path)
            }
        }

        var scan = TrafficScan()
        scan.programs = Traffic.programs(
            flows: flows, names: names, owners: store.owners.mapValues { Outgoing.Owned(owner: $0.owner, host: $0.host) }, lan: lan
        )
        scan.local = Traffic.localMap(
            flows: flows, programs: programs,
            dependencies: Dictionary(services.map { ($0.name, $0.dependencies) }, uniquingKeysWith: { first, _ in first })
        ) { pid in
            if let program = PortScan.ancestor(of: pid, in: listeners, procs), let label = labels[program.pid] {
                return Traffic.Client(id: label, group: Traffic.group(of: program), service: program.service)
            }
            guard let name = names[pid] else { return nil }
            let group: String
            switch PortScan.section(of: ProcessTable.executable(pid) ?? "", process: "") {
            case .apps: group = "Apps"
            case .system: group = "macOS"
            case .servers: group = "Other"
            }
            return Traffic.Client(id: name, group: group, service: PortScan.ancestor(of: pid, in: managed, procs))
        }
        // Traffic over time is traffic with other machines, like the rest of the tab: loopback is left out.
        for flow in flows where !Outgoing.isLoopback(flow.ip) && flow.bytes > 0 {
            scan.totals[names[flow.pid] ?? "pid \(flow.pid)", default: 0] += flow.bytes
        }
        return scan
    }

    /// Only the byte counts, for the samples between full scans. Names come from the last full scan.
    public func sampleTraffic(programs: [ListeningProgram], talkers: [Talker]) -> [String: UInt64] {
        scanTraffic(programs: programs, talkers: talkers).totals
    }

    private func isFresh(_ record: OwnerRecord, whois: Bool, now: Date) -> Bool {
        guard record.owner == Outgoing.unknownOwner else { return now.timeIntervalSince(record.at) < Self.ownerTTL }
        // An address nothing could name is asked about again the next day, or as soon as whois is allowed.
        return now.timeIntervalSince(record.at) < PortScan.day && (record.whois || !whois)
    }

    private static let hostname = Pattern(#"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+\.?$"#)

    /// `ip` goes to the lookup tools as an argument: callers pass only what `Outgoing.isAddress` accepts.
    private static func lookUp(_ ip: String, whois: Bool) -> Outgoing.Owned {
        guard Outgoing.isAddress(ip) else { return Outgoing.Owned(owner: Outgoing.unknownOwner) }
        // The system resolver, not a DNS server asked directly: it follows the Mac's DNS settings,
        // so a lookup goes wherever the user's other lookups go (encrypted DNS, a VPN's resolver).
        let answer = Command.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "ip_address", ip], timeout: 4).output
        let host = answer.split(separator: "\n").first { $0.hasPrefix("name: ") }
            .map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) } ?? ""
        if hostname.test(host), let owner = Outgoing.ownerByHost(host) {
            return Outgoing.Owned(owner: owner, host: host.hasSuffix(".") ? String(host.dropLast()) : host)
        }
        guard whois else { return Outgoing.Owned(owner: Outgoing.unknownOwner) }
        var record = Outgoing.ownerByWhois(Command.run("/usr/bin/whois", ["-h", "whois.arin.net", "n \(ip)"], timeout: 8).output)
        if record.owner == nil, let registry = record.referTo {
            record = Outgoing.ownerByWhois(Command.run("/usr/bin/whois", ["-h", registry, ip], timeout: 8).output)
        }
        return Outgoing.Owned(owner: record.owner ?? Outgoing.unknownOwner)
    }

    /// Where `path` is, when it is somewhere macOS asks the user before an app may read it. SkyEye scans in the
    /// background: a permission prompt out of nowhere is not something a scan should cause.
    static func protectedPlace(of path: String, home: String) -> String? {
        if path.hasPrefix("/Volumes/") { return "another disk or a disk image" }
        guard path.hasPrefix(home + "/") else { return nil }
        let parts = path.dropFirst(home.count + 1).split(separator: "/", maxSplits: 2).map(String.init)
        switch parts.first {
        case "Desktop", "Documents", "Downloads":
            return "your \(parts[0]) folder"
        case "Library" where parts.count > 1 && ["Mobile Documents", "CloudStorage"].contains(parts[1]):
            return "a cloud storage folder"
        default:
            return nil
        }
    }

    private static func checkSignature(_ bundle: String, home: String) -> Outgoing.Signature {
        if let place = protectedPlace(of: bundle, home: home) {
            return Outgoing.Signature(signer: "", isValid: true, unread: place)
        }
        // An app updated while it runs leaves its old executable's path empty: that is not a broken signature.
        guard FileManager.default.fileExists(atPath: bundle) else {
            return Outgoing.Signature(signer: Outgoing.missingFile, isValid: true)
        }
        let info = Command.run("/usr/bin/codesign", ["-dv", "--verbose=2", bundle], timeout: 10, mergeStderr: true)
        let signer = Outgoing.parseCodesign(info.output)
        if signer == "unsigned" || signer == "ad-hoc" { return Outgoing.Signature(signer: signer, isValid: true) }
        let verify = Command.run("/usr/bin/codesign", ["--verify", "--strict", bundle], timeout: 30)
        // A check that ran out of time proves nothing either way.
        return Outgoing.Signature(signer: signer, isValid: verify.status == 0 || verify.timedOut)
    }

    private func save() {
        guard let storeURL else { return }
        let encoder = JSONCoding.encoder
        guard let data = try? encoder.encode(store) else { return }
        try? data.write(to: storeURL, options: .atomic)
        chmod(storeURL.path, 0o600)
    }

    /// Runs `work` for each index at once and returns the results in order.
    private static func parallel<T>(_ count: Int, _ work: @escaping @Sendable (Int) -> T) -> [T] {
        guard count > 0 else { return [] }
        let results = Results<T>(count: count)
        DispatchQueue.concurrentPerform(iterations: count) { results.set($0, work($0)) }
        return results.values()
    }

    private final class Results<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [T?]

        init(count: Int) { slots = Array(repeating: nil, count: count) }

        func set(_ index: Int, _ value: T) { lock.withLock { slots[index] = value } }

        func values() -> [T] { lock.withLock { slots.compactMap { $0 } } }
    }
}

private extension ListeningPort {
    mutating func apply(_ probe: NetworkScanner.Probe) {
        status = probe.status
        title = probe.title
        isDebugger = probe.isDebugger
    }
}
