import Foundation
import SkyEyeCore

// A minimal MCP server over stdio (newline-delimited JSON-RPC 2.0).
// Every tool is a thin wrapper around SkyEye's local control socket.

let client = ControlClient()
let launchDirectory = FileManager.default.currentDirectoryPath

let instructions = """
SkyEye manages the user's local development services (dev servers, workers, databases) \
from their macOS menu bar. Use these tools to register services, start/stop them, check \
whether they are healthy and read their logs. Services added or changed through these tools \
cannot start until the user approves the command in the SkyEye menu bar: when a tool reports \
that approval is needed, ask the user to approve it, then retry.
"""

// MARK: JSON-RPC plumbing

func write(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func reply(_ id: Any, result: [String: Any]) {
    write(["jsonrpc": "2.0", "id": id, "result": result])
}

func replyError(_ id: Any, code: Int, message: String) {
    write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func text(_ s: String, isError: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": s]], "isError": isError]
}

func json(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
        return "\(value)"
    }
    return String(decoding: data, as: UTF8.self)
}

// MARK: Tool schemas

func prop(_ type: String, _ description: String) -> [String: Any] { ["type": type, "description": description] }

let serviceFields: [String: Any] = [
    "command": prop("string", "Shell command that starts the service, e.g. \"npm run dev\". Runs in the user's login shell, so nvm/asdf/mise work."),
    "port": prop("integer", "TCP port the service listens on. SkyEye watches it to know when the service is up."),
    "directory": prop("string", "Absolute working directory for the command. Defaults to the directory the agent runs in."),
    "health_path": prop("string", "Optional HTTP path (e.g. /health) that must return 2xx/3xx before the service counts as running."),
    "group": prop("string", "Optional group name. Use \"@group\" as the name in start/stop/restart to act on the whole group."),
    "dependencies": ["type": "array", "items": ["type": "string"], "description": "Names of prerequisites. They start first and must become ready. Cycles are rejected; [] clears dependencies."],
    "env": ["type": "object", "additionalProperties": ["type": "string"], "description": "Extra environment variables."],
    "auto_restart": prop("boolean", "Restart automatically after a crash (up to 5 times, with backoff)."),
]

func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
    ["name": name, "description": description,
     "inputSchema": ["type": "object", "properties": properties, "required": required]]
}

let nameProp = prop("string", "Service name.")
let targetProp = prop("string", "Service name, or \"@group\" for every service in a group.")

let tools: [[String: Any]] = [
    tool("list_services", "List every service SkyEye knows about, with live status: running, starting, unhealthy, crashed, stopped, stopping, external (port held by a process SkyEye didn't start) or pending-approval."),
    tool("get_service", "Get one service's configuration and live status.", ["name": nameProp], required: ["name"]),
    tool("add_service", "Register a new local service. It can't start until the user approves its command in the SkyEye menu bar.",
         serviceFields.merging(["name": prop("string", "Unique name: letters, digits, '-', '_' or '.'.")]) { $1 }, required: ["name"]),
    tool("update_service", "Change a service. Only the fields you pass change; pass null to clear port, command, health_path or group. Changing the command, directory or env requires the user's approval again.",
         serviceFields.merging(["name": nameProp, "new_name": prop("string", "Rename the service.")]) { $1 }, required: ["name"]),
    tool("remove_service", "Stop (if running) and remove a service.", ["name": nameProp], required: ["name"]),
    tool("start_service", "Start a service and wait until it is up (port open and health check passing). Returns its status, plus the last log lines if it failed.",
         ["name": targetProp, "wait_seconds": prop("integer", "How long to wait for it to come up (default 60, 0 to not wait).")], required: ["name"]),
    tool("stop_service", "Stop a service and everything it spawned.", ["name": targetProp], required: ["name"]),
    tool("restart_service", "Restart a service and wait until it is up again.",
         ["name": targetProp, "wait_seconds": prop("integer", "How long to wait (default 60, 0 to not wait).")], required: ["name"]),
    tool("get_logs", "Read the latest output (stdout and stderr) of a service.",
         ["name": nameProp, "lines": prop("integer", "Number of lines from the end (default 100, max 2000).")], required: ["name"]),
    tool("check_port", "See which process is listening on a TCP port.", ["port": prop("integer", "Port number.")], required: ["port"]),
]

