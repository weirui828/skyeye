import AppKit
import SkyEyeCore
import SwiftUI

/// Opened explicitly from the menu; closing it leaves the menu bar app running.
@MainActor
final class CanvasWindowController {
    static let shared = CanvasWindowController()
    private var window: NSWindow?

    func show(manager: ServiceManager) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "SkyEye — Dependency Canvas"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DependencyWorkspace().environmentObject(manager))
            window.contentMinSize = NSSize(width: 800, height: 520)
            window.setFrameAutosaveName("SkyEyeDependencyCanvas")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct NodePoint: Codable {
    var x: Double
    var y: Double
    var point: CGPoint { CGPoint(x: x, y: y) }
}

struct DependencyWorkspace: View {
    @EnvironmentObject private var manager: ServiceManager
    @AppStorage("dependencyCanvasPositions") private var savedPositions = Data()
    @AppStorage("dependencyCanvasLayoutVersion") private var layoutVersion = 0
    @State private var positions: [String: NodePoint] = [:]
    @State private var route: Route = .list
    @State private var error: String?
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize(width: 48, height: 48)
    @State private var panOrigin: CGSize?
    @State private var dragOrigins: [String: CGPoint] = [:]
    @State private var connectionSource: String?
    @State private var dropTarget: String?
    @State private var confirmStop: String?
    @State private var stopNames = Set<String>()
    private let cardWidth: CGFloat = 268
    private let cardHeight: CGFloat = 114

