import Combine
import Darwin
import Foundation

public enum ServiceEvent: Sendable {
    case crashed(name: String, detail: String)
    case unhealthy(name: String, detail: String)
    case approvalNeeded(name: String, command: String)
}

/// Owns the config, the running processes and their live status.
/// Everything here runs on the main actor; probes run in the background.
@MainActor
public final class ServiceManager: ObservableObject {
    public let paths: SkyEyePaths
    @Published public private(set) var config: SkyEyeConfig
    @Published public private(set) var snapshots: [ServiceSnapshot] = []
    @Published public private(set) var loadError: String?
    @Published public private(set) var systemUsage: SystemUsage?
    @Published public private(set) var skyEyeUsage: ResourceUsage?
    @Published public private(set) var servicesUsage: ResourceUsage?
    @Published public private(set) var logCleanupError: String?
    @Published public private(set) var autoStartError: String?
    private var lastLogCleanup: Date?
    public var onEvent: ((ServiceEvent) -> Void)?

    /// How long a freshly started service may take before it counts as unhealthy.
    public var startupGrace: TimeInterval = 90
    public static let maxAutoRestarts = 5

    private final class Runtime {
        var process: ManagedProcess?
        var startedAt: Date?
        var stopRequested = false
        var restartRequested = false
        var everReady = false
        var readyAt: Date?
        var lastReady = false
        var portOpen = false
        var healthy: Bool?
        var owner: PortListener?
        var crashed = false
        var lastExit: ExitStatus?
        var lastError: String?
        var autoRestarts = 0
        var pendingRestart: DispatchWorkItem?
        var restartAt: Date?
        var usage: GroupUsage?
        var usageAt: Date?
        var cpuPercent: Double?

        func resetUsage() {
            usage = nil
            usageAt = nil
            cpuPercent = nil
        }
    }

    private final class StartupPlan {
        let order: [String]
        let automatic: Bool
        var attempted = Set<String>()
        var waiting: String
        var since = Date()
        init(order: [String], automatic: Bool) {
            self.order = order; self.automatic = automatic; self.waiting = order[0]
        }
    }
    private var startupPlans: [String: StartupPlan] = [:]
    private var advancingPlans = false
    private var runtimes: [String: Runtime] = [:]
    private var timer: Timer?
    private var probing = false
    private var systemSampler = SystemSampler()
    private var skyEyeSampler = ResourceSampler()
    private var servicesSampler = ResourceSampler()
    private var systemSampledAt: Date?

    public init(paths: SkyEyePaths = .standard) {
        self.paths = paths
        try? paths.ensureDirectories()
        let (config, error) = Self.load(from: paths.configFile)
        self.config = config
        self.loadError = error
        refresh()
    }

    // MARK: Config

    private static func load(from url: URL) -> (SkyEyeConfig, String?) {
        guard let data = try? Data(contentsOf: url) else { return (SkyEyeConfig(), nil) }
        do {
            let config = try JSONCoding.decoder.decode(SkyEyeConfig.self, from: data)
            _ = try ServiceGraph.order(config.services)
            return (config, nil)
        } catch {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("config.invalid-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            return (SkyEyeConfig(), "config.json couldn't be read, so SkyEye started empty. The old file was saved as \(backup.lastPathComponent).")
        }
    }

    private func save() throws {
        let encoder = JSONCoding.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: paths.configFile, options: .atomic)
        chmod(paths.configFile.path, 0o600)
    }

    public func service(named name: String) -> ServiceConfig? {
        config.services.first { $0.name == name }
    }

    private func index(of name: String) throws -> Int {
        guard let i = config.services.firstIndex(where: { $0.name == name }) else {
            throw SkyEyeError("No service named '\(name)'.")
        }
        return i
    }

    private func runtime(_ name: String) -> Runtime {
        if let rt = runtimes[name] { return rt }
        let rt = Runtime()
        runtimes[name] = rt
        return rt
    }

