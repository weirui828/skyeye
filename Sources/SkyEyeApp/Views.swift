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

struct MenuContentView: View {
    @EnvironmentObject private var manager: ServiceManager
    @State private var route: Route = .list

    var body: some View {
        Group {
            switch route {
            case .list: ServiceListView(route: $route)
            case .edit(let name): ServiceEditorView(original: name.flatMap { manager.service(named: $0) }, route: $route)
            case .logs(let name): LogView(name: name, route: $route)
            case .settings: SettingsView(route: $route)
            }
        }
        .frame(width: route == .settings ? 480 : 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(SkyEyeSurface.background.ignoresSafeArea())
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

/// Opaque surfaces keep light mode bright without picking up the desktop's tint.
/// Dynamic colors continue to follow the system appearance.
enum SkyEyeSurface {
    static let background = adaptive(light: 0.985, dark: 0.12)
    static let card = adaptive(light: 1.0, dark: 0.17)
    static let group = adaptive(light: 0.965, dark: 0.145)

    private static func adaptive(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}

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
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .padding(.horizontal, 5)
    }
}

extension View {
    func menuHighlight() -> some View { modifier(MenuHighlight()) }
}

extension ServiceState {
    var color: Color {
        switch self {
        case .running: .green
        case .starting, .stopping: .yellow
        case .unhealthy, .pendingApproval: .orange
        case .crashed: .red
        case .external: .purple
        case .stopped: .secondary.opacity(0.5)
        }
    }
}

struct StatusDot: View {
    let state: ServiceState

    var body: some View {
        ZStack {
            if state == .starting || state == .stopping {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
            } else {
                Circle().fill(state.color)
            }
        }
        .frame(width: 9, height: 9)
        .accessibilityLabel(state.label)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Copies text and briefly shows a checkmark so the copy is visible.
struct CopyButton: View {
    let text: String
    var help: String = "Copy"
    @State private var copied = false

    var body: some View {
        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : help) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
        .foregroundStyle(copied ? Color.green : Color.primary)
    }
}

/// Small uppercase heading used to group rows and settings.
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// A shared, alternating resource badge for both interfaces.
struct ResourceUsageStatus: View {
    @EnvironmentObject private var manager: ServiceManager
    @State private var heldScope: Scope?

    private enum Scope: Int {
        case computer, skyEye, services
        var tooltip: String {
            switch self {
            case .computer: "Whole computer"
            case .skyEye: "SkyEye app"
            case .services: "Running services"
            }
        }
    }

    private static let telescope: NSImage = {
        let image = NSImage(contentsOf: Bundle.main.url(forResource: "Telescope", withExtension: "pdf")!)!
        image.isTemplate = true
        return image
    }()

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 5)) { context in
            let scope = heldScope ?? Scope(rawValue: Int(context.date.timeIntervalSinceReferenceDate / 5) % 3)!
            let text = summary(for: scope)
            let highMemory = scope == .computer && manager.systemUsage.map {
                $0.memoryTotal > 0 && Double($0.memoryUsed) / Double($0.memoryTotal) > 0.9
            } == true
            HStack(spacing: 5) {
                Group {
                    switch scope {
                    case .computer: Image(systemName: "laptopcomputer")
                    case .skyEye: Image(nsImage: Self.telescope).resizable().scaledToFit()
                    case .services: Image(systemName: "square.stack.3d.up")
                    }
                }
                .frame(width: 14, height: 14)
                Text(text)
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: 184, alignment: .leading)
            .foregroundStyle(highMemory ? Color.orange : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(scope.tooltip + ": " + text)
            .help(scope.tooltip)
            .onHover { hovering in heldScope = hovering ? scope : nil }
        }
    }

    private func summary(for scope: Scope) -> String {
        switch scope {
        case .computer: manager.systemUsage?.summary ?? "CPU — · —"
        case .skyEye: manager.skyEyeUsage?.summary ?? "CPU — · —"
        case .services: manager.servicesUsage?.summary ?? "CPU — · —"
        }
    }
}

struct PanelHeader<Trailing: View>: View {
    let title: String
    var back: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            if let back {
                IconButton(symbol: "chevron.left", help: "Back", action: back)
            }
            Text(title).font(.headline).lineLimit(1)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", help: "Dismiss", action: dismiss)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: List

struct ServiceListView: View {
    @EnvironmentObject private var manager: ServiceManager
    @Binding var route: Route
    @State private var error: String?

    private struct Section: Identifiable {
        let group: String?
        let items: [ServiceSnapshot]
        var id: String { group.map { "g:" + $0 } ?? "ungrouped" }
    }

    /// Groups in the order they first appear in the config, so the user's order is respected.
    private var sections: [Section] {
        let regular = manager.snapshots.filter { $0.state != .pendingApproval }
        var order: [String?] = []
        for s in regular where !order.contains(s.service.group) { order.append(s.service.group) }
        return order.map { g in Section(group: g, items: regular.filter { $0.service.group == g }) }
    }

