import AppKit
import SkyEyeCore
import SwiftUI

@MainActor
final class ActivityMonitor: ObservableObject {
    @Published private(set) var json = "{}"
    @Published private(set) var status = "Connecting…"
    @Published private(set) var running = false
    private var process: Process?
    private var generation = UUID()
    private var watchdog: Timer?
    private var lastSample: Date?
    private let queue = DispatchQueue(label: "dev.skyeye.activity", qos: .utility)

    func start(manager: ServiceManager) {
        guard process == nil else { return }
        generation = UUID()
        let generation = generation
        let services = manager.snapshots.map {
            NetworkScanner.Service(name: $0.service.name, pid: $0.pid, port: $0.service.port)
        }
        let storeURL = manager.paths.root.appendingPathComponent("network.json")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-L", "0", "-s", "1", "-x", "-n"]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        status = "Connecting…"
        lastSample = nil
        do { try process.run() } catch {
            status = "Network counters unavailable"
            return
        }
        self.process = process
        running = true
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let lastSample = self.lastSample, Date().timeIntervalSince(lastSample) > 5 {
                    self.status = "Waiting for network counters…"
                }
            }
        }
        queue.async { [weak self] in
            let naming = ActivityNaming(services: services, storeURL: storeURL)
            var frames = NettopFrames()
            var recorder = Activity.Recorder()
            while let data = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024), !data.isEmpty {
                for frame in frames.append(data) {
                    let flows = Traffic.parseNettop(frame, kernelName: ProcessTable.name)
                    let now = NettopFrames.sampledAt(frame) ?? Date()
                    let identities = naming.identities(for: flows, at: now)
                    let sample = recorder.record(flows, identities: identities, owners: naming.owners, at: now)
                    let json = sample.chartJSON()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.generation == generation else { return }
                            self.json = json
                            self.lastSample = now
                            self.status = sample.warmingUp ? "Measuring…" : "Live · 1s"
                        }
                    }
                }
                if frames.overflowed { break }
            }
            try? pipe.fileHandleForReading.close()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.stop()
                    self.status = "Network counters unavailable · retry"
                }
            }
        }
    }

    func stop() {
        generation = UUID()
        watchdog?.invalidate()
        watchdog = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        running = false
        status = "Paused"
        if var snapshot = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] {
            snapshot["active"] = false
            if let data = try? JSONSerialization.data(withJSONObject: snapshot) { json = String(decoding: data, as: UTF8.self) }
        }
    }
}

private final class ActivityNaming {
    private let services: [NetworkScanner.Service]
    private let storeURL: URL
    private var refreshed = Date.distantPast
    private var procs: [Int32: PortScan.Proc] = [:]
    private var groups: [String: String] = [:]
    private(set) var owners: [String: Outgoing.Owned] = [:]

    init(services: [NetworkScanner.Service], storeURL: URL) {
        self.services = services
        self.storeURL = storeURL
    }

    func identities(for flows: [Traffic.Flow], at now: Date) -> [Int32: Activity.Identity] {
        if now.timeIntervalSince(refreshed) > 10 {
            procs = PortScan.parsePs(CommandOutput.ps())
            owners = NetworkScanner(storeURL: storeURL).cachedOwners
            refreshed = now
        }
        let managed = Dictionary(services.compactMap { s in s.pid.map { ($0, s.name) } }, uniquingKeysWith: { a, _ in a })
        var identities: [Int32: Activity.Identity] = [:]
        var activeGroups = Set<String>()
        for pid in Set(flows.map(\.pid)).sorted() {
            let path = ProcessTable.executable(pid) ?? ""
            let name = ProcessTable.name(pid) ?? "Process \(pid)"
            if let service = PortScan.ancestor(of: pid, in: managed, procs) {
                identities[pid] = Activity.Identity(id: "service:\(service)", name: service)
            } else if let app = path.range(of: ".app/") {
                let bundle = String(path[..<app.upperBound])
                activeGroups.insert(bundle)
                let id = groups[bundle] ?? "app:\(pid)"
                groups[bundle] = id
                identities[pid] = Activity.Identity(id: id, name: Outgoing.talkerName(process: name, path: path))
            } else {
                let label = Traffic.displayName(procs[pid]?.command ?? path, executable: path.isEmpty ? nil : path)
                let kind = PortScan.section(of: path, process: name) == .system ? "system" : "program"
                identities[pid] = Activity.Identity(
                    id: "pid:\(pid)", name: Outgoing.talkerName(process: label, path: path), kind: kind
                )
            }
        }
        groups = groups.filter { activeGroups.contains($0.key) }
        return identities
    }
}

private enum CommandOutput {
    static func ps() -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,ppid=,etime=,rss=,%cpu=,command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class MonitoringWindowController: NSObject, NSWindowDelegate {
    static let shared = MonitoringWindowController()
    private var window: NSWindow?
    private let activity = ActivityMonitor()

    func show(manager: ServiceManager) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.title = "SkyEye — Monitoring"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 860, height: 600)
            window.contentView = NSHostingView(rootView: MonitoringWorkspace(activity: activity).environmentObject(manager))
            window.delegate = self
            window.center()
            if !Preferences.isCustomHome {
                window.setFrameUsingName("SkyEyeMonitoring")
                window.setFrameAutosaveName("SkyEyeMonitoring")
            }
            self.window = window
        }
        activity.start(manager: manager)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { activity.stop() }
}

struct MonitoringButton: View {
    @EnvironmentObject private var manager: ServiceManager

    var body: some View {
        Button { MonitoringWindowController.shared.show(manager: manager) } label: {
            Image(systemName: "waveform.path.ecg")
        }
        .help("Monitoring")
        .accessibilityLabel("Monitoring")
    }
}

private struct MonitoringWorkspace: View {
    @EnvironmentObject private var manager: ServiceManager
    @ObservedObject var activity: ActivityMonitor

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.secondary)
                Text("Monitoring").font(.system(size: 15, weight: .semibold))
                Text("Network").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(activity.running ? Color(red: 1, green: 0.353, blue: 0) : Tone.idle).frame(width: 6, height: 6)
                Text(activity.status).font(.system(size: 11)).foregroundStyle(.secondary)
                Button(activity.running ? "Pause" : "Resume") {
                    if activity.running { activity.stop() } else { activity.start(manager: manager) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if let directory = ChartBoard.directory {
                ChartBoard(directory: directory, json: activity.json, history: "{}", tab: "monitoring", selected: nil, onSelect: { _ in })
            } else {
                Text("Build the app bundle to view monitoring.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.white)
    }
}
