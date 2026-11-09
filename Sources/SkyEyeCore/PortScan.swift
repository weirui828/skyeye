import Darwin
import Foundation

/// Reading lsof and ps, and turning what they say into programs with a risk.
/// Everything here is plain text in, plain data out: `NetworkScanner` runs the commands and the HTTP probes.
public enum PortScan {
    public static let day: TimeInterval = 86_400

    public struct BoundPort: Equatable, Sendable {
        public var port: Int
        public var address: String
    }

    public struct Listener: Equatable, Sendable {
        public var pid: Int32
        public var process: String
        public var ports: [BoundPort]
    }

    public struct Proc: Equatable, Sendable {
        public var pid: Int32
        public var ppid: Int32
        /// Seconds since the process started.
        public var seconds: Int
        public var rssKb: Int
        public var cpu: Double
        public var command: String
    }

    // MARK: Parsing

    /// `lsof -nP -iTCP -sTCP:LISTEN -Fpcn`: "p123", "cnode", "f12", "n127.0.0.1:3000".
    public static func parseLsof(_ text: String) -> [Listener] {
        var order: [Int32] = []
        var byPid: [Int32: Listener] = [:]
        var current: Int32?
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                current = Int32(value)
                if let pid = current, byPid[pid] == nil {
                    byPid[pid] = Listener(pid: pid, process: "", ports: [])
                    order.append(pid)
                }
            case "c":
                if let pid = current { byPid[pid]?.process = value }
            case "n":
                guard let pid = current, let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                // IPv4 and IPv6 twins of one port: keep the wider of the two.
                if let twin = byPid[pid]?.ports.firstIndex(where: { $0.port == port }) {
                    if exposure(of: address).rank > exposure(of: byPid[pid]!.ports[twin].address).rank {
                        byPid[pid]?.ports[twin].address = address
                    }
                } else {
                    byPid[pid]?.ports.append(BoundPort(port: port, address: address))
                }
            default:
                break
            }
        }
        return order.compactMap { pid in
            guard var listener = byPid[pid] else { return nil }
            listener.ports.sort { $0.port < $1.port }
            return listener
        }
    }

    private static let psLine = Pattern(#"^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\d+)\s+([\d.]+)\s+(.*)$"#)

    /// `ps -axo pid=,ppid=,etime=,rss=,%cpu=,command=`
    public static func parsePs(_ text: String) -> [Int32: Proc] {
        var procs: [Int32: Proc] = [:]
        for line in text.split(separator: "\n") {
            guard let m = psLine.first(String(line)), let pid = m[1].flatMap({ Int32($0) }) else { continue }
            procs[pid] = Proc(
                pid: pid,
                ppid: m[2].flatMap { Int32($0) } ?? 0,
                seconds: parseEtime(m[3] ?? ""),
                rssKb: m[4].flatMap { Int($0) } ?? 0,
                cpu: m[5].flatMap { Double($0) } ?? 0,
                command: trimEnd(m[6] ?? "")
            )
        }
        return procs
    }

    /// "11-15:12:58", "04:46:06", "13:01" → seconds.
    public static func parseEtime(_ text: String) -> Int {
        let split = text.split(separator: "-", maxSplits: 1)
        let days = split.count == 2 ? Int(split[0]) ?? 0 : 0
        let clock = split.count == 2 ? split[1] : Substring(text)
        var parts = clock.split(separator: ":").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.insert(0, at: 0) }
        return days * 86_400 + parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    public static func exposure(of address: String) -> Exposure {
        if address == "*" || address == "0.0.0.0" || address == "[::]" { return .all }
        if address.hasPrefix("127.") || address == "[::1]" || address == "localhost" { return .loopback }
        return .lan
    }

    public static func widest(_ ports: [ListeningPort]) -> Exposure {
        ports.reduce(.loopback) { $1.exposure.rank > $0.rank ? $1.exposure : $0 }
    }

    /// Where a probe reaches the port: the address it is bound to, loopback for a wildcard.
    public static func probeURL(_ port: ListeningPort, path: String = "/") -> URL? {
        let host = port.exposure == .all ? "127.0.0.1" : port.address
        return URL(string: "http://\(host):\(port.port)\(path)")
    }

    private static let titleTag = Pattern(#"<title[^>]*>([^<]{1,80})"#, .caseInsensitive)

    /// The page's `<title>`, when the body has one.
    public static func pageTitle(_ body: String) -> String? {
        guard let raw = titleTag.first(body)?[1] else { return nil }
        let title = plain(raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\""))
        return title.isEmpty ? nil : title
    }

    /// A name as one line of plain text. Titles and file names come from other programs: control characters and
    /// the invisible ones that reorder text (so a name can read as something else) are dropped, runs of space folded.
    public static func plain(_ text: String) -> String {
        let kept = text.unicodeScalars.map { scalar -> Character in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator: " "
            default: Character(scalar)
            }
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// True when the command line asks for a debugger on `port`.
    public static func hasDebuggerFlag(_ command: String, port: Int) -> Bool {
        Pattern(#"--(inspect(-brk)?=(\S+:)?\#(port)|remote-debugging-port=\#(port))(\s|$)"#).test(command)
    }

    // MARK: Naming

    private static let friendly: [String: String] = [
        "rapportd": "Continuity",
        "ControlCenter": "AirPlay Receiver",
        "postgres": "PostgreSQL",
        "mysqld": "MySQL",
        "redis-server": "Redis",
        "mongod": "MongoDB",
        "claude": "Claude Code",
        "codex": "Codex",
        "agy": "Antigravity",
        "zed": "Zed",
        "gemini": "Gemini CLI",
        "ollama": "Ollama",
    ]
    /// Command-line agents and editors: their ports belong to an open session, never Stop them.
    private static let tools: Set<String> = ["claude", "codex", "agy", "zed", "gemini", "cursor-agent", "ollama"]
    /// Names that only mean something for macOS's own copy of the program.
    private static let systemNames: Set<String> = ["rapportd", "ControlCenter"]

    private static let databaseProcesses: Set<String> = [
        "postgres", "mysqld", "mariadbd", "redis-server", "mongod", "clickhouse", "memcached",
    ]
    private static let databasePorts: Set<Int> = [5432, 3306, 6379, 27017, 9200, 5984, 11211, 8529, 7687, 9042, 26257, 8123]

    /// What a server answers when it wants a login (or a token in the URL).
    public static func isLoginWall(_ status: Int?) -> Bool {
        status == 401 || status == 403 || status == 407
    }

    public static func isDatabasePort(_ port: Int, process: String) -> Bool {
        databasePorts.contains(port) || databaseProcesses.contains(process)
    }

    private static let appBundle = Pattern(#"/([^/]+)\.app/Contents/"#)

    /// The app a path is inside, if any.
    public static func app(of path: String) -> String? {
        guard let name = appBundle.first(path)?[1] else { return nil }
        return name == "claude" ? "Claude Code" : name
    }

    private static let systemPath = Pattern(#"^/(System|usr/libexec|usr/sbin|sbin)/"#)

    /// `path` is the executable the kernel reports (`ProcessTable.executable`), never the command line: a process
    /// writes its own arguments, and one that called itself `/usr/libexec/…` would pass for part of macOS.
    /// Pass "" when the path isn't known: the program is then treated as a server, which hides nothing.
    public static func section(of path: String, process: String) -> ProgramSection {
        if systemPath.test(path) { return .system }
        if app(of: path) != nil || tools.contains(process) { return .apps }
        return .servers
    }

    private static let interpreter = Pattern(#"^(node|bun|deno|python[\d.]*|ruby|java)$"#)
    private static let packageBin = Pattern(#"node_modules/(?:\.bin/)?([^/.][^/]*)"#)
    private static let scriptSuffix = Pattern(#"\.(m?js|cjs|ts|py|rb)$"#)

    /// "python -m atlas.serve …" → atlas.serve; "node …/.bin/vite" → vite.
    public static func script(of command: String, process: String) -> String {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        if let module = words.firstIndex(of: "-m"), module + 1 < words.count { return words[module + 1] }
        let first = words.first?.split(separator: "/").last.map(String.init) ?? ""
        guard interpreter.test(first), let script = words.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
            return process
        }
        // A package's own bin, however pnpm nests it: the last node_modules/<name>.
        if let package = packageBin.all(script).last?[1] { return package }
        let file = script.split(separator: "/").last.map(String.init) ?? script
        return scriptSuffix.replacing(file, with: "")
    }

    /// Page titles that say nothing about what the server is.
    private static let genericTitle = Pattern(
        #"^(error|not found|40\d\b.*|index of\b.*|untitled|document|home|browser|loading\b.*|welcome)$"#, .caseInsensitive
    )

    /// `executable` decides what kind of program this is; `command` only names the script an interpreter runs.
    public static func name(of command: String, executable: String, process: String, ports: [ListeningPort]) -> String {
        let section = section(of: executable, process: process)
        // An app's own name beats whatever page its helper serves.
        if section == .servers, let title = ports.compactMap(\.title).first(where: { !genericTitle.test($0) }) {
            return title
        }
        if let known = friendly[process], section == .system || !systemNames.contains(process) { return known }
        return plain(app(of: executable) ?? script(of: command, process: process))
    }

    // MARK: Who started it

    private static let claudeSession = Pattern(#"/claude\.app/Contents/MacOS/claude|(^|/)claude(\s|$)"#)
    private static let terminals = Pattern(
        #"/(Terminal|iTerm2?|Warp|Ghostty|Alacritty|kitty|WezTerm|Hyper)\.app/|(^|/)(tmux|screen)(\s|$)"#, .caseInsensitive
    )
    private static let wrapper = Pattern(
        #"(^|/)(sh|bash|zsh|dash) -c |(^|/)(npm|pnpm|yarn|npx|bunx|uv|poetry|pipenv|turbo|nodemon|concurrently)(\s|$)|(^|/)bun run |node_modules/\.bin/"#
    )

    /// `paths` and `names` hold each ancestor's executable and kernel name, where they are known: what a parent
    /// is goes by those, not by the arguments it gave itself.
    public static func startedBy(
        _ pid: Int32, _ procs: [Int32: Proc], paths: [Int32: String] = [:], names: [Int32: String] = [:]
    ) -> String {
        var at = procs[pid]?.ppid
        for _ in 0..<8 {
            guard let parent = at else { break }
            if parent <= 1 { return "launchd" }
            guard let p = procs[parent] else { break }
            let what = paths[parent] ?? p.command
            // Claude Code's own binary is a file named by its version; the kernel still calls the process claude.
            if claudeSession.test(what) || names[parent] == "claude" { return "Claude session" }
            if terminals.test(what) { return "terminal" }
            if let app = app(of: what) { return plain(app) }
            at = p.ppid
        }
        return "unknown"
    }

    /// The listener, and the wrappers right above it that would outlive it or restart it.
    public static func stopPids(_ pid: Int32, _ procs: [Int32: Proc]) -> [Int32] {
        var pids = [pid]
        var at = procs[pid]?.ppid
        for _ in 0..<4 {
            guard let parent = at, parent > 1, let p = procs[parent],
                  wrapper.test(p.command), !p.command.contains("claude") else { break }
            pids.append(parent)
            at = p.ppid
        }
        return pids
    }

    /// The first of `roots` that is `pid` or one of its ancestors.
    public static func ancestor<T>(of pid: Int32, in roots: [Int32: T], _ procs: [Int32: Proc]) -> T? {
        var at: Int32? = pid
        for _ in 0..<16 {
            guard let current = at, current > 1 else { break }
            if let found = roots[current] { return found }
            at = procs[current]?.ppid
        }
        return nil
    }

    // MARK: Where it runs

    /// `root` is the folder that holds the project's repository; pass "" when there is none.
    public static func place(of folder: String?, root: String, home: String) -> (project: String?, place: String) {
        guard let folder, folder != "/", folder != home else { return (nil, "") }
        if !root.isEmpty, folder.hasPrefix(root + "/") {
            let parts = folder.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let project = parts.first ?? ""
            let rest = Array(parts.dropFirst())
            if rest.count > 2, rest[0] == ".claude", rest[1] == "worktrees", !rest[2].isEmpty {
                return (project, (["worktree", rest[2]] + rest.dropFirst(3)).joined(separator: " / "))
            }
            return (project, rest.joined(separator: "/"))
        }
        return (nil, folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder)
    }

    // MARK: Risk

    public struct Assessment: Equatable, Sendable {
        public var kind: ProgramKind
        public var risk: PortRisk
        public var reasons: [String]
        public var exposure: Exposure
    }

    public static func assess(name: String, process: String, section: ProgramSection, ports: [ListeningPort]) -> Assessment {
        let exposure = widest(ports)
        let debuggers = ports.filter(\.isDebugger)
        let kind: ProgramKind =
            !debuggers.isEmpty ? .debugger
            : ports.contains { isDatabasePort($0.port, process: process) } ? .database
            : ports.contains { $0.status != nil } ? .web
            : .service
        let net = exposure == .all ? "every network this Mac joins" : "your local network"
        var reasons: [String] = []
        var risk: PortRisk = section == .servers ? .low : .info
        func raise(_ to: PortRisk) { if to.rank > risk.rank { risk = to } }

        for debugger in debuggers {
            raise(.high)
            reasons.append("Debugger on \(debugger.port) with no login: any program on this Mac can take over \(name)")
        }
        if exposure != .loopback {
            let open = ports.filter { $0.exposure != .loopback }
            // Any HTTP answer but a login wall counts as open: a 404 at / still serves the rest.
            let answered = open.contains { $0.status != nil && !isLoginWall($0.status) }
            let gated = open.contains { isLoginWall($0.status) }
            if section == .system {
                raise(.medium)
                reasons.append("Open to \(net): a macOS service, switch it off in System Settings if you don't use it")
            } else if kind == .database {
                raise(.high)
                reasons.append("Database open to \(net)")
            } else if answered {
                raise(.high)
                reasons.append("Open to \(net) with no login")
            } else {
                raise(.medium)
                reasons.append("Open to \(net)" + (gated ? ", asks for a login" : ""))
            }
        }
        if reasons.isEmpty {
            let gated = ports.contains { isLoginWall($0.status) } && !ports.contains { $0.status != nil && !isLoginWall($0.status) }
            reasons.append(kind == .database ? "Database, this Mac only" : gated ? "This Mac only, asks for a login" : "This Mac only")
        }
        return Assessment(kind: kind, risk: risk, reasons: reasons, exposure: exposure)
    }

    /// A server you started that has been left running for more than a day.
    public static func isStale(_ program: ListeningProgram, now: Date) -> Bool {
        program.section == .servers && now.timeIntervalSince(program.startedAt) > day
    }

    /// Riskiest first, then longest running.
    public static func byRisk(_ a: ListeningProgram, _ b: ListeningProgram) -> Bool {
        a.risk.rank != b.risk.rank ? a.risk.rank > b.risk.rank : a.startedAt < b.startedAt
    }

    // MARK: Actions

    /// The page to open for a program, when it serves one without a login wall.
    public static func openURL(for program: ListeningProgram) -> URL? {
        // A login wall opens only through the tokened link its own tool prints.
        guard let web = program.ports.first(where: { $0.status != nil && !$0.isDebugger && !isLoginWall($0.status) }) else {
            return nil
        }
        let host = web.exposure == .loopback && web.address.hasPrefix("[") ? "[::1]" : "localhost"
        return URL(string: "http://\(host):\(web.port)/")
    }

    /// Only servers you started, and services SkyEye runs, can be stopped from here.
    public static func canStop(_ program: ListeningProgram) -> Bool {
        program.section == .servers || program.managed
    }

    /// The pids Stop may end right now. A scan can be half a minute old, and a pid can be handed to another
    /// process in that time: the listener must still be the process that was scanned, and each wrapper still its parent.
    /// It never names launchd or SkyEye itself, whatever the scan said.
    public static func currentStopPids(_ program: ListeningProgram) -> [Int32] {
        func mayStop(_ pid: Int32) -> Bool { pid > 1 && pid != getpid() }
        guard let listener = program.stopPids.first, mayStop(listener), let info = ProcessTable.info(listener) else { return [] }
        let started = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        guard abs(started.timeIntervalSince(program.startedAt)) < 5 else { return [] }
        var pids = [listener]
        var parent = Int32(info.pbi_ppid)
        for pid in program.stopPids.dropFirst() {
            guard pid == parent, mayStop(pid), let next = ProcessTable.info(pid) else { break }
            pids.append(pid)
            parent = Int32(next.pbi_ppid)
        }
        return pids
    }

    private static func trimEnd(_ text: String) -> String {
        var view = Substring(text)
        while let last = view.last, last.isWhitespace { view.removeLast() }
        return String(view)
    }
}
