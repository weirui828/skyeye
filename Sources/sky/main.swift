import Foundation
import SkyEyeCore

let usage = """
sky — control SkyEye from the terminal

USAGE
  sky list [--json]                     List services and their status
  sky status <name> [--json]            Show one service
  sky add <name> [options]              Add a service
  sky edit <name> [options]             Change a service
  sky remove <name>                     Remove a service (stops it first)
  sky start <name|@group> [--no-wait]   Start, then wait until it's up
  sky stop <name|@group>                Stop
  sky restart <name|@group> [--no-wait] Restart
  sky logs <name> [-n 100] [-f]         Show (or follow) a service's log
  sky port <port> [--kill]              Show (or stop) whatever listens on a port
  sky open <name>                       Open the service in your browser

OPTIONS FOR add / edit
  --cmd "<command>"   Start command, run in your login shell
  --port <n>          Port the service listens on
  --dir <path>        Working directory (add: defaults to the current directory)
  --health <path>     Health check path, e.g. /health
  --group <name>      Group, so `sky start @<name>` starts them together
  --depends-on <a,b> Dependencies to start first; "none" clears them
  --env KEY=VALUE     Environment variable (repeatable)
  --auto-restart      Restart automatically after a crash
  edit only: --name <new>, --unset-env KEY, --no-auto-restart,
             and "none" clears --cmd/--port/--health/--group

New or changed commands added from the terminal must be approved in the
SkyEye menu bar before they run.
"""

let valueOptions: Set<String> = ["--depends-on", "--cmd", "--port", "--dir", "--health", "--group", "--env", "--unset-env", "--name", "-n", "--lines", "--timeout"]
let flagOptions: Set<String> = ["--json", "--kill", "-f", "--follow", "--no-wait", "--auto-restart", "--no-auto-restart", "-h", "--help"]

struct Args {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    func value(_ key: String) -> String? { values[key]?.last }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

let isTTY = isatty(STDOUT_FILENO) != 0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sky: \(message)\n".utf8))
    exit(1)
}

func parse(_ raw: [String]) -> Args {
    var args = Args()
    var i = 0
    while i < raw.count {
        let s = raw[i]
        if s == "--" {
            args.positional += raw[(i + 1)...]
            break
        }
        if s.hasPrefix("-"), s.count > 1, Int(s) == nil {
            var key = s
            var inline: String?
            if s.hasPrefix("--"), let eq = s.firstIndex(of: "=") {
                key = String(s[..<eq])
                inline = String(s[s.index(after: eq)...])
            }
            if valueOptions.contains(key) {
                if let inline {
                    args.values[key, default: []].append(inline)
                } else {
                    guard i + 1 < raw.count else { fail("\(key) needs a value") }
                    args.values[key, default: []].append(raw[i + 1])
                    i += 1
                }
            } else if flagOptions.contains(key) {
                args.flags.insert(key)
            } else {
                fail("unknown option \(s) (see `sky --help`)")
            }
        } else {
            args.positional.append(s)
        }
        i += 1
    }
    return args
}

let client = ControlClient()

@discardableResult
func call(_ request: ControlRequest) -> ControlResponse {
    do {
        let response = try client.send(request)
        if !response.ok { fail(response.error ?? "request failed") }
        return response
    } catch {
        fail(error.localizedDescription)
    }
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONCoding.encoder
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try! encoder.encode(value), as: UTF8.self))
}

func color(_ state: ServiceState) -> String {
    guard isTTY else { return "" }
    switch state {
    case .running: return "\u{1B}[32m"
    case .starting, .stopping: return "\u{1B}[33m"
    case .unhealthy, .pendingApproval: return "\u{1B}[38;5;208m"
    case .crashed: return "\u{1B}[31m"
    case .external: return "\u{1B}[35m"
    case .stopped: return "\u{1B}[90m"
    }
}

let reset = isTTY ? "\u{1B}[0m" : ""

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}