    private var topology: [String] {
        manager.config.services.map { $0.name + ":" + $0.dependencies.joined(separator: ",") }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error {
                ErrorBanner(message: error) { self.error = nil }
            } else if let loadError = manager.loadError ?? manager.autoStartError {
                ErrorBanner(message: loadError) { manager.dismissAutoStartError() }
            }
            if let source = connectionSource {
                HStack {
                    Text("Select the service that depends on \(source)")
                    Spacer()
                    Button("Cancel") { connectionSource = nil }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08))
            }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    SkyEyeSurface.background
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if panOrigin == nil { panOrigin = pan }
                            pan = CGSize(width: panOrigin!.width + value.translation.width,
                                         height: panOrigin!.height + value.translation.height)
                        }.onEnded { _ in panOrigin = nil })
                        .onTapGesture { connectionSource = nil }
                    ZStack(alignment: .topLeading) {
                        edges
                            .allowsHitTesting(false)
                        ForEach(manager.snapshots) { snapshot in
                            node(snapshot)
                                .position(center(of: snapshot.service.name))
                        }
                    }
                    .frame(width: graphSize.width, height: graphSize.height, alignment: .topLeading)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(pan)
                    if manager.snapshots.isEmpty {
                        ContentUnavailableView {
                            Label("No services yet", systemImage: "square.stack.3d.up")
                        } description: {
                            Text("Add services, then connect their dependencies.")
                        } actions: {
                            Button("Add service") { route = .edit(nil) }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                // Pin overlays to the viewport, even when the graph extends beyond it.
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 6) {
                        Button { changeZoom(zoom / 1.2, viewport: geometry.size) } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }.help("Zoom out")
                        Text(zoom, format: .percent.precision(.fractionLength(0)))
                            .font(.caption).monospacedDigit().frame(width: 42)
                        Button { changeZoom(zoom * 1.2, viewport: geometry.size) } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }.help("Zoom in")
                        Button("Fit") { fit(in: geometry.size) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(8)
                    .background(SkyEyeSurface.card, in: RoundedRectangle(cornerRadius: 10))
                    .padding(16)
                }
            }
            Divider()
            HStack {
                Text("Dependent ↑ dependency")
                Spacer()
                Text("Drag the canvas to pan · Drag card headers to move · Drag a connector to link")
            }
            .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(minWidth: 800, minHeight: 520)
        .background(SkyEyeSurface.background)
        .onAppear {
            positions = (try? JSONDecoder().decode([String: NodePoint].self, from: savedPositions)) ?? [:]
            arrange(all: layoutVersion < 2)
            layoutVersion = 2
        }
        .onChange(of: topology) { old, new in
            // Reflow only nodes whose prerequisites changed and their downstream dependents.
            let oldSet = Set(old)
            var affected = Set(manager.config.services.filter {
                !oldSet.contains($0.name + ":" + $0.dependencies.joined(separator: ","))
            }.map(\.name))
            var previous = Set<String>()
            while previous != affected {
                previous = affected
                for service in manager.config.services where !affected.isDisjoint(with: service.dependencies) {
                    affected.insert(service.name)
                }
            }
            for name in affected { positions[name] = nil }
            withAnimation(.easeInOut(duration: 0.25)) { arrange(all: false) }
        }
        .sheet(isPresented: Binding(get: { route != .list }, set: { if !$0 { route = .list } })) {
            Group {
                switch route {
                case .edit(let name):
                    ServiceEditorView(original: name.flatMap { manager.service(named: $0) }, route: $route)
                case .logs(let name): LogView(name: name, route: $route)
                case .settings: SettingsView(route: $route)
                case .list: EmptyView()
                }
            }
            .environmentObject(manager)
            .frame(width: 480)
            .padding(.vertical, 8)
        }
        .confirmationDialog("Stop \(confirmStop ?? "service")?", isPresented: Binding(
            get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } }
        ), titleVisibility: .visible) {
            if confirmStop != nil {
                Button("Stop services", role: .destructive) { performStop() }
            }
            Button("Cancel", role: .cancel) { confirmStop = nil }
        } message: {
            Text("Selected services and their active dependents will stop, with dependents first. Shared prerequisites will keep running.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text("SkyEye").font(.headline)
            Text("\(manager.snapshots.filter { $0.state == .running || $0.state == .external }.count)/\(manager.snapshots.count) up")
                .font(.caption).foregroundStyle(.secondary)
            ResourceUsageStatus()
            Spacer()
            Button { route = .edit(nil) } label: { Label("Add service", systemImage: "plus") }
            if !groups.isEmpty {
                Menu("Groups") {
                    ForEach(groups, id: \.self) { group in
                        Menu(group) {
                            Button("Start group") { groupAction(.start, group: group) }
                                .disabled(!manager.snapshots.contains {
                                    $0.service.group == group && $0.service.command != nil && $0.approved
                                        && ($0.state == .stopped || $0.state == .crashed)
                                })
                            Button("Stop group") { groupAction(.stop, group: group) }
                                .disabled(!manager.snapshots.contains {
                                    $0.service.group == group && $0.service.command != nil && $0.state.isActive
                                })
                        }
                    }
                }
            }
            Button { withAnimation { arrange(all: true) } } label: {
                Label("Arrange all", systemImage: "rectangle.3.group")
            }
            Button { route = .settings } label: { Image(systemName: "gearshape") }.help("Settings")
        }
        .buttonStyle(.borderless)
        .padding(16)
    }

    private func node(_ snapshot: ServiceSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(snapshot.service.group ?? "Service").lineLimit(1)
                    .font(.caption).foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                if !snapshot.service.dependencies.isEmpty {
                    Menu {
                        ForEach(snapshot.service.dependencies, id: \.self) { dependency in
                            Button("Remove dependency: " + dependency) { unlink(dependency, from: snapshot.service.name) }
                        }
                    } label: {
                        Label("\(snapshot.service.dependencies.count)", systemImage: "arrow.triangle.branch")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Dependencies; choose one to remove its link")
                }
                Button {
                    if let source = connectionSource {
                        connect(source, to: snapshot.service.name)
                    } else {
                        connectionSource = snapshot.service.name
                    }
                } label: {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .onDrag {
                    connectionSource = snapshot.service.name
                    return NSItemProvider(object: snapshot.service.name as NSString)
                }
                .help(connectionSource.map { "\(snapshot.service.name) depends on \($0)" }
                      ?? "Drag onto a service that depends on \(snapshot.service.name), or click to connect")
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { value in
                        let name = snapshot.service.name
                        if dragOrigins[name] == nil { dragOrigins[name] = positions[name]?.point ?? .zero }
                        let origin = dragOrigins[name]!
                        positions[name] = NodePoint(x: max(0, origin.x + value.translation.width / zoom),
                                                    y: max(0, origin.y + value.translation.height / zoom))
                    }.onEnded { _ in dragOrigins[snapshot.service.name] = nil; persistPositions() })
            }
            ServiceCard(snapshot: snapshot, route: $route, onError: { error = $0 },
                        onStop: { requestStop(snapshot.service.name) })
        }
        .padding(6)
        .frame(width: cardWidth, height: cardHeight, alignment: .top)
        .background(SkyEyeSurface.group, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
            connectionSource == snapshot.service.name || dropTarget == snapshot.service.name ? Color.accentColor : Color.primary.opacity(0.08),
            lineWidth: connectionSource == snapshot.service.name || dropTarget == snapshot.service.name ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            if let source = connectionSource { connect(source, to: snapshot.service.name) }
        }
        .dropDestination(for: String.self) { names, _ in
            guard let source = names.first, manager.service(named: source) != nil else { return false }
            return connect(source, to: snapshot.service.name)
        } isTargeted: { targeted in
            if targeted { dropTarget = snapshot.service.name }
            else if dropTarget == snapshot.service.name { dropTarget = nil }
        }
    }

    private var groups: [String] { Array(Set(manager.config.services.compactMap(\.group))).sorted() }

    private func groupAction(_ action: ControlRequest.Action, group: String) {
        let members = manager.snapshots.filter { $0.service.group == group && $0.service.command != nil }
        if action == .stop {
            stopNames = members.filter { $0.state.isActive }.reduce(into: Set<String>()) {
                $0.formUnion(dependents(of: $1.service.name))
            }
            confirmStop = group + " group"
        } else {
            var failures: [String] = []
            for member in members where member.approved && (member.state == .stopped || member.state == .crashed) {
                do { _ = try manager.start(named: member.service.name) }
                catch { failures.append(error.localizedDescription) }
            }
            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
    }

    private var graphSize: CGSize {
        CGSize(width: max(1000, (positions.values.map(\.x).max() ?? 0) + cardWidth + 80),
               height: max(700, (positions.values.map(\.y).max() ?? 0) + cardHeight + 80))
    }

    private func center(of name: String) -> CGPoint {
        let point = positions[name]?.point ?? .zero
        return CGPoint(x: point.x + cardWidth / 2, y: point.y + cardHeight / 2)
    }

    private var edges: some View {
        Canvas { context, _ in
            for service in manager.config.services {
                for dependency in service.dependencies {
                    let from = center(of: dependency)
                    let to = center(of: service.name)
                    let start = CGPoint(x: from.x, y: from.y - cardHeight / 2)
                    let end = CGPoint(x: to.x, y: to.y + cardHeight / 2 + 3)
                    let bend = max(45, abs(end.y - start.y) * 0.5)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y - bend),
                                  control2: CGPoint(x: end.x, y: end.y + bend))
                    context.stroke(path, with: .color(.secondary.opacity(0.6)), lineWidth: 1.7)
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: end.x - 4, y: end.y + 8))
                    arrow.addLine(to: end)
                    arrow.addLine(to: CGPoint(x: end.x + 4, y: end.y + 8))
                    context.stroke(arrow, with: .color(.secondary), lineWidth: 1.7)
                }
            }
        }
        .accessibilityLabel("Dependencies sit below their dependents; arrows point upward. Each service lists its prerequisites in its dependency menu.")
    }

    private func arrange(all: Bool) {
        do {
            let levels = try ServiceGraph.levels(manager.config.services)
            let maxLevel = levels.values.max() ?? 0
            let names = Set(manager.config.services.map(\.name))
            positions = positions.filter { names.contains($0.key) }
            if all { positions.removeAll() }
            let ordered = try ServiceGraph.order(manager.config.services)
            for name in ordered where positions[name] == nil {
                var x = 0.0
                let y = Double(maxLevel - (levels[name] ?? 0)) * (cardHeight + 100)
                while positions.values.contains(where: {
                    abs($0.x - x) < cardWidth + 28 && abs($0.y - y) < cardHeight + 24
                }) { x += cardWidth + 60 }
                positions[name] = NodePoint(x: x, y: y)
            }
            persistPositions()
        } catch { self.error = error.localizedDescription }
    }

    private func persistPositions() {
        if let data = try? JSONEncoder().encode(positions) { savedPositions = data }
    }

    private func changeZoom(_ value: CGFloat, viewport: CGSize) {
        let next = min(1.6, max(0.1, value))
        let ratio = next / zoom
        pan = CGSize(width: viewport.width / 2 - (viewport.width / 2 - pan.width) * ratio,
                     height: viewport.height / 2 - (viewport.height / 2 - pan.height) * ratio)
        zoom = next
    }

    private func fit(in viewport: CGSize) {
        let width = (positions.values.map(\.x).max() ?? 0) + cardWidth
        let height = (positions.values.map(\.y).max() ?? 0) + cardHeight
        zoom = min(1.2, max(0.1, min((viewport.width - 96) / width, (viewport.height - 96) / height)))
        pan = CGSize(width: (viewport.width - width * zoom) / 2, height: (viewport.height - height * zoom) / 2)
    }

    @discardableResult private func connect(_ dependency: String, to name: String) -> Bool {
        defer { connectionSource = nil }
        guard var service = manager.service(named: name) else { return false }
        guard !service.dependencies.contains(dependency) else { return true }
        service.dependencies.append(dependency)
        do {
            _ = try manager.updateService(named: name, to: service, trusted: false)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    private func unlink(_ dependency: String, from name: String) {
        guard var service = manager.service(named: name) else { return }
        service.dependencies.removeAll { $0 == dependency }
        do { _ = try manager.updateService(named: name, to: service, trusted: false) }
        catch { self.error = error.localizedDescription }
    }

    private func dependents(of name: String) -> Set<String> {
        var names: Set<String> = [name]
        var previous = Set<String>()
        while previous != names {
            previous = names
            for service in manager.config.services where !names.isDisjoint(with: service.dependencies) {
                names.insert(service.name)
            }
        }
        return names
    }

    private func requestStop(_ name: String) {
        let names = dependents(of: name).subtracting([name])
        if manager.snapshots.contains(where: { names.contains($0.service.name) && $0.state.isActive }) {
            stopNames = dependents(of: name)
            confirmStop = name
        } else {
            let response = manager.handle(ControlRequest(action: .stop, name: name))
            error = response.ok ? nil : response.error
        }
    }

    private func performStop() {
        let order = (try? ServiceGraph.order(manager.config.services)) ?? []
        var failures: [String] = []
        for target in order.reversed() where stopNames.contains(target) {
            guard manager.snapshots.contains(where: { $0.service.name == target && $0.state.isActive }) else { continue }
            do { _ = try manager.stop(named: target) } catch { failures.append(error.localizedDescription) }
        }
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        confirmStop = nil
        stopNames.removeAll()
    }
}
