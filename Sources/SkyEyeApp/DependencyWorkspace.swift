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
            window.contentView = NSHostingView(
                rootView: DependencyWorkspace().environmentObject(manager).defaultAppStorage(Preferences.store)
            )
            window.contentMinSize = NSSize(width: 800, height: 520)
            window.center()
            if !Preferences.isCustomHome { window.setFrameAutosaveName("SkyEyeDependencyCanvas") }
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

private struct ConnectionDrag {
    var source: String
    var location: CGPoint
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
    @GestureState private var connectionDrag: ConnectionDrag?
    @State private var confirmStop: String?
    @State private var stopNames = Set<String>()
    /// The size of the canvas, and whether the user has moved or zoomed it.
    @State private var viewport = CGSize.zero
    @State private var userMovedView = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let cardWidth: CGFloat = 296
    private let cardHeight: CGFloat = 88
    /// Distance between rows and between columns of the automatic layout.
    private let rowPitch: CGFloat = 196
    private let columnPitch: CGFloat = 336
    /// Where the connector sits on a card, from the card's top-left corner.
    private var connectorOffset: CGSize { CGSize(width: cardWidth - 21, height: 16) }

    private var topology: [String] {
        manager.config.services.map { $0.name + ":" + $0.dependencies.joined(separator: ",") }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.7)
            if let error {
                ErrorBanner(message: error) { self.error = nil }
            } else if let loadError = manager.loadError ?? manager.autoStartError {
                ErrorBanner(message: loadError) { manager.dismissAutoStartError() }
            }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    grid
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if panOrigin == nil { panOrigin = pan }
                            userMovedView = true
                            pan = CGSize(width: panOrigin!.width + value.translation.width,
                                         height: panOrigin!.height + value.translation.height)
                        }.onEnded { _ in panOrigin = nil })
                        .onTapGesture { connectionSource = nil }
                    edges
                        .allowsHitTesting(false)
                    ForEach(manager.snapshots) { snapshot in
                        node(snapshot)
                            .scaleEffect(zoom)
                            .frame(width: cardWidth * zoom, height: cardHeight * zoom)
                            .position(viewportPoint(center(of: snapshot.service.name)))
                    }
                    if manager.snapshots.isEmpty {
                        VStack(spacing: 10) {
                            BrandMark(size: 56)
                            Text("Nothing to connect yet").font(.title3.weight(.semibold)).padding(.top, 4)
                            Text("Add services, then draw a line from each one to the services that need it.")
                                .foregroundStyle(.secondary)
                            Button { route = .edit(nil) } label: { Label("Add a service", systemImage: "plus") }
                                .buttonStyle(PillButtonStyle(prominent: true))
                                .padding(.top, 2)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                // Pin overlays to the viewport, even when the graph extends beyond it.
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .coordinateSpace(name: "dependencyViewport")
                .clipped()
                .overlay(alignment: .top) {
                    if let source = connectionSource {
                        HStack(spacing: 10) {
                            Image(systemName: "link").foregroundStyle(Brand.tint)
                            Text("Now select the service that needs \(source)").font(.callout.weight(.medium))
                            Button("Cancel") { connectionSource = nil }.buttonStyle(PillButtonStyle())
                        }
                        .padding(.leading, 14)
                        .padding(.trailing, 6)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Brand.tint.opacity(0.5)))
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.18), value: connectionSource)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 2) {
                        IconButton(symbol: "minus", help: "Zoom out", size: 26) { changeZoom(zoom / 1.2, viewport: geometry.size) }
                        Text(zoom, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 40)
                        IconButton(symbol: "plus", help: "Zoom in", size: 26) { changeZoom(zoom * 1.2, viewport: geometry.size) }
                        Divider().frame(height: 14).padding(.horizontal, 3)
                        IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit everything in the window", size: 26) {
                            withAnimation(.easeInOut(duration: 0.25)) { fit(in: geometry.size) }
                            userMovedView = false
                        }
                    }
                    .padding(4)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(SkyEyeSurface.hairline))
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
                    .padding(16)
                }
                .overlay(alignment: .bottomTrailing) { legend.padding(16) }
                .onAppear {
                    viewport = geometry.size
                    if !userMovedView { fit(in: geometry.size) }
                }
                .onChange(of: geometry.size) { _, size in
                    viewport = size
                    if !userMovedView { fit(in: size) }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 520)
        .background(SkyEyeSurface.background)
        .onAppear {
            positions = (try? JSONDecoder().decode([String: NodePoint].self, from: savedPositions)) ?? [:]
            if layoutVersion == 2, let levels = try? ServiceGraph.levels(manager.config.services) {
                // Version 2 measured rows from the top row. Version 3 measures them from the bottom row.
                let shift = Double(levels.values.max() ?? 0) * 214
                for name in positions.keys { positions[name]!.y -= shift }
            }
            arrange(all: layoutVersion < 2)
            layoutVersion = 3
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
            withAnimation(.easeInOut(duration: 0.25)) {
                arrange(all: false)
                if !userMovedView, viewport != .zero { fit(in: viewport) }
            }
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
            .padding(.vertical, 4)
            .background(alignment: .top) { Brand.wash.frame(height: 140) }
            .background(SkyEyeSurface.background)
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
        let up = manager.snapshots.filter { $0.state == .running || $0.state == .external }.count
        let total = manager.snapshots.count
        return HStack(spacing: 10) {
            BrandMark(size: 26)
            Text("Dependencies").font(.system(size: 15, weight: .semibold))
            if total > 0 {
                Chip(text: up == total ? "All \(total) running" : "\(up) of \(total) running",
                     tint: up == total ? Tone.good : .secondary)
            }
            ResourceUsageStatus()
            Spacer()
            if !groups.isEmpty {
                Menu {
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
                } label: {
                    Label("Groups", systemImage: "square.stack.3d.up")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Start or stop a whole group")
            }
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    arrange(all: true)
                    if viewport != .zero { fit(in: viewport) }
                    userMovedView = false
                }
            } label: {
                Label("Arrange", systemImage: "rectangle.3.group")
            }
            .help("Put every card back in its automatic place")
            Button { route = .edit(nil) } label: { Label("Add service", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut("n")
            IconButton(symbol: "gearshape", help: "Settings", size: 28, filled: true) { route = .settings }
        }
        .buttonStyle(PillButtonStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(alignment: .top) { Brand.wash.frame(height: 90) }
    }

    /// A faint grid of dots that moves and scales with the cards, so panning and zooming can be felt.
    private var grid: some View {
        Canvas { context, size in
            var spacing = 28 * zoom
            while spacing < 16 { spacing *= 2 }
            let startX = pan.width.truncatingRemainder(dividingBy: spacing)
            let startY = pan.height.truncatingRemainder(dividingBy: spacing)
            var dots = Path()
            var y = startY - spacing
            while y < size.height + spacing {
                var x = startX - spacing
                while x < size.width + spacing {
                    dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(.primary.opacity(0.10)))
        }
        .background(SkyEyeSurface.background)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("in use", color: Tone.good, dash: [1, 5])
            legendItem("idle", color: Tone.idle, dash: [])
            legendItem("dependency down", color: Tone.bad, dash: [4, 4])
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SkyEyeSurface.hairline))
        .help("A line runs from a dependency up to the service that needs it.\nDrag the background to move around. Drag a card by its top to move it.\nDrag a card's link button onto the service that needs it.")
    }

    private func legendItem(_ label: String, color: Color, dash: [CGFloat]) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 1, y: 4))
                path.addLine(to: CGPoint(x: 21, y: 4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
            .frame(width: 22, height: 8)
            Text(label)
        }
    }

    /// A stable color for a group, so its cards can be picked out across the canvas.
    private func groupColor(_ group: String?) -> Color {
        guard let group, !group.isEmpty else { return Tone.idle }
        let palette: [Color] = [
            .adaptive(light: (0.16, 0.47, 0.84), dark: (0.36, 0.60, 0.95)),
            .adaptive(light: (0.92, 0.41, 0.20), dark: (0.96, 0.52, 0.30)),
            .adaptive(light: (0.11, 0.69, 0.48), dark: (0.20, 0.76, 0.56)),
            .adaptive(light: (0.38, 0.31, 0.84), dark: (0.60, 0.55, 0.96)),
            .adaptive(light: (0.91, 0.48, 0.64), dark: (0.93, 0.50, 0.68)),
            .adaptive(light: (0.93, 0.63, 0.0), dark: (0.95, 0.70, 0.20)),
        ]
        let sum = group.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }
        return palette[sum % palette.count]
    }

    private func node(_ snapshot: ServiceSnapshot) -> some View {
        let name = snapshot.service.name
        let isEnd = (connectionDrag?.source ?? connectionSource) == name || connectionTarget == name
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(groupColor(snapshot.service.group)).frame(width: 7, height: 7)
                Text(snapshot.service.group ?? "No group").lineLimit(1)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                if !snapshot.service.dependencies.isEmpty {
                    Menu {
                        Section("\(name) needs") {
                            ForEach(snapshot.service.dependencies, id: \.self) { dependency in
                                Button("Remove " + dependency) { unlink(dependency, from: name) }
                            }
                        }
                    } label: {
                        Label("\(snapshot.service.dependencies.count)", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("What \(name) needs. Choose one to remove its link.")
                }
                Image(systemName: "link")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(connectionSource == name ? Color.white : Brand.tint)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(connectionSource == name ? Brand.tint : Brand.tint.opacity(0.13)))
                    .contentShape(Circle())
                    .highPriorityGesture(
                        connectionGesture(from: name)
                            .exclusively(before: TapGesture().onEnded { selectConnector(name) })
                    )
                    .accessibilityLabel("Connect " + name)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { selectConnector(name) }
                    .help(connectionSource.map { "\(name) needs \($0)" }
                          ?? "Drag onto a service that needs \(name), or click and then click that service")
            }
            .padding(.leading, 11)
            .padding(.trailing, 6)
            .frame(height: 32)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .named("dependencyViewport")).onChanged { value in
                        if dragOrigins[name] == nil { dragOrigins[name] = positions[name]?.point ?? .zero }
                        let origin = dragOrigins[name]!
                        positions[name] = NodePoint(x: origin.x + value.translation.width / zoom,
                                                    y: origin.y + value.translation.height / zoom)
                    }.onEnded { _ in dragOrigins[name] = nil; persistPositions() })
            }
            Divider().opacity(0.6)
            ServiceCard(snapshot: snapshot, route: $route, onError: { error = $0 },
                        onStop: { requestStop(name) }, style: .row, compact: true)
                .padding(.vertical, 2)
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .top)
        .skyCard(radius: 14, stroke: isEnd ? Brand.tint : SkyEyeSurface.hairline, lineWidth: isEnd ? 2 : 1)
        .shadow(color: .black.opacity(dragOrigins[name] == nil ? 0.05 : 0.16), radius: dragOrigins[name] == nil ? 5 : 14, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            if let source = connectionSource, source != name {
                connect(source, to: name)
            }
        }
    }

    private func selectConnector(_ name: String) {
        if let source = connectionSource {
            if source == name { connectionSource = nil }
            else { connect(source, to: name) }
        } else {
            connectionSource = name
        }
    }

    private var connectionTarget: String? {
        guard let drag = connectionDrag else { return nil }
        return connectionTarget(at: drag.location, excluding: drag.source)
    }

    private func connectionTarget(at point: CGPoint, excluding source: String) -> String? {
        // Use graph coordinates so hit testing follows the same zoom and pan as the cards.
        manager.snapshots.reversed().first { snapshot in
            guard snapshot.service.name != source,
                  let origin = positions[snapshot.service.name]?.point else { return false }
            return CGRect(origin: origin, size: CGSize(width: cardWidth, height: cardHeight)).contains(point)
        }?.service.name
    }

    private func connectionGesture(from source: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("dependencyViewport"))
            .updating($connectionDrag) { value, state, _ in
                state = ConnectionDrag(source: source, location: graphPoint(value.location))
            }
            .onEnded { value in
                connectionSource = nil
                if let target = connectionTarget(at: graphPoint(value.location), excluding: source) {
                    connect(source, to: target)
                }
            }
    }

    private var groups: [String] {
        Array(Set(manager.config.services.compactMap(\.group))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

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

    private var graphBounds: CGRect {
        positions.values.reduce(CGRect.null) { bounds, point in
            bounds.union(CGRect(origin: point.point, size: CGSize(width: cardWidth, height: cardHeight)))
        }
    }

    private func viewportPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + pan.width, y: point.y * zoom + pan.height)
    }

    private func graphPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.width) / zoom, y: (point.y - pan.height) / zoom)
    }

    private func center(of name: String) -> CGPoint {
        let point = positions[name]?.point ?? .zero
        return CGPoint(x: point.x + cardWidth / 2, y: point.y + cardHeight / 2)
    }

    private enum Flow { case live, idle, broken }

    private func flow(from dependency: ServiceState?, to dependent: ServiceState?) -> Flow {
        let up: Set<ServiceState> = [.running, .external]
        let wants: Set<ServiceState> = [.running, .starting, .unhealthy, .external]
        guard let dependency, let dependent else { return .idle }
        if up.contains(dependency) { return wants.contains(dependent) ? .live : .idle }
        return wants.contains(dependent) ? .broken : .idle
    }

    private var edges: some View {
        let states = Dictionary(uniqueKeysWithValues: manager.snapshots.map { ($0.service.name, $0.state) })
        let links: [(from: String, to: String, flow: Flow)] = manager.config.services.flatMap { service in
            service.dependencies.map { ($0, service.name, flow(from: states[$0], to: states[service.name])) }
        }
        let moving = !reduceMotion && links.contains { $0.flow == .live }
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
            Canvas { context, _ in
                context.translateBy(x: pan.width, y: pan.height)
                context.scaleBy(x: zoom, y: zoom)
                let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)) * 22
                for link in links.sorted(by: { $0.flow == .idle && $1.flow != .idle }) {
                    let from = center(of: link.from)
                    let to = center(of: link.to)
                    let start = CGPoint(x: from.x, y: from.y - cardHeight / 2)
                    let end = CGPoint(x: to.x, y: to.y + cardHeight / 2 + 7)
                    let bend = max(45, abs(end.y - start.y) * 0.5)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y - bend),
                                  control2: CGPoint(x: end.x, y: end.y + bend))
                    let color: Color
                    switch link.flow {
                    case .live:
                        color = Tone.good
                        context.stroke(path, with: .color(color.opacity(0.28)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        context.stroke(path, with: .color(color), style: StrokeStyle(
                            lineWidth: 2.6, lineCap: .round, dash: [0.1, 11], dashPhase: moving ? -phase : 0
                        ))
                    case .idle:
                        color = Tone.idle
                        context.stroke(path, with: .color(color.opacity(0.75)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    case .broken:
                        color = Tone.bad
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
                    }
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: end.x, y: end.y - 6))
                    arrow.addLine(to: CGPoint(x: end.x - 5, y: end.y + 3))
                    arrow.addLine(to: CGPoint(x: end.x + 5, y: end.y + 3))
                    arrow.closeSubpath()
                    context.fill(arrow, with: .color(color))
                    context.fill(Path(ellipseIn: CGRect(x: start.x - 3.5, y: start.y - 3.5, width: 7, height: 7)), with: .color(color))
                }
                if let drag = connectionDrag {
                    let origin = positions[drag.source]?.point ?? .zero
                    let start = CGPoint(x: origin.x + connectorOffset.width, y: origin.y + connectorOffset.height)
                    var preview = Path()
                    preview.move(to: start)
                    preview.addLine(to: drag.location)
                    context.stroke(preview, with: .color(Brand.tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
                    let marker = CGRect(x: drag.location.x - 5, y: drag.location.y - 5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: marker), with: .color(Brand.tint))
                }
            }
        }
        .accessibilityLabel("Dependencies sit below the services that need them; lines run upward. Each service lists what it needs in its dependency menu.")
    }

    private func arrange(all: Bool) {
        do {
            let levels = try ServiceGraph.levels(manager.config.services)
            let names = Set(manager.config.services.map(\.name))
            positions = positions.filter { names.contains($0.key) }
            if all { positions.removeAll() }
            let dependencies = Dictionary(uniqueKeysWithValues: manager.config.services.map { ($0.name, $0.dependencies) })
            let ordered = try ServiceGraph.order(manager.config.services)
            let needed = Set(manager.config.services.flatMap(\.dependencies))
            let alone = Set(ordered.filter { (dependencies[$0] ?? []).isEmpty && !needed.contains($0) })
            func isTaken(_ x: Double, _ y: Double) -> Bool {
                positions.values.contains { abs($0.x - x) < cardWidth + 28 && abs($0.y - y) < cardHeight + 24 }
            }
            for name in ordered where positions[name] == nil && !alone.contains(name) {
                let y = -Double(levels[name] ?? 0) * rowPitch
                let below = (dependencies[name] ?? []).compactMap { positions[$0]?.x }
                let wanted = below.isEmpty ? 0 : ((below.reduce(0, +) / Double(below.count)) / columnPitch).rounded()
                var x = wanted * columnPitch
                for step in 0..<200 {
                    let offset = Double((step + 1) / 2) * (step.isMultiple(of: 2) ? -1 : 1)
                    x = (wanted + (below.isEmpty ? Double(step) : offset)) * columnPitch
                    if !isTaken(x, y) { break }
                }
                positions[name] = NodePoint(x: x, y: y)
            }
            let linked = positions.filter { !alone.contains($0.key) }.values
            let left = linked.map(\.x).min() ?? 0
            let perRow = max(3, Int((((linked.map(\.x).max() ?? 0) - left) / columnPitch).rounded()) + 1)
            let top = linked.isEmpty ? 0 : cardHeight + 64
            for name in ordered where positions[name] == nil {
                var slot = 0
                var x = left
                var y = top
                while slot < 400 {
                    x = left + Double(slot % perRow) * columnPitch
                    y = top + Double(slot / perRow) * (cardHeight + 30)
                    if !isTaken(x, y) { break }
                    slot += 1
                }
                positions[name] = NodePoint(x: x, y: y)
            }
            persistPositions()
        } catch { self.error = error.localizedDescription }
    }

    private func persistPositions() {
        if let data = try? JSONEncoder().encode(positions) { savedPositions = data }
    }

    private func changeZoom(_ value: CGFloat, viewport: CGSize) {
        userMovedView = true
        let next = min(1.6, max(0.1, value))
        let ratio = next / zoom
        pan = CGSize(width: viewport.width / 2 - (viewport.width / 2 - pan.width) * ratio,
                     height: viewport.height / 2 - (viewport.height / 2 - pan.height) * ratio)
        zoom = next
    }

    private func fit(in viewport: CGSize) {
        let bounds = graphBounds.isNull
            ? CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight) : graphBounds
        zoom = min(1.2, max(0.1, min((viewport.width - 96) / bounds.width, (viewport.height - 96) / bounds.height)))
        pan = CGSize(width: viewport.width / 2 - bounds.midX * zoom,
                     height: viewport.height / 2 - bounds.midY * zoom)
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
