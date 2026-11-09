import Foundation

/// Connections to other machines: which program talks to whom, who owns each address,
/// whether the program is signed, and what looks unusual.
/// Plain text in, plain data out: `NetworkScanner` runs the commands and keeps the caches.
public enum Outgoing {
    public enum Proto: String, Sendable {
        case tcp, udp
    }

    public struct Link: Equatable, Sendable {
        public var pid: Int32
        public var process: String
        public var local: String
        public var ip: String
        public var port: Int
        public var proto: Proto

        public init(pid: Int32, process: String, local: String, ip: String, port: Int, proto: Proto) {
            self.pid = pid
            self.process = process
            self.local = local
            self.ip = ip
            self.port = port
            self.proto = proto
        }
    }

    public struct Owned: Equatable, Sendable {
        public var owner: String
        public var host: String

        public init(owner: String, host: String = "") {
            self.owner = owner
            self.host = host
        }
    }

    public struct Signature: Equatable, Sendable {
        public var signer: String
        public var isValid: Bool

        public init(signer: String, isValid: Bool) {
            self.signer = signer
            self.isValid = isValid
        }
    }

    public struct Seen: Codable, Equatable, Sendable {
        public var first: Date
        public var last: Date
    }

    /// What earlier scans saw, so a new program or a dropped service stands out.
    public struct History: Codable, Equatable, Sendable {
        /// The first scan ever: what ran then is not news.
        public var baseline: Date?
        public var programs: [String: Seen] = [:]
        /// Keyed "program→owner".
        public var pairs: [String: Seen] = [:]

        public init() {}
    }

    /// The owner shown while an address is still being looked up.
    public static let lookingUp = "Looking up…"
    public static let unknownOwner = "Unknown"
    public static let localNetwork = "Local network"
    /// The signer recorded when a running program's file is gone from disk.
    public static let missingFile = "missing"

    // MARK: Parsing

