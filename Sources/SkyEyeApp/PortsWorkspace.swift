import AppKit
import SkyEyeCore
import SwiftUI

/// Scans in the background and publishes what it finds. Listening ports arrive first; who each program
/// talks to follows, because naming addresses and checking signatures takes longer.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var scan: NetworkScan?
    @Published private(set) var isScanning = false
    /// `TrafficHistory.chartJSON()`: bytes per second for each program over the last few minutes.
    @Published private(set) var historyJSON = "{}"
    private let manager: ServiceManager
    private let scanner: NetworkScanner
    private let queue = DispatchQueue(label: "dev.skyeye.network-scan", qos: .utility)
    private var timer: Timer?
    private var sampler: Timer?
    private var recorder = Traffic.Recorder()

    init(manager: ServiceManager) {
        self.manager = manager
        scanner = NetworkScanner(storeURL: manager.paths.root.appendingPathComponent("network.json"))
    }

    /// High-risk programs plus programs whose connections raised an alert, as of the last scan.
    var attentionCount: Int { scan?.attentionCount ?? 0 }

    func rescan() {
        guard !isScanning else { return }
        isScanning = true
        let services = manager.snapshots.map {
            NetworkScanner.Service(
                name: $0.service.name, pid: $0.pid, port: $0.service.port, dependencies: $0.service.dependencies
            )
        }
        let whois = manager.config.settings.whoisLookups
        let scanner = scanner
        queue.async { [weak self] in
            let listening = scanner.scanListening(services: services)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // What takes longer to find stays on screen from the last scan until its turn comes.
                    self.scan = NetworkScan(
                        programs: listening.programs, outgoing: self.scan?.outgoing ?? [],
                        firewall: listening.firewall, scannedAt: listening.scannedAt, tree: listening.tree,
                        traffic: self.scan?.traffic ?? [], local: self.scan?.local ?? LocalMap()
                    )
                }
            }
            let talkers = scanner.scanOutgoing(programs: listening.programs, whois: whois, now: listening.scannedAt)
            let traffic = scanner.scanTraffic(programs: listening.programs, talkers: talkers)
            let sampledAt = Date()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scan = NetworkScan(
                        programs: listening.programs, outgoing: talkers, firewall: listening.firewall,
                        scannedAt: listening.scannedAt, tree: listening.tree, traffic: traffic.programs, local: traffic.local
                    )
                    self.record(traffic.totals, at: sampledAt)
                    self.isScanning = false
                }
            }
        }
    }

    /// One more point for the traffic-over-time chart, between full scans.
    private func sample() {
        guard !isScanning, let scan else { return }
        let scanner = scanner
        queue.async { [weak self] in
            let totals = scanner.sampleTraffic(programs: scan.programs, talkers: scan.outgoing)
            let sampledAt = Date()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.record(totals, at: sampledAt) }
            }
        }
    }

    private func record(_ totals: [String: UInt64], at date: Date) {
        recorder.record(totals, at: date)
        historyJSON = recorder.history.chartJSON()
    }

    /// Scans unless the last scan is recent enough to still be true.
    func rescanIfStale(after age: TimeInterval = 60) {
        if let last = scan?.scannedAt, Date().timeIntervalSince(last) < age { return }
        rescan()
    }

    private static let openedKey = "portsPageOpened"

    /// A scan nobody asked for, to keep the menu's count current. A scan asks every listening port what it is,
    /// so SkyEye does this on its own only once the user has opened the page and so has seen what it does.
    func rescanInBackground() {
        guard Preferences.store.bool(forKey: Self.openedKey) else { return }
        rescanIfStale()
    }

    /// Keeps the page current while its window is open: a full scan every `interval`, and a traffic sample every `sampling`.
    func startPolling(every interval: TimeInterval = 30, sampling: TimeInterval = 10) {
        stopPolling()
        Preferences.store.set(true, forKey: Self.openedKey)
        // Samples from before the window was closed would draw as one long flat stretch: start the chart over.
        if let last = recorder.history.times.last, Date().timeIntervalSince(last) > 60 {
            recorder = Traffic.Recorder()
            historyJSON = recorder.history.chartJSON()
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        let sampler = Timer(timeInterval: sampling, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(sampler, forMode: .common)
        self.timer = timer
        self.sampler = sampler
        rescanIfStale(after: 10)
    }

    func stopPolling() {
        timer?.invalidate()
        sampler?.invalidate()
        timer = nil
        sampler = nil
    }
}

/// Opened from the menu; closing it leaves the menu bar app running and stops the periodic scan.
@MainActor
final class PortsWindowController: NSObject, NSWindowDelegate {
    static let shared = PortsWindowController()
    private var window: NSWindow?
    private weak var monitor: NetworkMonitor?

    func show(manager: ServiceManager, monitor: NetworkMonitor) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "SkyEye — Ports & Network"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: PortsWorkspace().environmentObject(manager).environmentObject(monitor)
                    .defaultAppStorage(Preferences.store)
            )
            window.contentMinSize = NSSize(width: 900, height: 560)
            window.center()
            if !Preferences.isCustomHome {
                window.setFrameUsingName("SkyEyePorts")
                window.setFrameAutosaveName("SkyEyePorts")
            }
            window.delegate = self
            self.window = window
        }
        self.monitor = monitor
        monitor.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        monitor?.stopPolling()
    }
}