func printTable(_ services: [ServiceSnapshot]) {
    guard !services.isEmpty else {
        print("No services yet. Add one with: sky add <name> --cmd \"npm run dev\" --port 3000")
        return
    }
    let nameWidth = max(4, services.map(\.service.name.count).max() ?? 0) + 2
    let stateWidth = 18
    print(pad("NAME", nameWidth) + pad("STATE", stateWidth) + pad("PORT", 7) + pad("PID", 8) + "DETAIL")
    for s in services {
        let state = s.state == .external ? "external" : s.state.rawValue
        print(
            pad(s.service.name, nameWidth) + color(s.state) + pad(state, stateWidth) + reset
                + pad(s.service.port.map(String.init) ?? "-", 7) + pad(s.pid.map(String.init) ?? "-", 8)
                + (s.detail ?? "")
        )
    }
}

func printStatus(_ s: ServiceSnapshot) {
    let c = s.service
    print("\(c.name): \(color(s.state))\(s.state.label)\(reset)\(s.detail.map { " — \($0)" } ?? "")")
    if let url = c.url { print("  url:          \(url)") }
    if let pid = s.pid { print("  pid:          \(pid)") }
    if let usage = s.usageSummary { print("  usage:        \(usage)") }
    if let cmd = c.command { print("  command:      \(cmd)\(s.approved ? "" : "  (not approved yet)")") }
    if let dir = c.directory { print("  directory:    \(dir)") }
    if let health = c.healthPath { print("  health check: \(health)") }
    if let group = c.group { print("  group:        \(group)") }
    if !c.dependencies.isEmpty { print("  depends on:   " + c.dependencies.joined(separator: ", ")) }
    if !c.env.isEmpty { print("  env:          \(c.env.keys.sorted().map { "\($0)=\(c.env[$0]!)" }.joined(separator: " "))") }
    if c.autoRestart { print("  auto-restart: on (\(s.autoRestarts) restarts used)") }
    if let exit = s.lastExit { print("  last exit:    \(exit)") }
    print("  log:          \(s.logFile)")
}

func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return URL(fileURLWithPath: expanded, relativeTo: cwd).standardizedFileURL.path
}

func parsePort(_ value: String) -> Int {
    guard let port = Int(value), (1...65535).contains(port) else { fail("invalid port '\(value)'") }
    return port
}

func parseEnv(_ pair: String) -> (String, String) {
    guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { fail("--env expects KEY=VALUE, got '\(pair)'") }
    return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
}

func requireName(_ args: Args, _ command: String) -> String {
    guard let name = args.positional.first else { fail("usage: sky \(command) <name>") }
    return name
}

/// Waits for each target to settle and prints the outcome. Returns false if any failed.
func waitAndReport(_ target: String, timeout: TimeInterval) -> Bool {
    let names: [String]
    do { names = try client.resolve(target) } catch { fail(error.localizedDescription) }
    var allGood = true
    for name in names {
        let s: ServiceSnapshot
        do { s = try client.waitUntilSettled(name, timeout: timeout) } catch { fail(error.localizedDescription) }
        switch s.state {
        case .running:
            let extra = [s.service.url, s.pid.map { "pid \($0)" }].compactMap { $0 }.joined(separator: ", ")
            print("\(color(.running))✓\(reset) \(name) is running\(extra.isEmpty ? "" : " (\(extra))")")
        case .starting:
            print("\(color(.starting))…\(reset) \(name) is still starting (\(s.detail ?? "")). Check `sky status \(name)` or `sky logs \(name)`.")
        case .stopped:
            print("\(color(.stopped))■\(reset) \(name) stopped")
        default:
            allGood = false
            print("\(color(s.state))✗\(reset) \(name) is \(s.state.label)\(s.detail.map { ": \($0)" } ?? "")")
            let log = (try? client.send(ControlRequest(action: .logs, name: name, lines: 20)))?.log ?? ""
            if !log.isEmpty { print("--- last lines of \(s.logFile) ---\n\(log)") }
        }
    }
    return allGood
}

// MARK: Commands

var argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first, !["-h", "--help", "help"].contains(command) else {
    print(usage)
    exit(0)
}
argv.removeFirst()
let args = parse(argv)
if args.has("-h") || args.has("--help") {
    print(usage)
    exit(0)
}