// MARK: Tool implementations

func summary(_ s: ServiceSnapshot) -> [String: Any] {
    let c = s.service
    var d: [String: Any] = [
        "name": c.name, "state": s.state.rawValue, "approved": s.approved,
        "dependencies": c.dependencies,
        "auto_restart": c.autoRestart, "log_file": s.logFile,
    ]
    if let v = s.detail { d["detail"] = v }
    if let v = c.port { d["port"] = v }
    if let v = c.url { d["url"] = v }
    if let v = s.pid { d["pid"] = Int(v) }
    if let v = s.cpuPercent { d["cpu_percent"] = (v * 10).rounded() / 10 }
    if let v = s.memoryBytes { d["memory_mb"] = Int(v / 1_048_576) }
    if let v = c.command { d["command"] = v }
    if let v = c.directory { d["directory"] = v }
    if let v = c.healthPath { d["health_path"] = v }
    if let v = c.group { d["group"] = v }
    if !c.env.isEmpty { d["env"] = c.env }
    if let v = s.lastExit { d["last_exit"] = v }
    return d
}

struct ToolError: Error { let message: String }

func send(_ request: ControlRequest) throws -> ControlResponse {
    let response: ControlResponse
    do { response = try client.send(request) } catch { throw ToolError(message: error.localizedDescription) }
    guard response.ok else { throw ToolError(message: response.error ?? "Request failed.") }
    return response
}

func string(_ args: [String: Any], _ key: String) throws -> String {
    guard let v = args[key] as? String, !v.isEmpty else { throw ToolError(message: "Missing '\(key)'.") }
    return v
}

func int(_ value: Any?) -> Int? {
    if let n = value as? NSNumber { return n.intValue }
    if let s = value as? String { return Int(s) }
    return nil
}

/// Applies the optional service fields in `args` onto `s`. NSNull clears a field.
func apply(_ args: [String: Any], to s: inout ServiceConfig) throws {
    func optionalString(_ key: String, _ set: (String?) -> Void) {
        guard let v = args[key] else { return }
        set(v is NSNull ? nil : v as? String)
    }
    optionalString("command") { s.command = $0 }
    optionalString("health_path") { s.healthPath = $0 }
    optionalString("group") { s.group = $0 }
    if let v = args["port"] {
        if v is NSNull { s.port = nil } else if let p = int(v) { s.port = p } else { throw ToolError(message: "'port' must be an integer.") }
    }
    if let dir = args["directory"] as? String {
        s.directory = (dir as NSString).expandingTildeInPath
    }
    if let env = args["env"] as? [String: Any] {
        for (k, v) in env {
            if v is NSNull { s.env[k] = nil } else { s.env[k] = v as? String ?? "\(v)" }
        }
    }
    if let value = args["dependencies"] {
        guard let names = value as? [String] else { throw ToolError(message: "dependencies must be an array of service names.") }
        s.dependencies = names
    }
    if let v = args["auto_restart"] as? Bool { s.autoRestart = v }
}

func startOrRestart(_ action: ControlRequest.Action, _ args: [String: Any]) throws -> [String: Any] {
    let target = try string(args, "name")
    let response = try send(ControlRequest(action: action, name: target))
    let wait = Double(int(args["wait_seconds"]) ?? 60)
    guard wait > 0 else { return text(response.message ?? "OK") }

    let names: [String]
    do { names = try client.resolve(target) } catch { throw ToolError(message: error.localizedDescription) }
    var results: [[String: Any]] = []
    var failed = false
    for name in names {
        let s: ServiceSnapshot
        do { s = try client.waitUntilSettled(name, timeout: wait) } catch { throw ToolError(message: error.localizedDescription) }
        var d = summary(s)
        if s.state != .running && s.state != .starting {
            failed = true
            let log = (try? send(ControlRequest(action: .logs, name: name, lines: 30)))?.log ?? ""
            d["recent_logs"] = LogTail.stripANSI(log)
        } else if s.state == .starting {
            d["note"] = "Still starting after \(Int(wait))s; check again with get_service or get_logs."
        }
        results.append(d)
    }
    let payload: Any
    if names.count == 1 { payload = results[0] } else { payload = ["services": results] as [String: Any] }
    return text(json(payload), isError: failed)
}

