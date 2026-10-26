import Darwin
import XCTest
@testable import SkyEyeCore

final class ModelTests: XCTestCase {
    func testDecodesMinimalConfigWithDefaults() throws {
        let json = #"{"services":[{"name":"api","port":3000}]}"#
        let config = try JSONCoding.decoder.decode(SkyEyeConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.services.first?.name, "api")
        XCTAssertEqual(config.services.first?.env, [:])
        XCTAssertEqual(config.services.first?.dependencies, [])
        XCTAssertEqual(config.settings.autoStartMode, .none)
        XCTAssertEqual(config.settings.autoStartServices, [])
        XCTAssertFalse(config.services.first?.autoRestart ?? true)
        XCTAssertTrue(config.settings.requireApproval)
    }

    func testFingerprintTracksWhatRuns() {
        var s = ServiceConfig(name: "api", port: 3000, command: "npm run dev", directory: "/tmp")
        let original = s.fingerprint
        s.port = 4000
        s.group = "web"
        XCTAssertEqual(s.fingerprint, original, "port/group don't affect what runs")
        s.env["DEBUG"] = "1"
        XCTAssertNotEqual(s.fingerprint, original)
    }

    func testNames() {
        XCTAssertTrue(ServiceConfig.isValidName("web-api_2.dev"))
        XCTAssertFalse(ServiceConfig.isValidName("../etc"))
        XCTAssertFalse(ServiceConfig.isValidName("has space"))
        XCTAssertFalse(ServiceConfig.isValidName(""))
    }
}

final class ProbeTests: XCTestCase {
    func testDetectsListeningPort() throws {
        let (fd, port) = try listenOnFreePort()
        XCTAssertTrue(PortProbe.isListening(port))
        XCTAssertEqual(PortProbe.listeners(on: port).first?.pid, getpid())
        close(fd)
        XCTAssertFalse(PortProbe.isListening(port))
    }

    func testSystemUsage() throws {
        var sampler = SystemSampler()
        let first = try XCTUnwrap(sampler.sample())
        XCTAssertNil(first.cpuPercent, "CPU needs two samples")
        XCTAssertGreaterThan(first.memoryUsed, 0)
        XCTAssertLessThan(first.memoryUsed, first.memoryTotal)
        Thread.sleep(forTimeInterval: 0.5)
        let cpu = try XCTUnwrap(sampler.sample()?.cpuPercent)
        XCTAssertTrue((0...100).contains(cpu))
        print("system usage: \(sampler.sample()!.summary)")
    }

    func testResourceSamplerTracksAppAndEmptyServiceSet() throws {
        var sampler = ResourceSampler()
        let first = sampler.sample(pids: [getpid()])
        XCTAssertGreaterThan(first.memoryBytes, 0)
        XCTAssertNil(first.cpuPercent)
        Thread.sleep(forTimeInterval: 0.2)
        let next = sampler.sample(pids: [getpid()])
        XCTAssertTrue((0...100).contains(try XCTUnwrap(next.cpuPercent)))
        XCTAssertGreaterThan(next.memoryBytes, 0)
        let empty = sampler.sample(pids: [])
        XCTAssertEqual(empty.cpuPercent, 0)
        XCTAssertEqual(empty.memoryBytes, 0)
    }

    func testLogTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skyeye-tail-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        LogTail.append((1...50).map { "line \($0)" }.joined(separator: "\n") + "\n", to: url)
        XCTAssertEqual(LogTail.read(url, lines: 2), "line 49\nline 50")
        XCTAssertEqual(LogTail.stripANSI("\u{1B}[32mready\u{1B}[0m"), "ready")
    }
}

final class ProcessTests: XCTestCase {
    func testTerminateStopsChildren() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("skyeye-proc-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let exited = expectation(description: "exited")
        let process = try ManagedProcess.spawn(
            executable: "/bin/sh", arguments: ["-c", "sleep 60 & echo started; wait"],
            directory: "/tmp", environment: ["PATH": "/usr/bin:/bin"], logFile: log
        ) { _ in exited.fulfill() }

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(getpgid(process.pid), process.pid, "runs in its own process group")
        XCTAssertTrue(try String(contentsOf: log).contains("started"))

        process.terminate(grace: 2)
        wait(for: [exited], timeout: 5)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(kill(-process.pid, 0), -1, "no process left in the group")
    }
}

@MainActor
final class ManagerTests: XCTestCase {
    private func makeManager() throws -> (ServiceManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skyeye-test-\(UUID())")
        let manager = ServiceManager(paths: SkyEyePaths(root: root, logsDir: root.appendingPathComponent("logs")))
        var settings = manager.config.settings
        settings.shell = "/bin/sh"
        settings.loadShellProfile = false
        try manager.updateSettings(settings)
        return (manager, root)
    }