/// The menu's way in, with a count when something needs a look.
struct PortsButton: View {
    @EnvironmentObject private var manager: ServiceManager
    @EnvironmentObject private var monitor: NetworkMonitor

    var body: some View {
        let count = monitor.attentionCount
        Button {
            PortsWindowController.shared.show(manager: manager, monitor: monitor)
        } label: {
            HStack(spacing: 4) {
                Label("Ports", systemImage: "shield.lefthalf.filled")
                if count > 0 {
                    Text(String(count))
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Tone.bad, in: Capsule())
                }
            }
        }
        .help(count > 0 ? "Open ports and network: \(count) need a look" : "Open ports and network")
        .accessibilityLabel(count > 0 ? "Ports and network, \(count) need a look" : "Ports and network")
    }
}

// MARK: Formatting

private extension PortRisk {
    var color: Color {
        switch self {
        case .high: Tone.bad
        case .medium: Tone.warn
        case .low: Brand.tint
        case .info: Tone.idle
        }
    }
}

private func portsLabel(_ program: ListeningProgram) -> String {
    let ports = program.ports.map { String($0.port) }
    return ports.count <= 3 ? ports.joined(separator: ", ") : ports.prefix(2).joined(separator: ", ") + " +\(ports.count - 2)"
}

private func memoryLabel(kb: Int) -> String {
    let mb = Double(kb) / 1024
    return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(max(1, Int(mb.rounded()))) MB"
}

private func uptimeLabel(_ interval: TimeInterval) -> String {
    let minutes = Int(interval / 60)
    if minutes < 60 { return "\(max(1, minutes))m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h \(minutes % 60)m" }
    let days = hours / 24
    return days < 7 ? "\(days)d \(hours % 24)h" : "\(days)d"
}

private func agoLabel(_ date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date).rounded())
    if seconds < 5 { return "just now" }
    if seconds < 60 { return "\(seconds)s ago" }
    return "\(seconds / 60)m ago"
}

// MARK: Page

struct PortsWorkspace: View {
    @EnvironmentObject private var manager: ServiceManager
    @EnvironmentObject private var monitor: NetworkMonitor
    /// Section ids, comma separated. App helpers and macOS start folded: they are rarely what you came for.
    @AppStorage("portsFoldedSections") private var folded = "apps,system"
    @AppStorage("portsChartTab") private var chartTab = "ports"
    @State private var selected: Int32?
    @State private var confirming: Int32?
    @State private var notice: Notice?
    @State private var showsAllTalkers = false

