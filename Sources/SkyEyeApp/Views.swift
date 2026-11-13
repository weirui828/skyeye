import AppKit
import Combine
import ServiceManagement
import SkyEyeCore
import SwiftUI

enum Route: Equatable {
    case list
    case edit(String?)
    case logs(String)
    case settings
}

extension Route {
    /// A page named on the command line.
    init?(argument: String) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("settings", nil): self = .settings
        case ("new", nil): self = .edit(nil)
        case ("edit", let name?): self = .edit(name)
        case ("logs", let name?): self = .logs(name)
        default: return nil
        }
    }
}

struct MenuContentView: View {
    @EnvironmentObject private var manager: ServiceManager
    @State private var route: Route

    init(route: Route = .list) {
        _route = State(initialValue: route)
    }

    var body: some View {
        Group {
            switch route {
            case .list: ServiceListView(route: $route)
            case .edit(let name): ServiceEditorView(original: name.flatMap { manager.service(named: $0) }, route: $route)
            case .logs(let name): LogView(name: name, route: $route)
            case .settings: SettingsView(route: $route)
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.14), value: route)
        .frame(width: route == .settings ? 480 : 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .top) { Brand.wash.frame(height: 150) }
        .background(SkyEyeSurface.background.ignoresSafeArea())
        .defaultAppStorage(Preferences.store)
        .background(GeometryReader { proxy in WindowFitter(size: proxy.size) })
    }
}

/// MenuBarExtra's window grows with its content but doesn't reliably shrink back (e.g. after leaving Settings, or when
/// the list changes while the panel is closed), leaving the content floating in an oversized panel. Pin the window to
/// the content's size, keeping its top edge under the menu bar.
struct WindowFitter: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let size = size
        DispatchQueue.main.async {
            guard let window = view.window, size.width > 0, size.height > 0 else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.height - size.height) > 0.5 || abs(content.width - size.width) > 0.5 else { return }
            var frame = window.frameRect(forContentRect: NSRect(origin: content.origin, size: size))
            frame.origin.y = window.frame.maxY - frame.height
            window.setFrame(frame, display: true)
        }
    }
}

// MARK: Shared bits

/// An inset separator, like the ones between groups in a system menu.
struct MenuDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 12).padding(.vertical, 4)
    }
}

/// A rounded highlight under the hovered row, inset from the edges like a system menu's selection.
struct MenuHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .padding(.horizontal, 6)
    }
}

extension View {
    func menuHighlight() -> some View { modifier(MenuHighlight()) }
}

/// The computer's CPU and memory in one line, for a toolbar.
struct ResourceUsageStatus: View {
    @EnvironmentObject private var manager: ServiceManager
    @ObservedObject private var history = UsageHistory.shared