    private func validate(_ s: ServiceConfig, replacing old: String?) throws {
        guard ServiceConfig.isValidName(s.name) else {
            throw SkyEyeError("'\(s.name)' isn't a valid name. Use letters, digits, '-', '_' or '.'.")
        }
        if s.name != old, service(named: s.name) != nil {
            throw SkyEyeError("A service named '\(s.name)' already exists.")
        }
        if let port = s.port, !(1...65535).contains(port) {
            throw SkyEyeError("Port \(port) is out of range.")
        }
        if s.command == nil && s.port == nil {
            throw SkyEyeError("A service needs a start command, a port, or both.")
        }
        if let dir = s.directory {
            var isDir: ObjCBool = false
            guard dir.hasPrefix("/") else { throw SkyEyeError("Directory must be an absolute path: \(dir)") }
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                throw SkyEyeError("Directory doesn't exist: \(dir)")
            }
        }
        if let health = s.healthPath, s.port == nil, !health.hasPrefix("http") {
            throw SkyEyeError("A health check path needs a port (or use a full http:// URL).")
        }
        for key in s.env.keys where key.isEmpty || key.contains("=") {
            throw SkyEyeError("Invalid environment variable name '\(key)'.")
        }
    }

    /// Adds a service. `trusted` is true when the user did it in the menu bar;
    /// otherwise the command waits for approval (if approval is required).
    @discardableResult
    public func addService(_ service: ServiceConfig, trusted: Bool) throws -> ServiceConfig {
        var s = service.normalized()
        try validate(s, replacing: nil)
        _ = try ServiceGraph.order(config.services + [s])
        s.approvedFingerprint = trusted || !config.settings.requireApproval ? s.fingerprint : nil
        config.services.append(s)
        try save()
        refresh()
        if !s.isApproved, let command = s.command {
            onEvent?(.approvalNeeded(name: s.name, command: command))
        }
        return s
    }

    @discardableResult
    public func updateService(named old: String, to service: ServiceConfig, trusted: Bool) throws -> ServiceConfig {
        let i = try index(of: old)
        let current = config.services[i]
        var s = service.normalized()
        try validate(s, replacing: old)
        if s.name != old, runtimes[old]?.process != nil {
            throw SkyEyeError("Stop '\(old)' before renaming it.")
        }
        guard !startupPlans.values.contains(where: { $0.order.contains(old) }) else {
            throw SkyEyeError("Wait for startup to finish or stop '\(old)' before editing it.")
        }
        var updated = config.services
        updated[i] = s
        if s.name != old {
            for j in updated.indices {
                updated[j].dependencies = updated[j].dependencies.map { $0 == old ? s.name : $0 }
            }
        }
        _ = try ServiceGraph.order(updated)
        let keepsApproval = s.fingerprint == current.approvedFingerprint
        s.approvedFingerprint = trusted || !config.settings.requireApproval || keepsApproval ? s.fingerprint : nil
        updated[i].approvedFingerprint = s.approvedFingerprint
        config.services = updated
        if s.name != old {
            config.settings.autoStartServices = config.settings.autoStartServices.map { $0 == old ? s.name : $0 }
        }
        if s.name != old, let rt = runtimes.removeValue(forKey: old) {
            runtimes[s.name] = rt
        }
        try save()
        refresh()
        if !s.isApproved, current.isApproved || current.fingerprint != s.fingerprint, let command = s.command {
            onEvent?(.approvalNeeded(name: s.name, command: command))
        }
        return s
    }

    public func removeService(named name: String) throws {
        let i = try index(of: name)
        let dependents = config.services.filter { $0.dependencies.contains(name) }.map(\.name)
        guard dependents.isEmpty else {
            throw SkyEyeError("Remove dependency links from " + dependents.joined(separator: ", ") + " before removing '\(name)'.")
        }
        cancelStartupPlans(involving: name)
        if let rt = runtimes[name] {
            rt.pendingRestart?.cancel()
            rt.stopRequested = true
            rt.restartRequested = false
            rt.process?.terminate()
        }
        runtimes[name] = nil
        config.services.remove(at: i)
        config.settings.autoStartServices.removeAll { $0 == name }
        try save()
        refresh()
    }

    /// Only called from the menu bar UI.
    public func approve(named name: String) throws {
        let i = try index(of: name)
        config.services[i].approvedFingerprint = config.services[i].fingerprint
        try save()
        refresh()
    }

    public func updateSettings(_ settings: Settings) throws {
        guard [0, 1, 7, 30].contains(settings.logRetentionDays) else {
            throw SkyEyeError("Log retention must be 1, 7, 30 days, or 0 to keep forever.")
        }
        config.settings = settings
        try save()
        maintainLogs(force: true)
        refresh()
    }

    public func maintainLogs(now: Date = Date(), force: Bool = false) {
        guard force || lastLogCleanup.map({ now.timeIntervalSince($0) >= 3600 }) ?? true else { return }
        lastLogCleanup = now
        let protected = Set(runtimes.compactMap { $0.value.process != nil ? $0.key : nil })
        do {
            try ServiceLogs.cleanup(in: paths.logsDir, retentionDays: config.settings.logRetentionDays,
                                    protectedNames: protected, now: now)
            logCleanupError = nil
        } catch { logCleanupError = "Could not clean up old logs: " + error.localizedDescription }
    }

    private var bundledLogWriter: URL? {
        let writer = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/skyeye-logwriter")
        return FileManager.default.isExecutableFile(atPath: writer.path) ? writer : nil
    }

    // MARK: Start / stop

    /// Called once at app launch, after detached services have been adopted.
    public func startConfiguredServices() {
        let selected = Set(config.settings.autoStartServices)
        let targets = config.services.filter {
            $0.command != nil && (config.settings.autoStartMode == .all
                || (config.settings.autoStartMode == .selected && selected.contains($0.name)))
        }
        var failures: [String] = []
        for service in targets {
            do {
                // Fresh probes allow already-running prerequisites and external services to be reused.
                _ = try scheduleStart(named: service.name, automatic: false, queued: true)
            } catch { failures.append(service.name + ": " + error.localizedDescription) }
        }
        autoStartError = failures.isEmpty ? nil : "Could not auto-start services:\n" + failures.joined(separator: "\n")
    }

    public func dismissAutoStartError() { autoStartError = nil }

    private var shellInvocation: (String, [String]) {
        let settings = config.settings
        var shell = settings.shell
        if shell == nil, let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            shell = String(cString: sh)
        }
        let path = shell?.isEmpty == false ? shell! : "/bin/zsh"
        return (path, settings.loadShellProfile ? ["-i", "-l", "-c"] : ["-c"])
    }

    @discardableResult
    public func start(named name: String) throws -> String {
        try scheduleStart(named: name, automatic: false)
    }

    @discardableResult
    private func scheduleStart(named name: String, automatic: Bool, queued: Bool = false) throws -> String {
        let order = try ServiceGraph.order(config.services, roots: [name])
        if startupPlans[name] != nil { return "'\(name)' is already starting." }
        if runtimes[name]?.process != nil { return "'\(name)' is already running." }
        guard order.count > 1 || queued else { return try start(named: name, automatic: automatic) }
        for target in order {
            let service = config.services[try index(of: target)]
            guard service.isApproved else { throw SkyEyeError("'\(target)' needs command approval before '\(name)' can start.") }
        }
        let rt = runtime(name)
        rt.crashed = false
        rt.lastError = nil
        if !automatic { rt.autoRestarts = 0 }
        startupPlans[name] = StartupPlan(order: order, automatic: automatic)
        refresh()
        tick()
        return "Starting '\(name)' after its dependencies: " + order.dropLast().joined(separator: ", ") + "."
    }

    /// Nonblocking orchestration: probes and process exits advance all pending requests.
    private func advanceStartupPlans() {
        guard !advancingPlans else { return }
        advancingPlans = true
        defer { advancingPlans = false }
        for root in Array(startupPlans.keys).sorted() {
            guard let plan = startupPlans[root] else { continue }
            do {
                var complete = true
                for name in plan.order {
                    guard let service = service(named: name) else { throw SkyEyeError("Dependency '\(name)' was removed.") }
                    let rt = runtime(name)
                    let (status, detail) = processState(of: service, rt)
                    if status == .running || status == .external { continue }
                    if plan.waiting != name { plan.waiting = name; plan.since = Date() }
                    if Date().timeIntervalSince(plan.since) > startupGrace {
                        throw SkyEyeError("'\(name)' did not become ready within \(Int(startupGrace)) seconds.")
                    }
                    if status == .starting {
                        plan.attempted.insert(name)
                        complete = false
                        break
                    }
                    if status == .unhealthy || status == .stopping || status == .pendingApproval || plan.attempted.contains(name) {
                        throw SkyEyeError("'\(name)' is \(status.label)" + (detail.map { ": " + $0 } ?? ""))
                    }
                    guard service.command != nil else { throw SkyEyeError("Monitor-only dependency '\(name)' is not ready. Start it externally first.") }
                    plan.attempted.insert(name)
                    _ = try start(named: name, automatic: name == root ? plan.automatic : false)
                    // Portless workers become ready once spawned; port services wait for the next probe.
                    if service.port == nil { continue }
                    complete = false
                    break
                }
                if complete { startupPlans[root] = nil }
            } catch {
                startupPlans[root] = nil
                let rt = runtime(root)
                rt.crashed = rt.process == nil
                rt.lastError = "Startup blocked: " + error.localizedDescription
                onEvent?(.crashed(name: root, detail: rt.lastError!))
            }
        }
    }

    private func cancelStartupPlans(involving name: String) {
        for root in Array(startupPlans.keys) where startupPlans[root]!.order.contains(name) {
            startupPlans[root] = nil
            runtime(root).lastError = "Startup cancelled because '\(name)' was stopped."
        }
    }

    @discardableResult
    private func start(named name: String, automatic: Bool) throws -> String {
        let s = config.services[try index(of: name)]
        guard let command = s.command else {
            throw SkyEyeError("'\(name)' has no start command; SkyEye only monitors it.")
        }
        guard s.isApproved else {
            throw SkyEyeError("'\(name)' is waiting for approval. Ask the user to approve its command in the SkyEye menu bar.")
        }
        let rt = runtime(name)
        if rt.process != nil { return "'\(name)' is already running." }
        rt.pendingRestart?.cancel()
        rt.pendingRestart = nil
        rt.restartAt = nil
        if !automatic { rt.autoRestarts = 0 }

        if let port = s.port, PortProbe.isListening(port) {
            let owners = PortProbe.listeners(on: port)
            let who = owners.isEmpty ? "another process" : owners.map(\.description).joined(separator: ", ")
            throw SkyEyeError("Port \(port) is already in use by \(who). Free it with `sky port \(port) --kill`.")
        }
        if let dir = s.directory, !FileManager.default.fileExists(atPath: dir) {
            throw SkyEyeError("Directory doesn't exist: \(dir)")
        }

        let log = paths.logFile(for: name)
        LogTail.append("\n=== SkyEye: starting '\(name)' at \(Date().formatted(date: .abbreviated, time: .standard)) ===\n$ \(command)\n", to: log)

        var environment = ProcessInfo.processInfo.environment
        environment.merge(s.env) { $1 }
        let (shell, args) = shellInvocation
        let process = try ManagedProcess.spawn(
            executable: shell, arguments: args + [command], directory: s.directory,
            environment: environment, logFile: log, logWriter: bundledLogWriter
        ) { [weak self] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.processExited(name: name, status: status) }
            }
        }
        rt.process = process
        rt.startedAt = Date()
        rt.stopRequested = false
        rt.restartRequested = false
        rt.everReady = false
        rt.lastReady = false
        rt.readyAt = nil
        rt.crashed = false
        rt.lastError = nil
        rt.portOpen = false
        rt.healthy = nil
        rt.resetUsage()
        refresh()
        tick()
        return "Started '\(name)' (pid \(process.pid))."
    }

    private func processExited(name: String, status: ExitStatus) {
        guard let rt = runtimes[name], rt.process != nil, rt.process?.isRunning == false else { return }
        rt.process = nil
        rt.startedAt = nil
        rt.resetUsage()
        rt.everReady = false
        rt.lastReady = false
        rt.lastExit = status
        let expected = rt.stopRequested
        rt.stopRequested = false
        LogTail.append("=== SkyEye: '\(name)' exited (\(status)) ===\n", to: paths.logFile(for: name))

        if rt.restartRequested {
            rt.restartRequested = false
            rt.crashed = false
            do { try start(named: name) } catch { rt.lastError = error.localizedDescription }
        } else if !expected && !status.isSuccess {
            rt.crashed = true
            var detail = status.description
            if let s = service(named: name), s.autoRestart, rt.autoRestarts < Self.maxAutoRestarts {
                let delay = min(30, pow(2, Double(rt.autoRestarts)))
                rt.autoRestarts += 1
                rt.restartAt = Date().addingTimeInterval(delay)
                // Capture the runtime, not the name: renaming the service moves the runtime
                // to a new key while this restart is still pending.
                let runtime = rt
                let item = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, runtime.pendingRestart != nil,
                              let currentName = self.runtimes.first(where: { $0.value === runtime })?.key else { return }
                        runtime.pendingRestart = nil
                        runtime.restartAt = nil
                        do { try self.scheduleStart(named: currentName, automatic: true) } catch {
                            runtime.lastError = error.localizedDescription
                            self.refresh()
                        }
                    }
                }
                rt.pendingRestart = item
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                detail += "; restarting in \(Int(delay))s"
            }
            onEvent?(.crashed(name: name, detail: detail))
        } else {
            rt.crashed = false
        }
        refresh()
    }

    @discardableResult
    public func stop(named name: String) throws -> String {
        cancelStartupPlans(involving: name)
        let s = config.services[try index(of: name)]
        let rt = runtime(name)
        if let item = rt.pendingRestart {
            item.cancel()
            rt.pendingRestart = nil
            rt.restartAt = nil
            rt.crashed = false
            refresh()
            return "Cancelled the pending restart of '\(name)'."
        }
        guard let process = rt.process else {
            if let port = s.port, rt.portOpen, s.command != nil {
                let who = rt.owner?.description ?? "another process"
                throw SkyEyeError("'\(name)' wasn't started by SkyEye; port \(port) is held by \(who). Use `sky port \(port) --kill` to stop it.")
            }
            rt.crashed = false
            refresh()
            return "'\(name)' isn't running."
        }
        rt.stopRequested = true
        rt.restartRequested = false
        process.terminate()
        refresh()
        return "Stopping '\(name)'."
    }

    @discardableResult
    public func restart(named name: String) throws -> String {
        _ = try index(of: name)
        let rt = runtime(name)
        guard let process = rt.process else { return try start(named: name) }
        rt.stopRequested = true
        rt.restartRequested = true
        process.terminate()
        refresh()
        return "Restarting '\(name)'."
    }

    /// Stops everything SkyEye started, waiting up to `timeout` before SIGKILL. Used on quit.
    public func stopAll(timeout: TimeInterval = 3) {
        startupPlans.removeAll()
        let order = (try? ServiceGraph.order(config.services)) ?? config.services.map(\.name)
        let processes = order.reversed().compactMap { runtimes[$0]?.process }
        for rt in runtimes.values {
            rt.pendingRestart?.cancel()
            rt.pendingRestart = nil
            rt.stopRequested = true
            rt.restartRequested = false
        }
        processes.forEach { $0.signal(SIGTERM) }
        let deadline = Date().addingTimeInterval(timeout)
        while processes.contains(where: \.isRunning) && Date() < deadline { usleep(50_000) }
        processes.forEach { $0.signal(SIGKILL) }
    }

    /// Leaves everything SkyEye started running and records it so `adoptDetached()` can take it back over on the
    /// next launch. Used on quit when `keepRunningOnQuit` is on.
    public func detachAll() {
        startupPlans.removeAll()
        var detached: [DetachedService] = []
        for (name, rt) in runtimes {
            rt.pendingRestart?.cancel()
            rt.pendingRestart = nil
            guard let process = rt.process, process.isRunning, !rt.stopRequested,
                  let processStart = ManagedProcess.startTime(of: process.pid) else { continue }
            detached.append(DetachedService(
                name: name, pid: process.pid, processStart: processStart,
                startedAt: rt.startedAt ?? Date(), everReady: rt.everReady
            ))
            LogTail.append("=== SkyEye: quit and left '\(name)' running (pid \(process.pid)) ===\n", to: paths.logFile(for: name))
        }
        guard !detached.isEmpty else { return }
        try? JSONCoding.encoder.encode(detached).write(to: paths.detachedFile, options: .atomic)
    }

    /// Takes back over the services a previous SkyEye left running when it quit.
    public func adoptDetached() {
        let file = paths.detachedFile
        guard let data = try? Data(contentsOf: file) else { return }
        try? FileManager.default.removeItem(at: file)
        guard let detached = try? JSONCoding.decoder.decode([DetachedService].self, from: data) else { return }
        for d in detached {
            guard service(named: d.name)?.command != nil, runtimes[d.name]?.process == nil,
                  ManagedProcess.startTime(of: d.pid) == d.processStart,
                  let process = ManagedProcess.adopt(pid: d.pid, onExit: { [weak self] status in
                      DispatchQueue.main.async {
                          MainActor.assumeIsolated { self?.processExited(name: d.name, status: status) }
                      }
                  })
            else { continue }
            let rt = runtime(d.name)
            rt.process = process
            rt.startedAt = d.startedAt
            rt.everReady = d.everReady
            rt.lastReady = d.everReady
            rt.readyAt = d.everReady ? Date() : nil
            rt.resetUsage()
            LogTail.append("=== SkyEye: took back over '\(d.name)' (pid \(d.pid)) ===\n", to: paths.logFile(for: d.name))
        }
        refresh()
        tick()
    }

    public var activeCount: Int { runtimes.values.filter { $0.process != nil }.count }

    // MARK: Monitoring

    public func startMonitoring(interval: TimeInterval = 2) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Probes every service with a port in the background, then updates status.
    public func tick() {
        maintainLogs()
        sampleUsage()
        guard !probing else { return }
        let targets = config.services.compactMap { s -> ProbeTarget? in
            guard let port = s.port else { return nil }
            let managed = runtimes[s.name]?.process != nil
            return ProbeTarget(name: s.name, port: port, healthPath: s.healthPath, wantOwner: !managed)
        }
        guard !targets.isEmpty else {
            advanceStartupPlans()
            refresh()
            return
        }
        probing = true
        DispatchQueue.global(qos: .utility).async {
            let results = PortProbe.probe(targets)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in self?.apply(results) }
            }
        }
    }

    /// Updates CPU and memory for running services. CPU is averaged since the previous sample, at least a second ago.
    private func sampleUsage() {
        let now = Date()
        if systemSampledAt.map({ now.timeIntervalSince($0) >= 1 }) ?? true {
            systemSampledAt = now
            let usage = systemSampler.sample()
            if usage != systemUsage { systemUsage = usage }
            skyEyeUsage = skyEyeSampler.sample(pids: [getpid()], now: now)
            var servicePIDs = Set<pid_t>()
            for rt in runtimes.values {
                if let process = rt.process {
                    servicePIDs.formUnion(GroupUsage.processIDs(pgid: process.pid))
                } else if rt.portOpen, let owner = rt.owner {
                    servicePIDs.formUnion(GroupUsage.processTree(root: owner.pid))
                }
            }
            servicePIDs.remove(getpid())
            servicesUsage = servicesSampler.sample(pids: servicePIDs, now: now)
        }
        for rt in runtimes.values {
            guard let process = rt.process else { continue }
            if let at = rt.usageAt, now.timeIntervalSince(at) < 1 { continue }
            guard let usage = GroupUsage.sample(pgid: process.pid) else { continue }
            if let previous = rt.usage, let at = rt.usageAt {
                // Children that exited since the last sample take their CPU time with them; don't go negative.
                let used = usage.cpuTime > previous.cpuTime ? Double(usage.cpuTime - previous.cpuTime) : 0
                rt.cpuPercent = used / (now.timeIntervalSince(at) * 1e9) * 100
            }
            rt.usage = usage
            rt.usageAt = now
        }
    }

    private func apply(_ results: [String: ProbeResult]) {
        probing = false
        for (name, result) in results {
            guard let s = service(named: name) else { continue }
            let rt = runtime(name)
            rt.portOpen = result.portOpen
            rt.healthy = result.healthy
            rt.owner = result.owner
            guard rt.process != nil, !rt.stopRequested else { continue }

            let ready = result.portOpen && (s.healthPath == nil || result.healthy == true)
            if ready {
                if !rt.everReady {
                    rt.everReady = true
                    rt.readyAt = Date()
                }
                if let at = rt.readyAt, Date().timeIntervalSince(at) > 60 { rt.autoRestarts = 0 }
            } else if rt.lastReady {
                let detail = result.portOpen ? "health check \(s.healthPath ?? "") failing" : "port \(s.port ?? 0) stopped accepting connections"
                onEvent?(.unhealthy(name: name, detail: detail))
            }
            rt.lastReady = ready
        }
        advanceStartupPlans()
        refresh()
    }

    // MARK: Snapshots

    private func state(of s: ServiceConfig, _ rt: Runtime?) -> (ServiceState, String?) {
        if let plan = startupPlans[s.name], rt?.process == nil {
            return (.starting, "waiting for " + plan.waiting)
        }
        return processState(of: s, rt)
    }

    private func processState(of s: ServiceConfig, _ rt: Runtime?) -> (ServiceState, String?) {
        if let rt, rt.process != nil {
            if rt.stopRequested { return (.stopping, rt.restartRequested ? "restarting" : nil) }
            guard let port = s.port else { return (.running, nil) }
            if rt.portOpen && (s.healthPath == nil || rt.healthy == true) { return (.running, nil) }
            let detail = rt.portOpen ? "health check \(s.healthPath ?? "") not passing" : "waiting for port \(port)"
            let elapsed = Date().timeIntervalSince(rt.startedAt ?? Date())
            if !rt.everReady && elapsed < startupGrace { return (.starting, detail) }
            return (.unhealthy, detail)
        }
        if s.command != nil && !s.isApproved { return (.pendingApproval, "command needs approval in the menu bar") }
        if let rt, rt.pendingRestart != nil, let at = rt.restartAt {
            let secs = max(0, Int(at.timeIntervalSinceNow.rounded(.up)))
            return (.crashed, "\(rt.lastExit?.description ?? "crashed"); restarting in \(secs)s (attempt \(rt.autoRestarts)/\(Self.maxAutoRestarts))")
        }
        if s.port != nil, rt?.portOpen == true {
            if s.healthPath != nil, rt?.healthy != true { return (.unhealthy, "health check not passing") }
            if s.command == nil { return (.running, "monitor only") }
            return (.external, "port in use by \(rt?.owner?.description ?? "another process")")
        }
        if let rt, rt.crashed { return (.crashed, rt.lastError ?? rt.lastExit?.description) }
        if s.command == nil { return (.stopped, "monitor only") }
        return (.stopped, runtimes[s.name]?.lastError)
    }

    private func makeSnapshot(_ s: ServiceConfig) -> ServiceSnapshot {
        let rt = runtimes[s.name]
        let (state, detail) = self.state(of: s, rt)
        return ServiceSnapshot(
            service: s, state: state, detail: detail, pid: rt?.process?.pid, startedAt: rt?.startedAt,
            lastExit: rt?.lastExit?.description, autoRestarts: rt?.autoRestarts ?? 0,
            approved: s.isApproved, logFile: paths.logFile(for: s.name).path,
            cpuPercent: rt?.process != nil ? rt?.cpuPercent : nil,
            memoryBytes: rt?.process != nil ? rt?.usage?.memory : nil
        )
    }

    public func refresh() {
        let fresh = config.services.map(makeSnapshot)
        if fresh != snapshots { snapshots = fresh }
    }

    public func snapshot(named name: String) throws -> ServiceSnapshot {
        makeSnapshot(config.services[try index(of: name)])
    }

    // MARK: Control API

    private func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw SkyEyeError("Missing \(what).") }
        return value
    }

    private func targets(_ name: String) throws -> [String] {
        guard name.hasPrefix("@") else {
            _ = try index(of: name)
            return [name]
        }
        let group = String(name.dropFirst())
        let names = config.services.filter { $0.group == group }.map(\.name)
        guard !names.isEmpty else { throw SkyEyeError("No services in group '\(group)'.") }
        return names
    }

    /// Handles a request from the CLI or MCP server. These are never trusted,
    /// so new or changed commands need approval in the menu bar.
    public func handle(_ request: ControlRequest) -> ControlResponse {
        do {
            switch request.action {
            case .ping:
                return ControlResponse(ok: true, message: "pong")
            case .list:
                return ControlResponse(ok: true, services: snapshots)
            case .get:
                return ControlResponse(ok: true, service: try snapshot(named: try require(request.name, "service name")))
            case .add:
                let s = try addService(try require(request.service, "service"), trusted: false)
                let message = s.isApproved
                    ? "Added '\(s.name)'."
                    : "Added '\(s.name)'. The user must approve its command in the SkyEye menu bar before it can start."
                return ControlResponse(ok: true, message: message, service: try snapshot(named: s.name))
            case .update:
                let old = try require(request.name, "service name")
                let s = try updateService(named: old, to: try require(request.service, "service"), trusted: false)
                let message = s.isApproved
                    ? "Updated '\(s.name)'."
                    : "Updated '\(s.name)'. The changed command must be approved in the SkyEye menu bar before it can start."
                return ControlResponse(ok: true, message: message, service: try snapshot(named: s.name))
            case .remove:
                let name = try require(request.name, "service name")
                try removeService(named: name)
                return ControlResponse(ok: true, message: "Removed '\(name)'.")
            case .start, .stop, .restart:
                var names = try targets(try require(request.name, "service name"))
                if request.action == .stop {
                    let selected = Set(names)
                    names = try ServiceGraph.order(config.services).reversed().filter { selected.contains($0) }
                }
                var messages: [String] = []
                var failures: [String] = []
                for name in names {
                    do {
                        switch request.action {
                        case .start: messages.append(try start(named: name))
                        case .stop: messages.append(try stop(named: name))
                        default: messages.append(try restart(named: name))
                        }
                    } catch {
                        failures.append(names.count == 1 ? error.localizedDescription : "\(name): \(error.localizedDescription)")
                    }
                }
                return ControlResponse(
                    ok: failures.isEmpty,
                    message: messages.isEmpty ? nil : messages.joined(separator: "\n"),
                    error: failures.isEmpty ? nil : failures.joined(separator: "\n")
                )
            case .logs:
                let name = try require(request.name, "service name")
                _ = try index(of: name)
                let lines = min(max(request.lines ?? 100, 1), 5000)
                return ControlResponse(ok: true, log: ServiceLogs.read(paths.logFile(for: name), lines: lines))
            case .port:
                let port = try require(request.port, "port")
                let listeners = PortProbe.listeners(on: port)
                let owner = config.services.first { $0.port == port }
                return ControlResponse(ok: true, message: owner.map { "Port \(port) belongs to service '\($0.name)'." }, listeners: listeners)
            case .killPort:
                return try killPort(try require(request.port, "port"))
            }
        } catch {
            return .failure(error)
        }
    }

    private func killPort(_ port: Int) throws -> ControlResponse {
        let listeners = PortProbe.listeners(on: port)
        guard !listeners.isEmpty else {
            return ControlResponse(ok: true, message: "Nothing is listening on port \(port).", listeners: [])
        }
        var messages: [String] = []
        for listener in listeners {
            // If it's one of ours, stop the service properly instead.
            let pgid = getpgid(listener.pid)
            if let ours = runtimes.first(where: { $0.value.process?.pid == pgid }) {
                messages.append(try stop(named: ours.key))
            } else if kill(listener.pid, SIGTERM) == 0 {
                messages.append("Sent SIGTERM to \(listener).")
            } else {
                messages.append("Couldn't stop \(listener): \(String(cString: strerror(errno))).")
            }
        }
        return ControlResponse(ok: true, message: messages.joined(separator: "\n"), listeners: listeners)
    }
}