    private struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    private static let sections: [(id: ProgramSection, title: String)] = [
        (.servers, "Servers"), (.apps, "App helpers"), (.system, "macOS"),
    ]
    private static let talkersShown = 8

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.7)
            if let notice {
                noticeBar(notice)
            }
            if let scan = monitor.scan {
                tiles(scan)
                Divider().opacity(0.7)
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        charts(scan)
                            .frame(width: min(600, max(420, geometry.size.width * 0.45)))
                        Divider()
                        list(scan)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning this Mac…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(SkyEyeSurface.background)
    }

    // MARK: Header

    private var toolbar: some View {
        HStack(spacing: 10) {
            BrandMark(size: 26)
            Text("Ports & network").font(.system(size: 15, weight: .semibold))
            if let scan = monitor.scan {
                let ports = scan.programs.reduce(0) { $0 + $1.ports.count }
                Chip(text: scan.programs.isEmpty
                     ? "Nothing is listening"
                     : "\(scan.programs.count) programs on \(ports) ports")
                firewall(scan.firewall)
            }
            Spacer()
            if let scan = monitor.scan {
                TimelineView(.periodic(from: Date(), by: 5)) { context in
                    Text(monitor.isScanning ? "Scanning…" : "Checked " + agoLabel(scan.scannedAt, now: context.date))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Button { monitor.rescan() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(monitor.isScanning)
                .keyboardShortcut("r")
                .help("Scan again (⌘R)")
        }
        .buttonStyle(PillButtonStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(alignment: .top) { Brand.wash.frame(height: 90) }
    }

    @ViewBuilder
    private func firewall(_ state: Bool?) -> some View {
        switch state {
        case true?:
            pill("Firewall on", symbol: "checkmark.shield.fill", tint: Tone.good)
        case false?:
            pill("Firewall off", symbol: "xmark.shield.fill", tint: Tone.bad)
                .help("Turn it on in System Settings › Network › Firewall")
        case nil:
            pill("Firewall unknown", symbol: "shield", tint: .secondary)
        }
    }

    private func noticeBar(_ notice: Notice) -> some View {
        NoticeBanner(
            message: notice.text, tone: notice.isError ? Tone.warn : Tone.good,
            symbol: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        ) { self.notice = nil }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func pill(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(TightLabelStyle())
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.13), in: Capsule())
    }

    private func tiles(_ scan: NetworkScan) -> some View {
        let now = scan.scannedAt
        let alerts = scan.outgoing.filter(\.hasAlert).count
        return HStack(spacing: 10) {
            Tile(symbol: "exclamationmark.triangle.fill", count: scan.programs.filter { $0.risk == .high }.count,
                 label: "high risk", color: Tone.bad)
            Tile(symbol: "dot.radiowaves.left.and.right", count: scan.programs.filter { $0.exposure != .loopback }.count,
                 label: "open to a network", color: Tone.warn)
            Tile(symbol: "clock.fill", count: scan.programs.filter { PortScan.isStale($0, now: now) }.count,
                 label: "running over a day", color: Tone.warn)
            Tile(symbol: "arrow.up.arrow.down", count: scan.programs.reduce(0) { $0 + $1.ports.count },
                 label: "ports listening", color: Brand.tint)
            Tile(symbol: "arrow.up.right", count: scan.outgoing.count,
                 label: alerts > 0 ? "talking out · \(alerts) flagged" : "programs talking out",
                 color: alerts > 0 ? Tone.bad : Brand.tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Charts

    @ViewBuilder
    private func charts(_ scan: NetworkScan) -> some View {
        if let directory = ChartBoard.directory {
            VStack(spacing: 0) {
                Picker("Charts", selection: $chartTab) {
                    Text("Ports").tag("ports")
                    Text("Traffic").tag("traffic")
                    Text("Processes").tag("processes")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 2)
                ChartBoard(
                    directory: directory, json: scan.chartJSON(), history: monitor.historyJSON, tab: chartTab, selected: selected
                ) { pid in
                    reveal(pid, in: scan)
                }
            }
        } else {
            Text("Charts are part of the packaged app.\nBuild it with scripts/build.sh to see them.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A program picked in a chart: open its section and bring its row into view.
    private func reveal(_ pid: Int32, in scan: NetworkScan) {
        if let program = scan.programs.first(where: { $0.pid == pid }), !needsLook(program) {
            setFolded(program.section.rawValue, false)
        }
        selected = pid
    }

    // MARK: List

    private func needsLook(_ program: ListeningProgram) -> Bool {
        program.risk == .high || program.risk == .medium
    }

    private var foldedSet: Set<String> { Set(folded.split(separator: ",").map(String.init)) }

    private func setFolded(_ id: String, _ value: Bool) {
        var set = foldedSet
        if value { set.insert(id) } else { set.remove(id) }
        folded = set.sorted().joined(separator: ",")
    }

    private func list(_ scan: NetworkScan) -> some View {
        let attention = scan.programs.filter(needsLook)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !attention.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            heading("Needs a look", count: attention.count, id: nil)
                            ForEach(attention) { row($0, now: scan.scannedAt) }
                        }
                    }
                    ForEach(Self.sections, id: \.id) { section in
                        let programs = scan.programs.filter { $0.section == section.id && !needsLook($0) }
                        if !programs.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                heading(section.title, count: programs.count, id: section.id.rawValue)
                                if !foldedSet.contains(section.id.rawValue) {
                                    ForEach(programs) { row($0, now: scan.scannedAt) }
                                }
                            }
                        }
                    }
                    if !scan.outgoing.isEmpty { outgoing(scan.outgoing) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: selected) { _, pid in
                guard let pid else { return }
                // After this update, so a section that was just opened has its rows.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(pid, anchor: .center) }
                }
            }
        }
    }

    private func heading(_ title: String, count: Int, detail: String? = nil, id: String?) -> some View {
        let label = HStack(spacing: 6) {
            SectionTitle(text: title)
            Text(detail ?? String(count)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            if let id {
                Image(systemName: foldedSet.contains(id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        return Group {
            if let id {
                Button { setFolded(id, !foldedSet.contains(id)) } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title), \(detail ?? String(count)), \(foldedSet.contains(id) ? "collapsed" : "expanded")")
            } else {
                label
            }
        }
        .padding(.horizontal, 2)
    }

    private func row(_ program: ListeningProgram, now: Date) -> some View {
        ProgramRow(
            program: program, now: now, isSelected: selected == program.pid, isConfirming: confirming == program.pid,
            select: { selected = selected == program.pid ? nil : program.pid },
            askStop: { confirming = program.pid },
            stop: { stop(program) },
            cancel: { confirming = nil }
        )
        .id(program.pid)
    }

    private func outgoing(_ talkers: [Talker]) -> some View {
        let alerts = talkers.filter(\.hasAlert)
        let noted = talkers.filter { !$0.flags.isEmpty && !$0.hasAlert }
        let services = Set(talkers.flatMap { $0.peers.map(\.owner) }).count
        // The flagged first, then the busiest, until "more" is pressed.
        let shown = showsAllTalkers
            ? talkers
            : talkers.enumerated().filter { $0.offset < Self.talkersShown || $0.element.hasAlert }.map(\.element)
        return VStack(alignment: .leading, spacing: 7) {
            heading("Outgoing", count: talkers.count, detail: "\(talkers.count) programs → \(services) services", id: "outgoing")
            if !foldedSet.contains("outgoing") {
                HStack(spacing: 4) {
                    if alerts.isEmpty {
                        Label("Nothing suspicious", systemImage: "checkmark.circle").foregroundStyle(Tone.good)
                    } else {
                        Label("\(alerts.count) " + (alerts.count == 1 ? "program needs" : "programs need") + " a look",
                              systemImage: "flag.fill").foregroundStyle(Tone.bad)
                    }
                    Text((noted.isEmpty ? "" : "· \(noted.count) with notes ") + "· checked every 30s, kept for a day")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 2)
                ForEach(shown) { TalkerRow(talker: $0) }
                if talkers.count > shown.count || showsAllTalkers {
                    Button(showsAllTalkers ? "Show fewer" : "\(talkers.count - shown.count) more programs") {
                        showsAllTalkers.toggle()
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    // MARK: Actions

    private func stop(_ program: ListeningProgram) {
        confirming = nil
        if program.managed, let service = program.service {
            // One of ours: stop the service properly, so it isn't restarted or counted as a crash.
            let response = manager.handle(ControlRequest(action: .stop, name: service))
            notice = response.ok
                ? Notice(text: "Stopped \(service)", isError: false)
                : Notice(text: response.error ?? "Couldn't stop \(service).", isError: true)
        } else {
            // Checked again now: the scan may be old enough for a pid to belong to something else.
            let pids = PortScan.currentStopPids(program)
            var failure: String?
            for pid in pids where kill(pid, SIGTERM) != 0 && errno != ESRCH {
                failure = String(cString: strerror(errno))
            }
            if pids.isEmpty {
                notice = Notice(text: "\(program.name) had already exited.", isError: false)
            } else if let failure {
                notice = Notice(text: "Couldn't stop \(program.name): \(failure)", isError: true)
            } else {
                notice = Notice(text: "Stopped \(program.name) (\(portsLabel(program)))", isError: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { monitor.rescan() }
    }
}

// MARK: Pieces

private struct Tile: View {
    let symbol: String
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        let tint = count > 0 ? color : Tone.idle
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(String(count)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .skyCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(label)")
    }
}

private struct ProgramRow: View {
    let program: ListeningProgram
    let now: Date
    let isSelected: Bool
    let isConfirming: Bool
    let select: () -> Void
    let askStop: () -> Void
    let stop: () -> Void
    let cancel: () -> Void

    private var isStale: Bool { PortScan.isStale(program, now: now) }

    private var meta: String {
        let place = program.project.map { [$0, program.place].filter { !$0.isEmpty }.joined(separator: " / ") } ?? program.place
        return ([program.process] + (place.isEmpty ? [] : [place]) + ["by " + program.startedBy, memoryLabel(kb: program.rssKb)])
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(program.risk.color).frame(width: 8, height: 8)
                    .background(Circle().fill(program.risk.color.opacity(program.risk == .info ? 0 : 0.22)).scaleEffect(1.8))
                    .frame(width: 14)
                Text(portsLabel(program)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(program.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let service = program.service {
                    Chip(text: service, tint: Brand.tint)
                        .help(program.managed ? "Started by SkyEye as the service \(service)" : "Watched by SkyEye as the service \(service)")
                }
                Spacer(minLength: 8)
                Text(uptimeLabel(now.timeIntervalSince(program.startedAt)))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(isStale ? Tone.warn : Color.secondary)
                    .help(isStale ? "Running for more than a day" : "")
            }
            Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(program.command)
            if program.risk != .info {
                let lead = program.risk == .high ? "High risk: " : program.risk == .medium ? "Medium: " : ""
                Text(lead + program.reasons.joined(separator: "; "))
                    .font(.caption)
                    .foregroundStyle(program.risk == .low ? Color.secondary : program.risk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .skyCard(stroke: isSelected ? Brand.tint : SkyEyeSurface.hairline, lineWidth: isSelected ? 1.5 : 1)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.tint.opacity(isSelected ? 0.18 : 0)).blur(radius: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: select)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        if isConfirming {
            HStack(spacing: 8) {
                // Verbatim: a program's name can be a page title, and a literal here would be read as Markdown,
                // so a title could put a link into the question.
                Text(verbatim: program.managed && program.service != nil
                     ? "Stop the service \(program.service!)?"
                     : "Stop \(program.name)? Ends pid \(program.stopPids.map(String.init).joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(Tone.warn)
                Button("Stop it", role: .destructive, action: stop)
                Button("Cancel", action: cancel)
            }
            .buttonStyle(PillButtonStyle())
            .padding(.top, 3)
        } else {
            let url = PortScan.openURL(for: program)
            let folder = program.folder.flatMap { $0 == "/" ? nil : $0 }
            if url != nil || folder != nil || PortScan.canStop(program) {
                HStack(spacing: 12) {
                    if let url {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.right.square") }
                            .help(url.absoluteString)
                    }
                    if let folder {
                        // Shown in Finder, never opened: a program can make an app bundle its working directory,
                        // and opening that would launch it.
                        Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) } label: {
                            Label("Folder", systemImage: "folder")
                        }
                        .help(folder)
                    }
                    if PortScan.canStop(program) {
                        Button(action: askStop) { Label("Stop", systemImage: "stop.fill") }
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .padding(.top, 3)
                .padding(.leading, -7)
            }
        }
    }
}

private struct TalkerRow: View {
    let talker: Talker

    private var peers: String {
        let shown = talker.peers.prefix(4).map { "\($0.owner) \($0.count)" }.joined(separator: " · ")
        return "→ " + shown + (talker.peers.count > 4 ? " · +\(talker.peers.count - 4) more" : "")
    }

    private var signature: (text: String, color: Color) {
        switch talker.signer {
        case nil: ("signature not checked", .secondary)
        case "unsigned"?: ("not signed", Tone.bad)
        case "ad-hoc"?: ("ad-hoc signed", Tone.warn)
        case Outgoing.missingFile?: ("file no longer on disk", Tone.warn)
        case let signer?: ("signed by " + signer, .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if talker.hasAlert {
                    Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(Tone.bad).frame(width: 14)
                } else {
                    Circle().fill(talker.flags.isEmpty ? Tone.idle : Tone.warn).frame(width: 8, height: 8).frame(width: 14)
                }
                Text(talker.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(talker.count) " + (talker.count == 1 ? "connection" : "connections"))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(peers).font(.caption).lineLimit(1).truncationMode(.tail)
            HStack(spacing: 4) {
                Text(signature.text).foregroundStyle(signature.color)
                Text("· pid " + talker.pids.map(String.init).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption)
            .help(talker.path)
            ForEach(talker.flags, id: \.self) { flag in
                Label(flag.text, systemImage: flag.level == .alert ? "flag.fill" : "circle.fill")
                    .labelStyle(FlagLabelStyle())
                    .font(.caption)
                    .foregroundStyle(flag.level == .alert ? Tone.bad : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !talker.earlier.isEmpty {
                Text("Earlier today: " + talker.earlier.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .skyCard(stroke: talker.hasAlert ? Tone.bad.opacity(0.55) : SkyEyeSurface.hairline)
    }
}

/// A small leading mark, top-aligned with the first line of wrapped text.
private struct FlagLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon.font(.system(size: 6)).frame(width: 8)
            configuration.title
        }
    }
}