    /// `lsof -nP -iTCP -sTCP:ESTABLISHED -Fpcn` (or `-iUDP`): "n10.0.0.2:5123->17.1.2.3:443".
    public static func parseLinks(_ text: String, proto: Proto) -> [Link] {
        var links: [Link] = []
        var pid: Int32 = 0
        var process = ""
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            if tag == "p" {
                pid = Int32(value) ?? 0
            } else if tag == "c" {
                process = String(value)
            } else if tag == "n", let arrow = value.range(of: "->") {
                let remote = value[arrow.upperBound...]
                guard let colon = remote.lastIndex(of: ":"), let port = Int(remote[remote.index(after: colon)...]) else { continue }
                var ip = remote[..<colon]
                if ip.hasPrefix("[") { ip = ip.dropFirst() }
                if ip.hasSuffix("]") { ip = ip.dropLast() }
                guard !ip.isEmpty, !isLoopback(String(ip)) else { continue }
                links.append(Link(
                    pid: pid, process: process, local: String(value[..<arrow.lowerBound]),
                    ip: String(ip), port: port, proto: proto
                ))
            }
        }
        return links
    }

    /// `lsof -a -d txt -Fpn -p 1,2`: the first txt of each pid is its executable.
    public static func parseExecutables(_ text: String) -> [Int32: String] {
        var paths: [Int32: String] = [:]
        var pid: Int32?
        for line in text.split(separator: "\n") {
            if line.first == "p" {
                pid = Int32(line.dropFirst())
            } else if line.first == "n", let pid, paths[pid] == nil {
                paths[pid] = String(line.dropFirst())
            }
        }
        return paths
    }

    public static func isLoopback(_ ip: String) -> Bool {
        ip.hasPrefix("127.") || ip == "::1"
    }

    private static let privateV4 = Pattern(#"^(10\.|192\.168\.|169\.254\.)"#)
    private static let privateV4b = Pattern(#"^172\.(1[6-9]|2\d|3[01])\."#)
    private static let privateV6 = Pattern(#"^(fe80|fd|fc)"#, .caseInsensitive)

    public static func isLocal(_ ip: String) -> Bool {
        privateV4.test(ip) || privateV4b.test(ip) || privateV6.test(ip)
    }

    /// IPv6 written out in full: eight hextets, lower case, no leading zeros dropped.
    public static func expand6(_ ip: String) -> [String]? {
        guard ip.contains(":") else { return nil }
        let lower = ip.lowercased()
        let halves = lower.components(separatedBy: "::")
        let head = halves[0].isEmpty ? [] : halves[0].components(separatedBy: ":")
        let tail = halves.count > 1 && !halves[1].isEmpty ? halves[1].components(separatedBy: ":") : []
        let missing = 8 - head.count - tail.count
        guard missing >= 0 else { return nil }
        let all = head + (halves.count > 1 ? Array(repeating: "0", count: missing) : []) + tail
        guard all.count == 8 else { return nil }
        return all.map { String(repeating: "0", count: max(0, 4 - $0.count)) + $0 }
    }

    private static let inet6 = Pattern(#"^\s*inet6 ([0-9a-f:]+)"#, [.anchorsMatchLines, .caseInsensitive])

    /// ifconfig's global IPv6 addresses → their /64s: a phone or Mac on the same
    /// Wi-Fi often connects from an address in one of them, not a fe80 one.
    public static func localPrefixes(_ ifconfig: String) -> [String] {
        var prefixes: [String] = []
        for match in inet6.all(ifconfig) {
            guard let address = match[1], let full = expand6(address), full[0] != "fe80", full[0] != "0000" else { continue }
            let prefix = full.prefix(4).joined(separator: ":")
            if !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
        return prefixes
    }

    // MARK: Who owns an address

    /// Owners of the addresses most machines talk to all day, so most lookups
    /// never leave the Mac. IPv4 as CIDR, IPv6 as a hextet prefix.
    private static let owners: [(range: String, owner: String)] = [
        ("160.79.104.0/23", "Anthropic"), ("2607:6bc0:", "Anthropic"),
        ("104.16.0.0/13", "Cloudflare"), ("172.64.0.0/13", "Cloudflare"), ("162.159.0.0/16", "Cloudflare"),
        ("2606:4700:", "Cloudflare"), ("2a06:98c1:", "Cloudflare"),
        ("142.250.0.0/15", "Google"), ("172.217.0.0/16", "Google"), ("216.58.192.0/19", "Google"), ("74.125.0.0/16", "Google"),
        ("2001:4860:", "Google"), ("2607:f8b0:", "Google"),
        ("130.211.0.0/16", "Google Cloud"), ("34.0.0.0/8", "Google Cloud"), ("35.184.0.0/13", "Google Cloud"), ("2600:190", "Google Cloud"),
        ("17.0.0.0/8", "Apple"), ("2620:149:", "Apple"), ("2403:300:", "Apple"),
        ("140.82.112.0/20", "GitHub"), ("185.199.108.0/22", "GitHub"), ("192.30.252.0/22", "GitHub"),
        ("157.240.0.0/16", "Meta"), ("31.13.64.0/18", "Meta"), ("2a03:2880:", "Meta"),
        ("2602:f79a:", "Notion"),
        ("13.64.0.0/11", "Microsoft"), ("20.0.0.0/8", "Microsoft"), ("40.64.0.0/10", "Microsoft"), ("172.176.0.0/12", "Microsoft"),
    ]

    private static func ipv4(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false).map { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil && $0! <= 255 }) else { return nil }
        return parts.reduce(0) { $0 << 8 | $1! }
    }

    /// The owner, when the address is local or in the built-in table. `lan` holds this Mac's own IPv6 /64s.
    public static func ownerByPrefix(_ ip: String, lan: [String] = []) -> String? {
        if isLocal(ip) { return localNetwork }
        if let full = expand6(ip), lan.contains(full.prefix(4).joined(separator: ":")) { return localNetwork }
        let v4 = ipv4(ip)
        for (range, owner) in owners {
            if let slash = range.firstIndex(of: "/") {
                guard let v4, let base = ipv4(String(range[..<slash])), let bits = UInt32(range[range.index(after: slash)...]) else {
                    continue
                }
                let mask: UInt32 = bits == 0 ? 0 : ~0 << (32 - bits)
                if v4 & mask == base & mask { return owner }
            } else if v4 == nil, ip.lowercased().hasPrefix(range) {
                return owner
            }
        }
        return nil
    }

    private static let domains: [(Pattern, String)] = [
        (Pattern(#"\.amazonaws\.com\.?$"#), "AWS"), (Pattern(#"\.cloudfront\.net\.?$"#), "AWS CloudFront"),
        (Pattern(#"\.(1e100\.net|google\.com)\.?$"#), "Google"), (Pattern(#"\.googleusercontent\.com\.?$"#), "Google Cloud"),
        (Pattern(#"\.github\.com\.?$"#), "GitHub"), (Pattern(#"\.(facebook\.com|fbcdn\.net)\.?$"#), "Meta"),
        (Pattern(#"\.(aaplimg|apple)\.com\.?$"#), "Apple"), (Pattern(#"\.(akamai\w*|akamaitechnologies)\.(com|net)\.?$"#), "Akamai"),
        (Pattern(#"\.fastly\.net\.?$"#), "Fastly"), (Pattern(#"\.(azure|microsoft|msedge)\.\w+\.?$"#), "Microsoft"),
    ]

    /// `dig +short -x IP`: "ec2-18-97-36-58.compute-1.amazonaws.com."
    public static func ownerByHost(_ host: String) -> String? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty else { return nil }
        if let known = domains.first(where: { $0.0.test(h) }) { return known.1 }
        // Otherwise the registrable part: lb-1.iad.example.com → example.com.
        let labels = (h.hasSuffix(".") ? String(h.dropLast()) : h).split(separator: ".")
        return labels.suffix(2).joined(separator: ".")
    }

    /// ARIN hands other regions' addresses to their own registry.
    private static let registries: [(Pattern, String)] = [
        (Pattern("RIPE"), "whois.ripe.net"),
        (Pattern("Asia Pacific Network|APNIC"), "whois.apnic.net"),
        (Pattern("Latin American and Caribbean|LACNIC"), "whois.lacnic.net"),
        (Pattern("African Network|AFRINIC"), "whois.afrinic.net"),
    ]

    /// One name per company, whichever source named it.
    private static let brands: [(Pattern, String)] = [
        (Pattern("^Amazon", .caseInsensitive), "AWS"), (Pattern("^Google", .caseInsensitive), "Google"),
        (Pattern("^Microsoft", .caseInsensitive), "Microsoft"), (Pattern("^Cloudflare", .caseInsensitive), "Cloudflare"),
        (Pattern("^Akamai", .caseInsensitive), "Akamai"), (Pattern("^Fastly", .caseInsensitive), "Fastly"),
        (Pattern("^Apple", .caseInsensitive), "Apple"), (Pattern("^(Facebook|Meta Platforms)", .caseInsensitive), "Meta"),
        (Pattern("^Anthropic", .caseInsensitive), "Anthropic"), (Pattern("^GitHub", .caseInsensitive), "GitHub"),
    ]

    private static let companySuffix = Pattern(#",?\s+(Inc|LLC|PBC|Ltd|Corp|Corporation|L\.L\.C|Co\., Ltd)\.?$"#, .caseInsensitive)

    private static func tidyOrg(_ org: String) -> String {
        if let brand = brands.first(where: { $0.0.test(org) }) { return brand.1 }
        return companySuffix.replacing(org, with: "").trimmingCharacters(in: .whitespaces)
    }

    private static let orgName = Pattern(#"^OrgName:\s*(.+)$"#, .anchorsMatchLines)
    private static let descrLine = Pattern(#"^descr:\s*(.+)$"#, [.anchorsMatchLines, .caseInsensitive])
    private static let otherOrgName = Pattern(#"^org-name:\s*(.+)$"#, [.anchorsMatchLines, .caseInsensitive])
    private static let netName = Pattern(#"^netname:\s*(.+)$"#, [.anchorsMatchLines, .caseInsensitive])
    private static let streetAddress = Pattern(#"^\d|#|\b(road|street|floor|building|plaza)\b"#, .caseInsensitive)

    /// whois: ARIN's "OrgName:", or another registry's "org-name:" / "descr:".
    public static func ownerByWhois(_ text: String) -> (owner: String?, referTo: String?) {
        func field(_ pattern: Pattern) -> String? {
            pattern.first(text)?[1]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let org = field(orgName)
        if let refer = registries.first(where: { $0.0.test(org ?? "") })?.1 { return (nil, refer) }
        if let org { return (tidyOrg(org), nil) }
        // Other registries: the org's name, else the first descr line that is not a street address.
        let descr = descrLine.all(text)
            .compactMap { $0[1]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !streetAddress.test($0) }
        let other = field(otherOrgName) ?? descr ?? field(netName)
        return (other.map(tidyOrg), nil)
    }

    // MARK: Signatures

    private static let adhoc = Pattern("^Signature=adhoc", .anchorsMatchLines)
    private static let authority = Pattern("^Authority=(.+)$", .anchorsMatchLines)
    private static let appleSigning = Pattern("^(macOS |Apple Mac OS Application |)Software Signing$")
    private static let developerID = Pattern(#"^Developer ID Application: (.+?)(?: \([A-Z0-9]+\))?$"#)
    private static let appStore = Pattern("^Apple (Development|Distribution)")

    /// `codesign -dv --verbose=2` (it writes to stderr).
    public static func parseCodesign(_ text: String) -> String {
        if text.contains("not signed at all") { return "unsigned" }
        if adhoc.test(text) { return "ad-hoc" }
        let signer = authority.first(text)?[1] ?? ""
        if appleSigning.test(signer) { return "Apple" }
        if let developer = developerID.first(signer)?[1] { return developer }
        if appStore.test(signer) { return "App Store" }
        return signer.isEmpty ? "unknown" : signer
    }

    /// The bundle to check: the innermost .app holding the executable, else the file.
    public static func bundle(of path: String) -> String {
        guard let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { return path }
        return String(path[..<range.lowerBound]) + ".app"
    }

    // MARK: Grouping and flags

    private static let pushDaemon = Pattern("(^|/)apsd$")

    public static func talkerName(process: String, path: String) -> String {
        if path.contains(".simruntime/") { return "iOS Simulator · \(process)" }
        if pushDaemon.test(path) { return "Apple Push" }
        if path.hasSuffix("identityservicesd") { return "Messages & Continuity" }
        if process == "claude" { return "Claude Code" }
        return PortScan.app(of: path) ?? process
    }

    private static let usualPorts: Set<Int> = [
        443, 80, 5223, 5228, 993, 995, 465, 587, 22, 53, 853, 9418, 3478, 3479, 3480, 3481, 19302, 19305,
    ]

    public static func buildTalkers(
        links: [Link], paths: [Int32: String], owners: [String: Owned], signatures: [String: Signature],
        listening: [Int32: [Int]], history: History, now: Date
    ) -> [Talker] {
        struct Group {
            var path: String
            var process: String
            var pids = Set<Int32>()
            var links: [(link: Link, inbound: Bool)] = []
        }
        var names: [String] = []
        var groups: [String: Group] = [:]
        for link in links {
            let path = paths[link.pid] ?? link.process
            let name = talkerName(process: link.process, path: path)
            if groups[name] == nil {
                groups[name] = Group(path: path, process: link.process)
                names.append(name)
            }
            let localPort = link.local.lastIndex(of: ":").flatMap { Int(link.local[link.local.index(after: $0)...]) }
            let inbound = localPort.map { listening[link.pid]?.contains($0) == true } ?? false
            groups[name]?.pids.insert(link.pid)
            groups[name]?.links.append((link, inbound))
        }

        var talkers: [Talker] = []
        for name in names {
            guard let group = groups[name] else { continue }
            var owned: [String] = []
            var peers: [String: Peer] = [:]
            // Outgoing first, then what came in, so a peer's ports and addresses lead with what the program chose.
            for (link, inbound) in group.links.filter({ !$0.inbound }) + group.links.filter(\.inbound) {
                let own = owners[link.ip]
                let owner = own?.owner ?? lookingUp
                if peers[owner] == nil {
                    peers[owner] = Peer(owner: owner, count: 0, ports: [], ips: [], hosts: [], inbound: 0)
                    owned.append(owner)
                }
                peers[owner]?.count += 1
                if peers[owner]?.ports.contains(link.port) == false { peers[owner]?.ports.append(link.port) }
                if let ips = peers[owner]?.ips, !ips.contains(link.ip), ips.count < 4 { peers[owner]?.ips.append(link.ip) }
                if let host = own?.host, !host.isEmpty, let hosts = peers[owner]?.hosts, !hosts.contains(host), hosts.count < 3 {
                    peers[owner]?.hosts.append(host)
                }
                if inbound { peers[owner]?.inbound += 1 }
            }
            let list = owned.compactMap { peers[$0] }.sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.owner < $1.owner
            }
            let section: ProgramSection = group.path.contains(".simruntime/")
                ? .apps : PortScan.section(of: group.path, process: group.process)
            let signature = signatures[bundle(of: group.path)]
            let seen = history.programs[name]
            var flags: [ConnectionFlag] = []

            if signature?.signer == "unsigned" {
                flags.append(ConnectionFlag(.alert, "Not code-signed"))
            } else if let signature, !signature.isValid {
                flags.append(ConnectionFlag(.alert, "Signature doesn't verify: the program changed after it was signed"))
            } else if signature?.signer == "ad-hoc" {
                flags.append(ConnectionFlag(.note, "Ad-hoc signed: built on this Mac, no developer identity"))
            } else if signature?.signer == missingFile {
                flags.append(ConnectionFlag(.note, "Its file is no longer on disk: updated or deleted while it runs"))
            }
            for peer in list {
                if peer.inbound > 0, peer.owner != localNetwork {
                    flags.append(ConnectionFlag(.alert, "\(peer.owner) connected in to a port you're listening on"))
                } else if peer.inbound > 0 {
                    flags.append(ConnectionFlag(.note, "A device on your network connected in"))
                }
                let odd = peer.ports.filter { !usualPorts.contains($0) }
                if peer.owner != localNetwork, peer.inbound == 0, !odd.isEmpty {
                    let ports = odd.prefix(3).map(String.init).joined(separator: ", ")
                    flags.append(ConnectionFlag(.note, "Unusual port \(ports) to \(peer.owner)"))
                }
                if peer.owner == unknownOwner, let ip = peer.ips.first {
                    flags.append(ConnectionFlag(.note, "\(ip) has no known owner"))
                }
            }
            if section == .servers {
                let to = list.prefix(3).map(\.owner).joined(separator: ", ")
                flags.append(ConnectionFlag(.note, "A program you started talks out to \(to)"))
            }
            // The first scan ever is the baseline: what runs then is not news.
            if let baseline = history.baseline,
               seen == nil || (seen!.first > baseline && now.timeIntervalSince(seen!.first) < PortScan.day) {
                flags.append(ConnectionFlag(.note, "New: first seen talking out today"))
            }

            // Services it talked to in the last day that it isn't talking to now.
            let prefix = name + "→"
            var dropped: [(owner: String, last: Date)] = []
            for (pair, seen) in history.pairs where pair.hasPrefix(prefix) {
                let owner = String(pair.dropFirst(prefix.count))
                if now.timeIntervalSince(seen.last) < PortScan.day, peers[owner] == nil {
                    dropped.append((owner, seen.last))
                }
            }
            dropped.sort { $0.last != $1.last ? $0.last > $1.last : $0.owner < $1.owner }
            let earlier = dropped.prefix(6).map(\.owner)

            talkers.append(Talker(
                name: name, section: section, path: group.path, pids: group.pids.sorted(),
                signer: signature?.signer, peers: list, count: group.links.count, flags: flags,
                firstSeen: seen?.first ?? now, earlier: earlier
            ))
        }

        func level(_ talker: Talker) -> Int { talker.hasAlert ? 0 : talker.flags.isEmpty ? 2 : 1 }
        return talkers.sorted {
            if level($0) != level($1) { return level($0) < level($1) }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name < $1.name
        }
    }

    /// What the scan saw, folded into the history: programs, and program→owner pairs.
    public static func remember(_ history: History, _ talkers: [Talker], now: Date) -> History {
        var next = history
        for talker in talkers {
            next.programs[talker.name] = Seen(first: next.programs[talker.name]?.first ?? now, last: now)
            for peer in talker.peers where peer.owner != lookingUp {
                let key = talker.name + "→" + peer.owner
                next.pairs[key] = Seen(first: next.pairs[key]?.first ?? now, last: now)
            }
        }
        // Forget what has not been seen for a week (a month for programs).
        next.pairs = next.pairs.filter { now.timeIntervalSince($0.value.last) <= 7 * PortScan.day }
        next.programs = next.programs.filter { now.timeIntervalSince($0.value.last) <= 30 * PortScan.day }
        next.baseline = history.baseline ?? now
        return next
    }
}