func callTool(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
    switch name {
    case "list_services":
        let services = try send(ControlRequest(action: .list)).services ?? []
        return text(services.isEmpty ? "No services yet." : json(services.map(summary)))

    case "get_service":
        guard let s = try send(ControlRequest(action: .get, name: try string(args, "name"))).service else {
            throw ToolError(message: "No such service.")
        }
        return text(json(summary(s)))

    case "add_service":
        var s = ServiceConfig(name: try string(args, "name"), directory: launchDirectory)
        try apply(args, to: &s)
        let response = try send(ControlRequest(action: .add, service: s))
        var d = response.service.map(summary) ?? [:]
        d["message"] = response.message
        return text(json(d))

    case "update_service":
        let name = try string(args, "name")
        guard var s = try send(ControlRequest(action: .get, name: name)).service?.service else {
            throw ToolError(message: "No such service.")
        }
        try apply(args, to: &s)
        if let newName = args["new_name"] as? String, !newName.isEmpty { s.name = newName }
        let response = try send(ControlRequest(action: .update, name: name, service: s))
        var d = response.service.map(summary) ?? [:]
        d["message"] = response.message
        return text(json(d))

    case "remove_service":
        return text(try send(ControlRequest(action: .remove, name: try string(args, "name"))).message ?? "Removed.")

    case "start_service":
        return try startOrRestart(.start, args)

    case "restart_service":
        return try startOrRestart(.restart, args)

    case "stop_service":
        let target = try string(args, "name")
        let response = try send(ControlRequest(action: .stop, name: target))
        var results: [[String: Any]] = []
        for n in (try? client.resolve(target)) ?? [] {
            if let s = try? client.waitUntilSettled(n, timeout: 15) { results.append(summary(s)) }
        }
        if results.isEmpty { return text(response.message ?? "Stopped.") }
        let payload: Any
        if results.count == 1 { payload = results[0] } else { payload = ["services": results] as [String: Any] }
        return text(json(payload))

    case "get_logs":
        let lines = min(max(int(args["lines"]) ?? 100, 1), 2000)
        let log = try send(ControlRequest(action: .logs, name: try string(args, "name"), lines: lines)).log ?? ""
        return text(log.isEmpty ? "(no output yet)" : LogTail.stripANSI(log))

    case "check_port":
        guard let port = int(args["port"]) else { throw ToolError(message: "Missing 'port'.") }
        let response = try send(ControlRequest(action: .port, port: port))
        let listeners = (response.listeners ?? []).map { ["pid": Int($0.pid), "command": $0.command] as [String: Any] }
        var d: [String: Any] = ["port": port, "listeners": listeners, "in_use": !listeners.isEmpty]
        if let m = response.message { d["note"] = m }
        return text(json(d))

    default:
        throw ToolError(message: "Unknown tool '\(name)'.")
    }
}

// MARK: Main loop

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { continue }
    let method = message["method"] as? String ?? ""
    let params = message["params"] as? [String: Any] ?? [:]
    guard let id = message["id"] else { continue }  // notifications need no reply

    switch method {
    case "initialize":
        reply(id, result: [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "skyeye", "version": "0.1.0"],
            "instructions": instructions,
        ])
    case "ping":
        reply(id, result: [:])
    case "tools/list":
        reply(id, result: ["tools": tools])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            reply(id, result: try callTool(name, args))
        } catch let error as ToolError {
            reply(id, result: text(error.message, isError: true))
        } catch {
            reply(id, result: text(error.localizedDescription, isError: true))
        }
    default:
        replyError(id, code: -32601, message: "Method not found: \(method)")
    }
}