    private var upCount: Int {
        manager.snapshots.filter { $0.state == .running || $0.state == .external }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "SkyEye") {
                ResourceUsageStatus()
                if !manager.snapshots.isEmpty {
                    Text(String(upCount) + "/" + String(manager.snapshots.count) + " up")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(upCount == manager.snapshots.count ? Color.secondary : Color.orange)
                        .help("Services running, including ones started outside SkyEye")
                        .accessibilityLabel(String(upCount) + " of " + String(manager.snapshots.count) + " services running")
                }
                IconButton(symbol: "gearshape", help: "Settings") { route = .settings }
            }
            MenuDivider()
            if let message = error ?? manager.loadError ?? manager.autoStartError {
                ErrorBanner(message: message) { error = nil; manager.dismissAutoStartError() }
                MenuDivider()
            }
            HStack {
                Button {
                    CanvasWindowController.shared.show(manager: manager)
                } label: {
                    Label("Canvas", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Open dependency canvas")
                Spacer()
                Button { route = .edit(nil) } label: {
                    Label("Add service", systemImage: "plus")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if manager.snapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        let pending = manager.snapshots.filter { $0.state == .pendingApproval }
                        if !pending.isEmpty {
                            sectionTitle("Needs your approval")
                            ForEach(pending) { ApprovalRow(snapshot: $0, onError: { error = $0 }) }
                        }
                        ForEach(sections) { section in
                            if let group = section.group, section.items.count > 1 {
                                VStack(spacing: 8) {
                                    GroupHeader(group: group, items: section.items, onError: { error = $0 })
                                    ForEach(section.items) { snapshot in
                                        ServiceCard(snapshot: snapshot, route: $route, onError: { error = $0 })
                                    }
                                }
                                .padding(9)
                                .background(SkyEyeSurface.group, in: RoundedRectangle(cornerRadius: 13))
                                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.07)))
                            } else {
                                ForEach(section.items) { snapshot in
                                    ServiceCard(snapshot: snapshot, route: $route, onError: { error = $0 })
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            }
            MenuDivider()
            footer
        }
    }

    private var footer: some View {
        let keepRunning = manager.config.settings.keepRunningOnQuit
        let active = manager.activeCount
        return Button { NSApp.terminate(nil) } label: {
            HStack(spacing: 6) {
                Text("Quit")
                Spacer()
                if active > 0 {
                    Text(keepRunning ? "Services keep running" : "Stops " + String(active) + (active == 1 ? " service" : " services"))
                        .foregroundStyle(keepRunning ? Color.secondary : Color.orange)
                }
                Text("⌘Q").foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
        .menuHighlight()
        .padding(.bottom, 5)
        .help(active > 0 && !keepRunning ? "Stops the running services first" : "")
    }

    @ViewBuilder
    private func sectionTitle(_ title: String) -> some View {
        SectionTitle(text: title)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.aperture").font(.largeTitle).foregroundStyle(.tertiary)
            Text("No services yet").font(.headline)
            Text("Add one here, run `sky add` in a terminal,\nor ask your coding agent through MCP.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct GroupHeader: View {
    @EnvironmentObject private var manager: ServiceManager
    let group: String
    let items: [ServiceSnapshot]
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

    var body: some View {
        HStack(spacing: 6) {
            Text(group).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(String(upCount) + "/" + String(items.count))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(upCount == items.count ? Color.secondary : Color.orange)
                .help(String(upCount) + " of " + String(items.count) + " running")
                .accessibilityLabel(String(upCount) + " of " + String(items.count) + " services running")
            Spacer()
            if !startable.isEmpty {
                Button { run(.start, items: startable) } label: {
                    Label("Start all", systemImage: "play.fill")
                }
                .disabled(transitioning)
            }
            if !manageableActive.isEmpty {
                Button { run(.stop, items: manageableActive) } label: {
                    Label("Stop all", systemImage: "stop.fill")
                }
                .disabled(transitioning)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
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
    @EnvironmentObject private var manager: ServiceManager
    let snapshot: ServiceSnapshot
    @Binding var route: Route
    let onError: (String?) -> Void
    var onStop: (() -> Void)? = nil
    @State private var hovering = false
    @State private var confirmRemove = false

    private var service: ServiceConfig { snapshot.service }

    private var isLive: Bool {
        [.running, .unhealthy, .starting, .external].contains(snapshot.state)
    }

    private var subtitle: String {
        var text: String
        switch snapshot.state {
        case .running:
            text = snapshot.usageSummary ?? "running"
        case .pendingApproval:
            text = "command needs approval in the menu bar"
        case .external:
            if let detail = snapshot.detail, !detail.isEmpty {
                text = "running outside SkyEye — " + detail
            } else {
                text = "running outside SkyEye"
            }
        default:
            if let detail = snapshot.detail, !detail.isEmpty {
                text = snapshot.state.label + " — " + detail
            } else {
                text = snapshot.state.label
            }
        }
        if !snapshot.approved, service.command != nil, snapshot.state != .pendingApproval {
            text += " · new command needs approval"
        }
        return text
    }

    private var placeholder: some View {
        Color.clear.frame(width: 22, height: 22)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                nameLabel
                Spacer(minLength: 4)
                StatusDot(state: snapshot.state)
                Text(snapshot.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let port = service.port {
                    Text(":" + String(port))
                        .monospacedDigit()
                }
                Text(subtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(subtitle)
            .opacity(hovering ? 0 : 1)
            .overlay(alignment: .trailing) {
                HStack(spacing: 3) {
                    if !snapshot.approved, service.command != nil {
                        Button("Approve") { approve() }
                            .controlSize(.small)
                    }
                    hoverActions
                    primaryAction
                    moreMenu
                }
                .padding(.leading, 6)
                .background(SkyEyeSurface.card, in: RoundedRectangle(cornerRadius: 6))
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(minHeight: 24)
        }
        .padding(12)
        .background(SkyEyeSurface.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(hovering ? 0.18 : 0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .help([service.command, snapshot.pid.map { "pid " + String($0) }].compactMap { $0 }.joined(separator: "\n"))
        .contextMenu { menuActions }
        .confirmationDialog("Remove " + service.name + "?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Service", role: .destructive) {
                do { try manager.removeService(named: service.name) } catch { onError(error.localizedDescription) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be stopped and removed from SkyEye. Its log file stays on disk.")
        }
    }

    @ViewBuilder
    private var nameLabel: some View {
        if let url = service.url, isLive, let target = URL(string: url) {
            Button {
                NSWorkspace.shared.open(target)
            } label: {
                Text(service.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open " + url)
        } else {
            Text(service.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
    }

    @ViewBuilder
    private var hoverActions: some View {
        if let url = service.url {
            IconButton(symbol: "globe", help: "Open in browser: " + url) {
                if let target = URL(string: url) { NSWorkspace.shared.open(target) }
            }
            .disabled(!isLive)
        }
        IconButton(symbol: "terminal", help: "Show logs") { route = .logs(service.name) }
        if service.command != nil {
            IconButton(symbol: "arrow.clockwise", help: "Restart") { run(.restart) }
                .disabled(!(snapshot.state.isActive || snapshot.state == .crashed) || snapshot.state == .stopping || !snapshot.approved)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if snapshot.state == .external, let port = service.port {
            Button("Kill") { killPort(port) }
                .controlSize(.small)
                .help("Stop the process holding port " + String(port))
        } else if service.command != nil {
            if snapshot.state.isActive {
                IconButton(symbol: "stop.fill", help: "Stop") { run(.stop) }
                    .disabled(snapshot.state == .stopping)
            } else {
                IconButton(symbol: "play.fill", help: "Start") { run(.start) }
                    .disabled(!snapshot.approved)
            }
        } else {
            placeholder
        }
    }

    private var moreMenu: some View {
        Menu {
            menuActions
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 22, height: 22)
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
        if !snapshot.approved, service.command != nil {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield").foregroundStyle(.orange)
                Text(s.name).font(.system(size: 13, weight: .semibold))
                if let port = s.port { Text(":\(String(port))").foregroundStyle(.secondary) }
                Spacer()
            }
            Text(s.command ?? "")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            if let dir = s.directory {
                Label(dir, systemImage: "folder").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if !s.env.isEmpty {
                Text("env: " + s.env.keys.sorted().map { "\($0)=\(s.env[$0]!)" }.joined(separator: " "))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Text("Added from the terminal or an AI agent").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Remove…") { confirmRemove = true }
                Button("Approve") {
                    do { try manager.approve(named: s.name) } catch { onError(error.localizedDescription) }
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .confirmationDialog("Remove " + s.name + "?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Service", role: .destructive) {
                do { try manager.removeService(named: s.name) } catch { onError(error.localizedDescription) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be stopped and removed from SkyEye. Its log file stays on disk.")
        }
    }
}

// MARK: Logs

struct LogView: View {
    @EnvironmentObject private var manager: ServiceManager
    let name: String
    @Binding var route: Route
    @State private var text = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var logURL: URL { manager.paths.logFile(for: name) }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "\(name) logs", back: { route = .list }) {
                CopyButton(text: text, help: "Copy logs")
                IconButton(symbol: "arrow.up.forward.app", help: "Open in Console") { NSWorkspace.shared.open(logURL) }
            }
            MenuDivider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "(no output yet)" : text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(height: 400)
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: text) { proxy.scrollTo("bottom") }
                .onAppear { proxy.scrollTo("bottom") }
            }
        }
        .onAppear(perform: load)
        .onReceive(timer) { _ in load() }
    }

    private func load() {
        let fresh = LogTail.stripANSI(ServiceLogs.read(logURL, lines: 400))
        if fresh != text { text = fresh }
    }
}