switch command {
case "list", "ls":
    let services = call(ControlRequest(action: .list)).services ?? []
    if args.has("--json") { printJSON(services) } else { printTable(services) }

case "status":
    let response = call(ControlRequest(action: .get, name: requireName(args, "status")))
    guard let s = response.service else { fail("no such service") }
    if args.has("--json") { printJSON(s) } else { printStatus(s) }

case "add":
    let name = requireName(args, "add")
    var s = ServiceConfig(name: name)
    s.command = args.value("--cmd")
    s.port = args.value("--port").map(parsePort)
    s.directory = absolutePath(args.value("--dir") ?? FileManager.default.currentDirectoryPath)
    s.healthPath = args.value("--health")
    s.group = args.value("--group")
    s.dependencies = (args.value("--depends-on") ?? "").split(separator: ",").map(String.init)
    for pair in args.values["--env"] ?? [] {
        let (k, v) = parseEnv(pair)
        s.env[k] = v
    }
    s.autoRestart = args.has("--auto-restart")
    let response = call(ControlRequest(action: .add, service: s))
    print(response.message ?? "Added '\(name)'.")

case "edit":
    let name = requireName(args, "edit")
    guard var s = call(ControlRequest(action: .get, name: name)).service?.service else { fail("no such service") }
    func clearable(_ key: String) -> String?? {
        guard let v = args.value(key) else { return .none }
        return .some(v == "none" || v.isEmpty ? nil : v)
    }
    if let v = clearable("--cmd") { s.command = v }
    if let v = clearable("--port") { s.port = v.map(parsePort) }
    if let v = args.value("--dir") { s.directory = absolutePath(v) }
    if let v = clearable("--health") { s.healthPath = v }
    if let v = clearable("--group") { s.group = v }
    if let v = args.value("--depends-on") { s.dependencies = v == "none" ? [] : v.split(separator: ",").map(String.init) }
    for pair in args.values["--env"] ?? [] {
        let (k, v) = parseEnv(pair)
        s.env[k] = v
    }
    for key in args.values["--unset-env"] ?? [] { s.env[key] = nil }
    if args.has("--auto-restart") { s.autoRestart = true }
    if args.has("--no-auto-restart") { s.autoRestart = false }
    if let newName = args.value("--name") { s.name = newName }
    let response = call(ControlRequest(action: .update, name: name, service: s))
    print(response.message ?? "Updated '\(name)'.")

case "remove", "rm":
    let response = call(ControlRequest(action: .remove, name: requireName(args, "remove")))
    print(response.message ?? "Removed.")

case "start", "restart":
    let target = requireName(args, command)
    let response = call(ControlRequest(action: command == "start" ? .start : .restart, name: target))
    if args.has("--no-wait") {
        print(response.message ?? "OK")
    } else {
        let timeout = args.value("--timeout").flatMap(Double.init) ?? 60
        exit(waitAndReport(target, timeout: timeout) ? 0 : 1)
    }

case "stop":
    let target = requireName(args, "stop")
    let response = call(ControlRequest(action: .stop, name: target))
    if args.has("--no-wait") {
        print(response.message ?? "OK")
    } else {
        exit(waitAndReport(target, timeout: 15) ? 0 : 1)
    }

case "logs":
    let name = requireName(args, "logs")
    let lines = (args.value("-n") ?? args.value("--lines")).flatMap(Int.init) ?? 100
    if args.has("-f") || args.has("--follow") {
        guard let path = call(ControlRequest(action: .get, name: name)).service?.logFile else { fail("no such service") }
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-n", String(lines), "-F", path]
        do { try tail.run() } catch { fail(error.localizedDescription) }
        tail.waitUntilExit()
    } else {
        let log = call(ControlRequest(action: .logs, name: name, lines: lines)).log ?? ""
        print(log.isEmpty ? "(no output yet)" : log)
    }

case "port":
    guard let raw = args.positional.first else { fail("usage: sky port <port> [--kill]") }
    let port = parsePort(raw)
    if args.has("--kill") {
        print(call(ControlRequest(action: .killPort, port: port)).message ?? "Done.")
    } else {
        let response = call(ControlRequest(action: .port, port: port))
        let listeners = response.listeners ?? []
        if listeners.isEmpty {
            print("Nothing is listening on port \(port).")
        } else {
            for l in listeners { print("\(port)  \(l.command)  pid \(l.pid)") }
        }
        if let message = response.message { print(message) }
    }

case "open":
    let name = requireName(args, "open")
    guard let url = call(ControlRequest(action: .get, name: name)).service?.service.url else {
        fail("'\(name)' has no port")
    }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [url]
    try? open.run()
    open.waitUntilExit()

default:
    fail("unknown command '\(command)' (see `sky --help`)")
}