    var body: some View {
        let usage = manager.systemUsage
        let memoryFraction = usage.map { $0.memoryTotal > 0 ? Double($0.memoryUsed) / Double($0.memoryTotal) : 0 } ?? 0
        HStack(spacing: 7) {
            Image(systemName: "cpu").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(usage?.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
            Sparkline(values: history.system, floor: 20).frame(width: 44, height: 14)
            Divider().frame(height: 12)
            Image(systemName: "memorychip").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(usage.map(Self.memory) ?? "—")
                .foregroundStyle(memoryFraction > 0.9 ? Tone.warn : Color.primary.opacity(0.85))
        }
        .font(.system(size: 11.5, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Whole computer: " + (usage?.summary ?? "no reading yet"))
        .help(Self.breakdown(manager))
    }

    static func memory(_ usage: SystemUsage) -> String {
        let gb = 1_073_741_824.0
        return String(format: "%.1f / %.0f GB", Double(usage.memoryUsed) / gb, Double(usage.memoryTotal) / gb)
    }

    static func breakdown(_ manager: ServiceManager) -> String {
        [
            "Whole computer: " + (manager.systemUsage?.summary ?? "—"),
            "Running services: " + (manager.servicesUsage?.summary ?? "—"),
            "SkyEye app: " + (manager.skyEyeUsage?.summary ?? "—"),
        ].joined(separator: "\n")
    }
}

struct PanelHeader<Trailing: View>: View {
    let title: String
    var back: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let back {
                IconButton(symbol: "chevron.left", help: "Back", size: 26, filled: true, action: back)
            }
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        NoticeBanner(message: message, dismiss: dismiss)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
    }
}

struct Overview: View {
    @EnvironmentObject private var manager: ServiceManager
    @ObservedObject private var history = UsageHistory.shared
    let openSettings: () -> Void

    private var states: [ServiceState] { manager.snapshots.map(\.state) }
    private var upCount: Int { states.filter { $0 == .running || $0 == .external }.count }

    /// One sentence on how things stand, and the color of the worst of it.
    private var status: (text: String, color: Color) {
        let total = states.count
        guard total > 0 else { return ("Nothing to watch yet", .secondary) }
        var problems: [String] = []
        let crashed = states.filter { $0 == .crashed }.count
        let unhealthy = states.filter { $0 == .unhealthy }.count
        let waiting = manager.snapshots.filter { $0.state == .pendingApproval || !$0.approved }.count
        if crashed > 0 { problems.append("\(crashed) crashed") }
        if unhealthy > 0 { problems.append("\(unhealthy) unhealthy") }
        if waiting > 0 { problems.append("\(waiting) " + (waiting == 1 ? "needs" : "need") + " approval") }
        let running = upCount == total ? "All \(total) running" : "\(upCount) of \(total) running"
        if problems.isEmpty { return (running, upCount == total ? Tone.good : .secondary) }
        return (([running] + problems).joined(separator: " · "), crashed > 0 ? Tone.bad : Tone.warn)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                BrandMark(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SkyEye").font(.system(size: 15, weight: .semibold))
                    Text(status.text)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(status.color)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                IconButton(symbol: "gearshape", help: "Settings (⌘,)", size: 28, filled: true, action: openSettings)
                    .keyboardShortcut(",")
            }
            HStack(spacing: 8) {
                cpu
                memory
                services
            }
            .help(ResourceUsageStatus.breakdown(manager))
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var cpu: some View {
        let value = manager.systemUsage?.cpuPercent
        return Metric(title: "CPU", value: value.map { String(format: "%.0f", $0) } ?? "—", unit: "%") {
            Sparkline(values: history.system, tint: (value ?? 0) > 85 ? Tone.warn : Brand.tint, floor: 20)
        }
        .accessibilityLabel("CPU, whole computer: " + (value.map { String(format: "%.0f percent", $0) } ?? "no reading yet"))
    }

    private var memory: some View {
        let usage = manager.systemUsage
        let gb = 1_073_741_824.0
        let fraction = usage.map { $0.memoryTotal > 0 ? Double($0.memoryUsed) / Double($0.memoryTotal) : 0 } ?? 0
        return Metric(
            title: "Memory",
            value: usage.map { String(format: "%.1f", Double($0.memoryUsed) / gb) } ?? "—",
            unit: usage.map { String(format: "/ %.0f GB", Double($0.memoryTotal) / gb) } ?? ""
        ) {
            Meter(fraction: fraction, tint: fraction > 0.9 ? Tone.warn : Brand.tint).frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityLabel("Memory, whole computer: " + (usage.map(ResourceUsageStatus.memory) ?? "no reading yet"))
    }

    private var services: some View {
        Metric(title: "Services", value: String(upCount), unit: "/ \(states.count) up") {
            StateBar(states: states).frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityLabel("\(upCount) of \(states.count) services running")
    }
}

private struct Metric<Graphic: View>: View {
    let title: String
    let value: String
    let unit: String
    @ViewBuilder var graphic: Graphic

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                Text(unit).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            graphic.frame(height: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .skyCard(radius: 11)
        .accessibilityElement(children: .ignore)
    }
}

// MARK: List

struct ServiceListView: View {
    @EnvironmentObject private var manager: ServiceManager
    @EnvironmentObject private var monitor: NetworkMonitor
    @Binding var route: Route
    @State private var error: String?

    private enum ListItem: Identifiable {
        case group(name: String, items: [ServiceSnapshot])
        case single(ServiceSnapshot)

        var id: String {
            switch self {
            case .group(let name, _): return "g:" + name
            case .single(let snapshot): return "s:" + snapshot.id
            }
        }

        var sortKey: String {
            switch self {
            case .group(let name, _): return name
            case .single(let snapshot): return snapshot.service.name
            }
        }
    }

    /// Sort services and groups alphabetically by display name.
    private var items: [ListItem] {
        let regular = manager.snapshots.filter { $0.state != .pendingApproval }
        var grouped: [String: [ServiceSnapshot]] = [:]
        var singles: [ServiceSnapshot] = []

        for snapshot in regular {
            if let group = snapshot.service.group?.trimmingCharacters(in: .whitespaces), !group.isEmpty {
                grouped[group, default: []].append(snapshot)
            } else {
                singles.append(snapshot)
            }
        }

        var result: [ListItem] = []
        for (group, groupItems) in grouped {
            if groupItems.count > 1 {
                let sortedItems = groupItems.sorted {
                    $0.service.name.localizedStandardCompare($1.service.name) == .orderedAscending
                }
                result.append(.group(name: group, items: sortedItems))
            } else {
                result.append(contentsOf: groupItems.map { .single($0) })
            }
        }
        result.append(contentsOf: singles.map { .single($0) })

        return result.sorted {
            $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Overview { route = .settings }
            if let message = error ?? manager.loadError ?? manager.autoStartError {
                ErrorBanner(message: message) { error = nil; manager.dismissAutoStartError() }
            }
            HStack(spacing: 6) {
                Button {
                    CanvasWindowController.shared.show(manager: manager)
                } label: {
                    Label("Canvas", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("See which services depend on which")
                PortsButton()
                Spacer()
                Button { route = .edit(nil) } label: {
                    Label("Add service", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut("n")
                .help("Add a service (⌘N)")
            }
            .buttonStyle(PillButtonStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if manager.snapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        let pending = manager.snapshots.filter { $0.state == .pendingApproval }
                        if !pending.isEmpty {
                            SectionTitle(text: "Needs your approval").padding(.horizontal, 4).padding(.top, 2)
                            ForEach(pending) { ApprovalRow(snapshot: $0, onError: { error = $0 }) }
                        }
                        ForEach(items) { item in
                            switch item {
                            case .group(let group, let groupItems):
                                GroupCard(group: group, items: groupItems, route: $route, onError: { error = $0 })
                            case .single(let snapshot):
                                ServiceCard(snapshot: snapshot, route: $route, onError: { error = $0 })
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 470)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.6)
            footer
        }
        // The Ports button's count comes from the last scan: refresh it when the menu opens.
        .onAppear { monitor.rescanInBackground() }
    }

    private var footer: some View {
        let keepRunning = manager.config.settings.keepRunningOnQuit
        let active = manager.activeCount
        return Button { NSApp.terminate(nil) } label: {
            HStack(spacing: 6) {
                Image(systemName: "power").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text("Quit SkyEye")
                Spacer()
                if active > 0 {
                    Text(keepRunning ? "Services keep running" : "Stops " + String(active) + (active == 1 ? " service" : " services"))
                        .foregroundStyle(keepRunning ? Color.secondary : Tone.warn)
                }
                Text("⌘Q").foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
        .menuHighlight()
        .padding(.vertical, 5)
        .help(active > 0 && !keepRunning ? "Stops the running services first" : "")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            BrandMark(size: 52)
            Text("Nothing to watch yet").font(.system(size: 15, weight: .semibold)).padding(.top, 4)
            Text("Add the servers you run while you work.\nSkyEye starts them in order and keeps an eye on them.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { route = .edit(nil) } label: { Label("Add your first service", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(prominent: true))
                .padding(.top, 2)
            HStack(spacing: 5) {
                Text("or run")
                Text("sky add").font(.system(size: 11, design: .monospaced)).padding(.horizontal, 5).padding(.vertical, 1).skyWell(radius: 4)
                Text("in a terminal, or ask your coding agent")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 30)
    }
}

/// A group's services on one card.
struct GroupCard: View {
    @EnvironmentObject private var manager: ServiceManager
    /// The names of the folded groups, one to a line.
    @AppStorage("foldedGroups") private var folded = ""
    let group: String
    let items: [ServiceSnapshot]
    @Binding var route: Route
    let onError: (String?) -> Void

    private var upCount: Int {
        items.filter { $0.state == .running || $0.state == .external }.count
    }

    /// Only services SkyEye can actually run take part in the group toggle: monitor-only
    /// services have no command, so starting or stopping them would just report errors.
    private var manageableActive: [ServiceSnapshot] {
        items.filter { $0.service.command != nil && $0.state.isActive && $0.state != .external }
    }
    private var startable: [ServiceSnapshot] {
        items.filter { $0.service.command != nil && $0.approved && ($0.state == .stopped || $0.state == .crashed) }
    }
    private var transitioning: Bool { items.contains { $0.state == .starting || $0.state == .stopping } }

    private var isFolded: Bool { folded.split(separator: "\n").contains(Substring(group)) }

    private func toggleFold() {
        var names = folded.split(separator: "\n").map(String.init).filter { $0 != group }
        if !isFolded { names.append(group) }
        withAnimation(.easeInOut(duration: 0.18)) { folded = names.joined(separator: "\n") }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isFolded {
                ForEach(items) { snapshot in
                    Divider().padding(.leading, 34).opacity(0.7)
                    ServiceCard(snapshot: snapshot, route: $route, onError: onError, style: .row)
                }
            }
        }
        .padding(.bottom, isFolded ? 0 : 3)
        .skyCard()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: toggleFold) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                        .frame(width: 16)
                    Text(group).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Chip(text: String(upCount) + "/" + String(items.count), tint: upCount == items.count ? .secondary : Tone.warn)
                    if isFolded {
                        HStack(spacing: 4) {
                            ForEach(items) { Circle().fill($0.state.color).frame(width: 6, height: 6) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFolded ? "Show the services in " + group : "Fold " + group)
            .accessibilityLabel("\(group), \(upCount) of \(items.count) running, \(isFolded ? "folded" : "open")")
            if !startable.isEmpty {
                Button { run(.start, items: startable) } label: { Label("Start all", systemImage: "play.fill") }
                    .disabled(transitioning)
            }
            if !manageableActive.isEmpty {
                Button { run(.stop, items: manageableActive) } label: { Label("Stop all", systemImage: "stop.fill") }
                    .disabled(transitioning)
            }
        }
        .buttonStyle(QuietButtonStyle())
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
    }

    private func run(_ action: ControlRequest.Action, items: [ServiceSnapshot]) {
        var failures: [String] = []
        for item in items {
            let response = manager.handle(ControlRequest(action: action, name: item.service.name))
            if !response.ok { failures.append(response.error ?? item.service.name + " failed") }
        }
        onError(failures.isEmpty ? nil : failures.joined(separator: "\n"))
    }
}

struct ServiceCard: View {
    /// On its own a service is a card.
    enum Style { case card, row }

    @EnvironmentObject private var manager: ServiceManager
    @ObservedObject private var history = UsageHistory.shared
    let snapshot: ServiceSnapshot
    @Binding var route: Route
    let onError: (String?) -> Void
    var onStop: (() -> Void)? = nil
    var style: Style = .card
    /// Leaves out the small chart, where the row is narrow.
    var compact = false
    @State private var hovering = false
    @State private var confirmRemove = false

    private var service: ServiceConfig { snapshot.service }

    private var isLive: Bool {
        [.running, .unhealthy, .starting, .external].contains(snapshot.state)
    }

    private var needsApproval: Bool { !snapshot.approved && service.command != nil }

    private var subtitle: String {
        var text: String
        let detail = snapshot.detail.flatMap { $0.isEmpty ? nil : $0 }
        switch snapshot.state {
        case .running:
            text = snapshot.startedAt.map { "Running for " + Format.uptime(Date().timeIntervalSince($0)) } ?? "Running"
        case .pendingApproval:
            text = "Waiting for your approval"
        case .external:
            text = "Running outside SkyEye" + (detail.map { " — " + $0 } ?? "")
        case .stopped:
            text = (service.command == nil ? "Not running — monitor only" : "Stopped") + (detail.map { " — " + $0 } ?? "")
        default:
            let label = snapshot.state.label
            text = label.prefix(1).uppercased() + label.dropFirst() + (detail.map { " — " + $0 } ?? "")
        }
        if needsApproval, snapshot.state != .pendingApproval {
            text += " · new command needs approval"
        }
        return text
    }

    private var subtitleColor: Color {
        switch snapshot.state {
        case .crashed: Tone.bad
        case .unhealthy, .pendingApproval: Tone.warn
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(state: snapshot.state)
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(service.name).font(.system(size: 13, weight: .medium)).lineLimit(1).layoutPriority(1)
                        portChip.fixedSize()
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(subtitle)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                usage.opacity(hovering ? 0 : 1)
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 0) {
                    hoverActions
                    moreMenu
                }
                .padding(.leading, 22)
                .background(LinearGradient(
                    stops: [.init(color: SkyEyeSurface.card.opacity(0), location: 0), .init(color: SkyEyeSurface.card, location: 0.22)],
                    startPoint: .leading, endPoint: .trailing
                ))
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            primaryAction
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 46)
        .modifier(Surface(style: style, hovering: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help([service.command, snapshot.pid.map { "pid " + String($0) }].compactMap { $0 }.joined(separator: "\n"))
        .contextMenu { menuActions }
        .accessibilityElement(children: .contain)
        .confirmationDialog("Remove " + service.name + "?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Service", role: .destructive) {
                do { try manager.removeService(named: service.name) } catch { onError(error.localizedDescription) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be stopped and removed from SkyEye. Its log file stays on disk.")
        }
    }

    private struct Surface: ViewModifier {
        let style: Style
        let hovering: Bool

        func body(content: Content) -> some View {
            switch style {
            case .card:
                content.skyCard(stroke: hovering ? Color.primary.opacity(0.17) : SkyEyeSurface.hairline)
            case .row:
                content
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(hovering ? 0.045 : 0))
                            .padding(.horizontal, 3)
                    )
            }
        }
    }

    @ViewBuilder
    private var portChip: some View {
        if let port = service.port {
            if isLive, let url = service.url, let target = URL(string: url) {
                Button { NSWorkspace.shared.open(target) } label: {
                    Chip(text: ":" + String(port), tint: Brand.tint, monospaced: true)
                }
                .buttonStyle(.plain)
                .help("Open " + url)
                .accessibilityLabel("Open " + url)
            } else {
                Chip(text: ":" + String(port), monospaced: true)
            }
        }
    }

    @ViewBuilder
    private var usage: some View {
        if needsApproval, snapshot.state != .pendingApproval {
            Button("Approve") { approve() }
                .buttonStyle(PillButtonStyle(prominent: true))
        } else if let memory = snapshot.memoryBytes {
            HStack(spacing: 7) {
                if !compact {
                    Sparkline(values: history.services[snapshot.id] ?? [], floor: 5)
                        .frame(width: 36, height: 16)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(snapshot.cpuPercent.map(Format.percent) ?? "—")
                    Text(Format.memory(memory))
                }
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.usageSummary ?? "")
        }
    }

    @ViewBuilder
    private var hoverActions: some View {
        if snapshot.state == .external, let port = service.port {
            Button("Kill") { killPort(port) }
                .buttonStyle(QuietButtonStyle())
                .help("Stop the process holding port " + String(port))
        }
        if let url = service.url {
            IconButton(symbol: "globe", help: "Open in browser: " + url) {
                if let target = URL(string: url) { NSWorkspace.shared.open(target) }
            }
            .disabled(!isLive)
        }
        IconButton(symbol: "text.alignleft", help: "Show logs") { route = .logs(service.name) }
        if service.command != nil {
            IconButton(symbol: "arrow.clockwise", help: "Restart") { run(.restart) }
                .disabled(!(snapshot.state.isActive || snapshot.state == .crashed) || snapshot.state == .stopping || !snapshot.approved)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if service.command != nil, snapshot.state != .external {
            if snapshot.state.isActive {
                IconButton(symbol: "stop.fill", help: "Stop " + service.name, size: 26, tint: .secondary, filled: true) { run(.stop) }
                    .disabled(snapshot.state == .stopping)
            } else {
                IconButton(symbol: "play.fill", help: "Start " + service.name, size: 26, tint: Brand.tint, filled: true) { run(.start) }
                    .disabled(!snapshot.approved)
            }
        } else {
            Color.clear.frame(width: 26, height: 26)
        }
    }

    private var moreMenu: some View {
        Menu {
            menuActions
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for " + service.name)
    }

    @ViewBuilder
    private var menuActions: some View {
        Button("Show Logs") { route = .logs(service.name) }
        Button("Edit…") { route = .edit(service.name) }
        if needsApproval {
            Button("Approve Command") { approve() }
        }
        if let url = service.url {
            Button("Open in Browser") {
                if let target = URL(string: url) { NSWorkspace.shared.open(target) }
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        }
        if snapshot.state == .external, let port = service.port {
            Button("Kill Port " + String(port)) { killPort(port) }
        }
        if service.command != nil {
            Divider()
            if snapshot.state.isActive {
                Button("Stop") { run(.stop) }
            } else {
                Button("Start") { run(.start) }
            }
            Button("Restart") { run(.restart) }
                .disabled(!(snapshot.state.isActive || snapshot.state == .crashed) || snapshot.state == .stopping || !snapshot.approved)
        }
        Divider()
        Button("Remove…", role: .destructive) { confirmRemove = true }
    }

    private func run(_ action: ControlRequest.Action) {
        if action == .stop, let onStop { onStop(); return }
        let response = manager.handle(ControlRequest(action: action, name: service.name))
        onError(response.ok ? nil : response.error)
    }

    private func approve() {
        do { try manager.approve(named: service.name) } catch { onError(error.localizedDescription) }
    }

    private func killPort(_ port: Int) {
        let response = manager.handle(ControlRequest(action: .killPort, port: port))
        onError(response.ok ? nil : response.error)
    }
}

struct ApprovalRow: View {
    @EnvironmentObject private var manager: ServiceManager
    let snapshot: ServiceSnapshot
    let onError: (String?) -> Void
    @State private var confirmRemove = false

    var body: some View {
        let s = snapshot.service
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(Tone.warn)
                Text(s.name).font(.system(size: 13, weight: .semibold))
                if let port = s.port { Chip(text: ":" + String(port), monospaced: true) }
                Spacer()
                Text("from the terminal or an AI agent").font(.caption2).foregroundStyle(.secondary)
            }
            // Verbatim: this is text from outside SkyEye, shown exactly as it will run.
            Text(verbatim: s.command ?? "")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .skyWell()
            if let dir = s.directory {
                Label(dir, systemImage: "folder").labelStyle(TightLabelStyle())
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if !s.env.isEmpty {
                Text(verbatim: "env: " + s.env.keys.sorted().map { "\($0)=\(s.env[$0]!)" }.joined(separator: " "))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                Spacer()
                Button("Remove…") { confirmRemove = true }
                    .buttonStyle(PillButtonStyle())
                Button { approve() } label: { Label("Approve", systemImage: "checkmark") }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(11)
        .skyCard(stroke: Tone.warn.opacity(0.45))
        .confirmationDialog("Remove " + s.name + "?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Service", role: .destructive) {
                do { try manager.removeService(named: s.name) } catch { onError(error.localizedDescription) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be stopped and removed from SkyEye. Its log file stays on disk.")
        }
    }

    private func approve() {
        do { try manager.approve(named: snapshot.service.name) } catch { onError(error.localizedDescription) }
    }
}

// MARK: Logs

struct LogView: View {
    @EnvironmentObject private var manager: ServiceManager
    let name: String
    @Binding var route: Route
    @State private var text = ""
    @State private var filter = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var logURL: URL { manager.paths.logFile(for: name) }

    private var lines: [Substring] {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let wanted = filter.trimmingCharacters(in: .whitespaces)
        return wanted.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(wanted) }
    }

    var body: some View {
        let shown = lines
        VStack(spacing: 0) {
            PanelHeader(title: name, back: { route = .list }) {
                if let state = manager.snapshots.first(where: { $0.id == name })?.state {
                    StatusDot(state: state)
                    Text(state.label).font(.caption).foregroundStyle(.secondary)
                }
                CopyButton(text: shown.joined(separator: "\n"), help: "Copy logs")
                IconButton(symbol: "arrow.up.forward.app", help: "Open in Console") { NSWorkspace.shared.open(logURL) }
            }
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Show only lines with…", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !filter.isEmpty {
                    Text("\(shown.count) lines").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    IconButton(symbol: "xmark.circle.fill", help: "Show every line", size: 18) { filter = "" }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .skyWell(radius: 8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? AttributedString("No output yet") : Self.styled(shown))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(height: 390)
                .background(SkyEyeSurface.card)
                .overlay(alignment: .top) { Divider().opacity(0.6) }
                .onChange(of: text) { proxy.scrollTo("bottom") }
                .onAppear { proxy.scrollTo("bottom") }
            }
        }
        .onAppear(perform: load)
        .onReceive(timer) { _ in load() }
    }

    /// Colors the lines that matter.
    private static func styled(_ lines: [Substring]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(String(line) + (index < lines.count - 1 ? "\n" : ""))
            let lower = line.lowercased()
            if line.hasPrefix("=== SkyEye") {
                piece.foregroundColor = Color.secondary
                piece.font = .system(size: 11, weight: .semibold, design: .monospaced)
            } else if line.hasPrefix("$ ") {
                piece.foregroundColor = Brand.tint
            } else if ["error", "fatal", "exception", "panic", "traceback", "failed"].contains(where: lower.contains) {
                piece.foregroundColor = Tone.bad
            } else if lower.contains("warn") {
                piece.foregroundColor = Tone.warn
            }
            result += piece
        }
        return result
    }

    private func load() {
        let fresh = LogTail.stripANSI(ServiceLogs.read(logURL, lines: 400))
        if fresh != text { text = fresh }
    }
}