    private func waitFor(_ manager: ServiceManager, _ name: String, _ state: ServiceState, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            manager.tick()
            if try manager.snapshot(named: name).state == state { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("'\(name)' never became \(state); is \(try manager.snapshot(named: name).state)")
    }

    func testSelectedAutoStartIncludesDependenciesAndPreservesSelection() throws {
        let (manager, root) = try makeManager()
        defer { manager.stopAll(); try? FileManager.default.removeItem(at: root) }
        try manager.addService(ServiceConfig(name: "db", command: "exec sleep 60"), trusted: true)
        try manager.addService(ServiceConfig(name: "api", command: "exec sleep 60", dependencies: ["db"]), trusted: true)
        try manager.addService(ServiceConfig(name: "other", command: "exec sleep 60"), trusted: true)
        manager.startConfiguredServices()
        XCTAssertEqual(manager.activeCount, 0, "Defaults must not start services")
        var settings = manager.config.settings
        settings.autoStartMode = .selected
        settings.autoStartServices = ["api"]
        try manager.updateSettings(settings)
        XCTAssertEqual(manager.activeCount, 0, "Changing the setting applies on next launch")
        manager.startConfiguredServices()
        XCTAssertEqual(try manager.snapshot(named: "db").state, .running)
        XCTAssertEqual(try manager.snapshot(named: "api").state, .running)
        XCTAssertEqual(try manager.snapshot(named: "other").state, .stopped)
        let pid = try manager.snapshot(named: "api").pid
        manager.startConfiguredServices()
        XCTAssertEqual(try manager.snapshot(named: "api").pid, pid)
        let restored = ServiceManager(paths: manager.paths)
        XCTAssertEqual(restored.config.settings.autoStartMode, .selected)
        XCTAssertEqual(restored.config.settings.autoStartServices, ["api"])
    }

    func testAutoStartAllSkipsMonitorOnlyAndRejectsUnapprovedCommands() throws {
        let (manager, root) = try makeManager()
        defer { manager.stopAll(); try? FileManager.default.removeItem(at: root) }
        try manager.addService(ServiceConfig(name: "approved", command: "exec sleep 60"), trusted: true)
        try manager.addService(ServiceConfig(name: "unapproved", command: "exec sleep 60"), trusted: false)
        var settings = manager.config.settings
        settings.autoStartMode = .all
        try manager.updateSettings(settings)
        manager.startConfiguredServices()
        XCTAssertEqual(try manager.snapshot(named: "approved").state, .running)
        XCTAssertNil(try manager.snapshot(named: "unapproved").pid)
        XCTAssertTrue(manager.autoStartError?.contains("unapproved") == true)
        manager.stopAll()
    }

    func testAutoStartReusesExternalServiceAndSkipsMonitorOnly() async throws {
        let (manager, root) = try makeManager()
        defer { manager.stopAll(); try? FileManager.default.removeItem(at: root) }
        let (fd, port) = try listenOnFreePort()
        defer { close(fd) }
        try manager.addService(ServiceConfig(name: "external", port: port, command: "exec sleep 60"), trusted: true)
        try manager.addService(ServiceConfig(name: "monitor", port: port), trusted: true)
        var settings = manager.config.settings
        settings.autoStartMode = .all
        try manager.updateSettings(settings)
        manager.startConfiguredServices()
        try await waitFor(manager, "external", .external)
        XCTAssertNil(try manager.snapshot(named: "external").pid)
        XCTAssertNil(manager.autoStartError)
        XCTAssertEqual(manager.activeCount, 0)
    }

    func testAutoStartSelectionTracksRenameAndRemoval() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        var service = try manager.addService(ServiceConfig(name: "web", command: "exec sleep 60"), trusted: true)
        var settings = manager.config.settings
        settings.autoStartMode = .selected
        settings.autoStartServices = ["web"]
        try manager.updateSettings(settings)
        service.name = "app"
        try manager.updateService(named: "web", to: service, trusted: true)
        XCTAssertEqual(manager.config.settings.autoStartServices, ["app"])
        try manager.removeService(named: "app")
        XCTAssertTrue(manager.config.settings.autoStartServices.isEmpty)
    }

    func testDependencyValidationRenameAndPersistence() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try manager.addService(ServiceConfig(name: "db", port: 5432), trusted: true)
        try manager.addService(ServiceConfig(name: "api", command: "sleep 60", dependencies: ["db"]), trusted: true)
        var db = manager.service(named: "db")!
        db.dependencies = ["api"]
        XCTAssertThrowsError(try manager.updateService(named: "db", to: db, trusted: true))
        XCTAssertEqual(manager.service(named: "db")?.dependencies, [])
        XCTAssertThrowsError(try manager.addService(ServiceConfig(name: "bad", command: "sleep 60", dependencies: ["missing"]), trusted: true))
        XCTAssertThrowsError(try manager.addService(ServiceConfig(name: "self", command: "sleep 60", dependencies: ["self"]), trusted: true))
        XCTAssertThrowsError(try manager.removeService(named: "db"))
        db.dependencies = []
        db.name = "postgres"
        try manager.updateService(named: "db", to: db, trusted: true)
        XCTAssertEqual(manager.service(named: "api")?.dependencies, ["postgres"])
        let reloaded = ServiceManager(paths: manager.paths)
        XCTAssertEqual(reloaded.service(named: "api")?.dependencies, ["postgres"])
        XCTAssertEqual(try ServiceGraph.order(reloaded.config.services), ["postgres", "api"])
    }

    func testRecursiveStartupWaitsAndReusesSharedDependency() async throws {
        let (manager, root) = try makeManager()
        defer { manager.stopAll(); try? FileManager.default.removeItem(at: root) }
        let (fd, port) = try listenOnFreePort()
        close(fd)
        try manager.addService(ServiceConfig(name: "db", port: port,
            command: "sleep 1; exec python3 -m http.server \(port) --bind 127.0.0.1", healthPath: "/"), trusted: true)
        try manager.addService(ServiceConfig(name: "api", command: "exec sleep 60", dependencies: ["db"]), trusted: true)
        try manager.addService(ServiceConfig(name: "web", command: "exec sleep 60", dependencies: ["api"]), trusted: true)
        try manager.addService(ServiceConfig(name: "worker", command: "exec sleep 60", dependencies: ["db"]), trusted: true)
        try manager.start(named: "web")
        try manager.start(named: "worker")
        XCTAssertEqual(try manager.snapshot(named: "web").state, .starting)
        XCTAssertNil(try manager.snapshot(named: "api").pid)
        XCTAssertNil(try manager.snapshot(named: "web").pid)
        try await waitFor(manager, "web", .running)
        try await waitFor(manager, "worker", .running)
        let dbPID = try XCTUnwrap(manager.snapshot(named: "db").pid)
        XCTAssertEqual(try manager.snapshot(named: "api").state, .running)
        try manager.stop(named: "web")
        try await waitFor(manager, "web", .stopped)
        XCTAssertEqual(try manager.snapshot(named: "db").pid, dbPID)
        try manager.start(named: "web")
        try await waitFor(manager, "web", .running)
        XCTAssertEqual(try manager.snapshot(named: "db").pid, dbPID)
        let log = LogTail.read(manager.paths.logFile(for: "db"), lines: 100)
        XCTAssertEqual(log.components(separatedBy: "starting 'db'").count - 1, 1)
    }

    func testFailedDependencyBlocksDependent() async throws {
        let (manager, root) = try makeManager()
        defer { manager.stopAll(); try? FileManager.default.removeItem(at: root) }
        let (fd, port) = try listenOnFreePort()
        close(fd)
        try manager.addService(ServiceConfig(name: "db", port: port, command: "exit 7"), trusted: true)
        try manager.addService(ServiceConfig(name: "web", command: "exec sleep 60", dependencies: ["db"]), trusted: true)
        try manager.start(named: "web")
        try await waitFor(manager, "web", .crashed)
        XCTAssertNil(try manager.snapshot(named: "web").pid)
        XCTAssertTrue(try manager.snapshot(named: "web").detail?.contains("db") == true)
    }

    func testUnapprovedDependencyPreventsAnyStartup() throws {
        let (manager, root) = try makeManager()
        defer { manager.stopAll(); try? FileManager.default.removeItem(at: root) }
        try manager.addService(ServiceConfig(name: "db", command: "exec sleep 60"), trusted: false)
        try manager.addService(ServiceConfig(name: "web", command: "exec sleep 60", dependencies: ["db"]), trusted: true)
        XCTAssertThrowsError(try manager.start(named: "web"))
        XCTAssertNil(try manager.snapshot(named: "db").pid)
        XCTAssertNil(try manager.snapshot(named: "web").pid)
    }

    func testDependencyReadinessTimeout() async throws {
        let (manager, root) = try makeManager()
        defer { manager.stopAll(); try? FileManager.default.removeItem(at: root) }
        manager.startupGrace = 0.5
        let (fd, port) = try listenOnFreePort()
        close(fd)
        try manager.addService(ServiceConfig(name: "db", port: port, command: "exec sleep 60"), trusted: true)
        try manager.addService(ServiceConfig(name: "web", command: "exec sleep 60", dependencies: ["db"]), trusted: true)
        try manager.start(named: "web")
        try await waitFor(manager, "web", .crashed)
        XCTAssertNil(try manager.snapshot(named: "web").pid)
        XCTAssertTrue(try manager.snapshot(named: "web").detail?.contains("db") == true)
    }

    func testStoppingWaitingServiceCancelsStartup() async throws {
        let (manager, root) = try makeManager()
        defer { manager.stopAll(); try? FileManager.default.removeItem(at: root) }
        let (fd, port) = try listenOnFreePort()
        close(fd)
        try manager.addService(ServiceConfig(name: "db", port: port, command: "exec sleep 60"), trusted: true)
        try manager.addService(ServiceConfig(name: "web", command: "exec sleep 60", dependencies: ["db"]), trusted: true)
        try manager.start(named: "web")
        try manager.stop(named: "web")
        manager.tick()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(try manager.snapshot(named: "web").state, .stopped)
        XCTAssertNil(try manager.snapshot(named: "web").pid)
    }

    func testDependentAutoRestartKeepsRetryCount() async throws {
        let (manager, root) = try makeManager()
        defer { manager.stopAll(); try? FileManager.default.removeItem(at: root) }
        let (fd, port) = try listenOnFreePort()
        close(fd)
        try manager.addService(ServiceConfig(name: "db", port: port,
            command: "exec python3 -m http.server \(port) --bind 127.0.0.1"), trusted: true)
        try manager.addService(ServiceConfig(name: "web", command: "exit 5", autoRestart: true, dependencies: ["db"]), trusted: true)
        manager.startMonitoring(interval: 0.1)
        try manager.start(named: "web")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            manager.tick()
            if try manager.snapshot(named: "web").autoRestarts >= 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThanOrEqual(try manager.snapshot(named: "web").autoRestarts, 2)
    }

    func testMonitorOnlyDependencyReusedWhenReady() async throws {
        let (manager, root) = try makeManager()
        defer { manager.stopAll(); try? FileManager.default.removeItem(at: root) }
        let (fd, port) = try listenOnFreePort()
        defer { close(fd) }
        try manager.addService(ServiceConfig(name: "db", port: port), trusted: true)
        try manager.addService(ServiceConfig(name: "web", command: "exec sleep 60", dependencies: ["db"]), trusted: true)
        try manager.start(named: "web")
        try await waitFor(manager, "web", .running)
        XCTAssertNil(try manager.snapshot(named: "db").pid)
    }

    func testUntrustedCommandsNeedApproval() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let added = manager.handle(ControlRequest(action: .add, service: ServiceConfig(name: "x", command: "echo hi")))
        XCTAssertTrue(added.ok)
        XCTAssertEqual(added.service?.state, .pendingApproval)
        XCTAssertFalse(manager.handle(ControlRequest(action: .start, name: "x")).ok)

        try manager.approve(named: "x")
        XCTAssertEqual(try manager.snapshot(named: "x").state, .stopped)

        // Changing the command through the API needs approval again.
        var changed = manager.service(named: "x")!
        changed.command = "echo bye"
        XCTAssertTrue(manager.handle(ControlRequest(action: .update, name: "x", service: changed)).ok)
        XCTAssertEqual(try manager.snapshot(named: "x").state, .pendingApproval)
    }

    func testStartHealthCheckAndStop() async throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let (fd, port) = try listenOnFreePort()
        close(fd)

        try manager.addService(
            ServiceConfig(name: "web", port: port, command: "exec python3 -m http.server \(port) --bind 127.0.0.1", directory: "/tmp", healthPath: "/"),
            trusted: true
        )
        try manager.start(named: "web")
        try await waitFor(manager, "web", .running)

        XCTAssertFalse(manager.handle(ControlRequest(action: .start, name: "web")).error != nil)
        try manager.stop(named: "web")
        try await waitFor(manager, "web", .stopped)
        XCTAssertFalse(PortProbe.isListening(port))
    }

    func testDetachedServiceIsTakenBackOver() async throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let (fd, port) = try listenOnFreePort()
        close(fd)

        try manager.addService(
            ServiceConfig(name: "web", port: port, command: "exec python3 -m http.server \(port) --bind 127.0.0.1", directory: "/tmp"),
            trusted: true
        )
        try manager.start(named: "web")
        try await waitFor(manager, "web", .running)
        let pid = try manager.snapshot(named: "web").pid

        manager.detachAll()
        let relaunched = ServiceManager(paths: manager.paths)
        relaunched.adoptDetached()
        XCTAssertEqual(try relaunched.snapshot(named: "web").pid, pid)
        try await waitFor(relaunched, "web", .running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.paths.detachedFile.path))

        try relaunched.stop(named: "web")
        try await waitFor(relaunched, "web", .stopped)
        XCTAssertFalse(PortProbe.isListening(port))
    }

    func testReportsUsageOfWholeGroup() async throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        // The busy loop runs in a child of the shell, so it only counts if the whole group is summed.
        try manager.addService(ServiceConfig(name: "busy", command: "sh -c 'while :; do :; done' & wait"), trusted: true)
        try manager.start(named: "busy")
        defer { manager.stopAll() }

        try await Task.sleep(nanoseconds: 1_200_000_000)
        manager.tick()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        manager.tick()
        let snapshot = try manager.snapshot(named: "busy")
        XCTAssertGreaterThan(snapshot.memoryBytes ?? 0, 0)
        XCTAssertGreaterThan(manager.skyEyeUsage?.memoryBytes ?? 0, 0)
        XCTAssertGreaterThan(manager.servicesUsage?.memoryBytes ?? 0, 0)
        XCTAssertGreaterThan(manager.servicesUsage?.cpuPercent ?? 0, 0)
        XCTAssertLessThanOrEqual(manager.servicesUsage?.cpuPercent ?? 101, 100)
        XCTAssertGreaterThan(snapshot.cpuPercent ?? 0, 50)
        XCTAssertLessThan(snapshot.cpuPercent ?? 0, 150)
    }

    func testCrashIsReported() async throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try manager.addService(ServiceConfig(name: "bad", command: "echo boom; exit 3"), trusted: true)
        try manager.start(named: "bad")
        try await waitFor(manager, "bad", .crashed)
        XCTAssertEqual(try manager.snapshot(named: "bad").lastExit, "exit code 3")
        XCTAssertTrue(manager.handle(ControlRequest(action: .logs, name: "bad")).log?.contains("boom") == true)
    }

    func testRenameWhileAutoRestartPendingStillRestarts() async throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { manager.stopAll() }

        try manager.addService(ServiceConfig(name: "flaky", command: "exit 5", autoRestart: true), trusted: true)
        try manager.start(named: "flaky")
        try await waitFor(manager, "flaky", .crashed)

        // Wait until the first auto-restart is scheduled (the attempt counter is bumped before the delay).
        let scheduled = Date().addingTimeInterval(5)
        while Date() < scheduled {
            if try manager.snapshot(named: "flaky").autoRestarts > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try manager.snapshot(named: "flaky").autoRestarts, 1)

        var renamed = manager.service(named: "flaky")!
        renamed.name = "flaky-renamed"
        _ = try manager.updateService(named: "flaky", to: renamed, trusted: true)

        // The pending restart must still fire, under the new name, and count as a second attempt.
        let restarted = Date().addingTimeInterval(6)
        while Date() < restarted {
            if try manager.snapshot(named: "flaky-renamed").autoRestarts >= 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try manager.snapshot(named: "flaky-renamed").autoRestarts, 2)
    }

    func testUpdatingRunningCommandLeavesNewCommandUnapproved() async throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { manager.stopAll() }
        let (fd, port) = try listenOnFreePort()
        close(fd)

        let command = "exec python3 -m http.server " + String(port) + " --bind 127.0.0.1"
        try manager.addService(ServiceConfig(name: "web", port: port, command: command, directory: "/tmp"), trusted: true)
        try manager.start(named: "web")
        try await waitFor(manager, "web", .running)

        // An agent changes the command of a running service: the process keeps running the old
        // command, but the new one is unapproved and must not be masked by the .running state.
        var changed = manager.service(named: "web")!
        changed.command = command + " --directory /tmp"
        _ = try manager.updateService(named: "web", to: changed, trusted: false)

        let snapshot = try manager.snapshot(named: "web")
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertFalse(snapshot.approved)

        // Approving a running service is possible from the UI; the process restarts separately.
        try manager.approve(named: "web")
        XCTAssertTrue(try manager.snapshot(named: "web").approved)
    }
}

/// Opens a listening TCP socket on 127.0.0.1 with a kernel-assigned port.
func listenOnFreePort() throws -> (Int32, Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr -> Bool in
            bind(fd, ptr, len) == 0 && listen(fd, 4) == 0 && getsockname(fd, ptr, &len) == 0
        }
    }
    guard bound else { throw SkyEyeError("couldn't open a test socket") }
    return (fd, Int(UInt16(bigEndian: addr.sin_port)))
}
