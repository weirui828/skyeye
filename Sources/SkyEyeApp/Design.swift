import AppKit
import SkyEyeCore
import SwiftUI


enum Preferences {
    /// SkyEye was started with its own home folder (`SKYEYE_HOME`).
    static let isCustomHome = !(ProcessInfo.processInfo.environment["SKYEYE_HOME"] ?? "").isEmpty

    /// Where the interface keeps its own state.
    static let store: UserDefaults = {
        guard isCustomHome, let suite = UserDefaults(suiteName: "dev.skyeye.SkyEye.custom-home") else { return .standard }
        return suite
    }()
}

extension Color {
    /// A color with a light and a dark value.
    static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        let light = NSColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: 1)
        let dark = NSColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: 1)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// The chart page repeats `background` and `card` in `Resources/charts/charts.css`: change both together.
enum SkyEyeSurface {
    /// Behind everything.
    static let background = Color.adaptive(light: (0.949, 0.953, 0.965), dark: (0.106, 0.110, 0.125))
    static let card = Color.adaptive(light: (1, 1, 1), dark: (0.153, 0.161, 0.180))
    /// A container that holds cards, such as a node on the canvas.
    static let group = Color.adaptive(light: (0.975, 0.977, 0.984), dark: (0.129, 0.135, 0.153))
    /// Set into a card.
    static let well = Color.adaptive(light: (0.945, 0.949, 0.961), dark: (0.090, 0.094, 0.110))
    static let hairline = Color.primary.opacity(0.08)
}

/// The sky blue of the app icon.
enum Brand {
    static let top = Color(red: 0.33, green: 0.70, blue: 1.0)
    static let bottom = Color(red: 0.26, green: 0.38, blue: 0.94)
    static let tint = Color.adaptive(light: (0.20, 0.47, 0.94), dark: (0.45, 0.68, 1.0))
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// The app icon's sky.
    static let sky = LinearGradient(
        colors: [
            Color(red: 0.11, green: 0.15, blue: 0.52), Color(red: 0.17, green: 0.34, blue: 0.87), Color(red: 0.36, green: 0.74, blue: 1.0),
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// A faint sky behind the top of a page.
    static var wash: some View {
        LinearGradient(
            colors: [tint.opacity(0.17), tint.opacity(0.05), tint.opacity(0)], startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

/// What a color says.
enum Tone {
    static let good = Color.adaptive(light: (0.11, 0.65, 0.37), dark: (0.25, 0.84, 0.50))
    static let busy = Color.adaptive(light: (0.89, 0.61, 0.04), dark: (1.0, 0.77, 0.24))
    static let warn = Color.adaptive(light: (0.92, 0.47, 0.09), dark: (1.0, 0.62, 0.26))
    static let bad = Color.adaptive(light: (0.87, 0.23, 0.21), dark: (1.0, 0.43, 0.40))
    static let outside = Color.adaptive(light: (0.48, 0.35, 0.89), dark: (0.68, 0.58, 1.0))
    static let idle = Color.adaptive(light: (0.63, 0.65, 0.69), dark: (0.44, 0.46, 0.51))
}

extension ServiceState {
    var color: Color {
        switch self {
        case .running: Tone.good
        case .starting, .stopping: Tone.busy
        case .unhealthy, .pendingApproval: Tone.warn
        case .crashed: Tone.bad
        case .external: Tone.outside
        case .stopped: Tone.idle
        }
    }

    /// The order states are counted in.
    var rank: Int {
        switch self {
        case .running: 0
        case .external: 1
        case .starting, .stopping: 2
        case .unhealthy: 3
        case .pendingApproval: 4
        case .crashed: 5
        case .stopped: 6
        }
    }
}

enum Format {
    /// "4m", "2h 14m", "3d 5h".
    static func uptime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return "\(max(1, Int(interval)))s" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return days < 7 ? "\(days)d \(hours % 24)h" : "\(days)d"
    }

    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func percent(_ value: Double) -> String {
        String(format: value < 10 ? "%.1f%%" : "%.0f%%", value)
    }
}

private struct CardBackground: ViewModifier {
    var radius: CGFloat
    var fill: Color
    var stroke: Color
    var lineWidth: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(fill).shadow(color: .black.opacity(0.055), radius: 2, y: 1))
            .overlay(shape.strokeBorder(stroke, lineWidth: lineWidth))
    }
}

extension View {
    /// A raised white surface with a hairline edge.
    func skyCard(
        radius: CGFloat = 12, fill: Color = SkyEyeSurface.card, stroke: Color = SkyEyeSurface.hairline, lineWidth: CGFloat = 1
    ) -> some View {
        modifier(CardBackground(radius: radius, fill: fill, stroke: stroke, lineWidth: lineWidth))
    }

    /// Text set into a card.
    func skyWell(radius: CGFloat = 7) -> some View {
        background(SkyEyeSurface.well, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The telescope on the sky gradient.
struct BrandMark: View {
    var size: CGFloat = 28

    static let telescope: NSImage = {
        let image = NSImage(contentsOf: Bundle.main.url(forResource: "Telescope", withExtension: "pdf")!)!
        image.isTemplate = true
        return image
    }()

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Brand.sky)
            .overlay(
                Image(nsImage: Self.telescope).resizable().scaledToFit()
                    .foregroundStyle(.white)
                    .padding(size * 0.17)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
            )
            .frame(width: size, height: size)
            .shadow(color: Brand.bottom.opacity(0.35), radius: size * 0.12, y: size * 0.05)
            .accessibilityHidden(true)
    }
}

/// A service's state as a dot.
struct StatusDot: View {
    let state: ServiceState
    var size: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isChanging: Bool { state == .starting || state == .stopping }

    var body: some View {
        ZStack {
            if isChanging && !reduceMotion {
                Circle().fill(state.color)
                    .phaseAnimator([false, true]) { halo, grown in
                        halo.scaleEffect(grown ? 2.3 : 1).opacity(grown ? 0 : 0.55)
                    } animation: { _ in .easeOut(duration: 1.1) }
            } else if state != .stopped {
                Circle().fill(state.color.opacity(0.22)).scaleEffect(1.75)
            }
            if state == .stopped {
                Circle().strokeBorder(state.color, lineWidth: 1.5)
            } else {
                Circle().fill(state.color)
            }
        }
        .frame(width: size, height: size)
        .frame(width: size * 1.8, height: size * 1.8)
        .accessibilityLabel(state.label)
    }
}

/// A short label in a tinted capsule.
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var monospaced = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: monospaced ? .monospaced : .default))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.13), in: Capsule())
    }
}

/// How full something is.
struct Meter: View {
    let fraction: Double
    var tint: Color = Brand.tint

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(tint).frame(width: max(4, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// One segment for each service, colored by its state.
struct StateBar: View {
    let states: [ServiceState]

    var body: some View {
        HStack(spacing: 2) {
            if states.isEmpty {
                Capsule().fill(Color.primary.opacity(0.09))
            }
            ForEach(Array(states.sorted { $0.rank < $1.rank }.enumerated()), id: \.offset) { _, state in
                Capsule().fill(state.color)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The last couple of minutes of a reading, newest at the right edge.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = Brand.tint
    /// The value that fills the height when the readings are all smaller, so idle noise stays a flat line.
    var floor: Double = 4

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(values.max() ?? 0, floor)
            let step = size.width / CGFloat(UsageHistory.capacity - 1)
            var line = Path()
            var first = CGPoint.zero
            for (index, value) in values.enumerated() {
                let point = CGPoint(
                    x: size.width - CGFloat(values.count - 1 - index) * step,
                    y: size.height - 1 - CGFloat(value / top) * (size.height - 2)
                )
                if index == 0 { line.move(to: point); first = point } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.30), tint.opacity(0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// An icon and its title, closer together than the system's.
struct TightLabelStyle: LabelStyle {
    var spacing: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

/// A capsule button.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, prominent: prominent)
    }

    private struct Pill: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(TightLabelStyle())
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.85))
                .background(
                    Capsule().fill(prominent
                        ? AnyShapeStyle(Brand.gradient)
                        : AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                )
                .brightness(prominent && hovering ? 0.06 : 0)
                .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 24
    var tint: Color?
    var filled = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(tint ?? Color.primary.opacity(0.78))
                .background(Circle().fill((tint ?? Color.primary).opacity(hovering && isEnabled ? 0.16 : (filled ? 0.10 : 0))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.32)
        .onHover { hovering = $0 }
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
        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : help, tint: copied ? Tone.good : nil) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
    }
}

/// Small uppercase heading used to group rows and settings.
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(.secondary)
    }
}

/// A titled group of settings or fields on one card.
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionTitle(text: title).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .skyCard()
        }
    }
}

/// A message that something went wrong, or went right, with a way to put it away.
struct NoticeBanner: View {
    let message: String
    var tone: Color = Tone.warn
    var symbol = "exclamationmark.triangle.fill"
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tone).padding(.top, 1)
            Text(verbatim: message).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", help: "Dismiss", size: 20, action: dismiss)
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .padding(.vertical, 8)
        .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tone.opacity(0.25)))
    }
}

/// The last couple of minutes of CPU readings, for the small charts beside the numbers.
@MainActor
final class UsageHistory: ObservableObject {
    static let shared = UsageHistory()
    /// Readings kept.
    static let capacity = 40

    @Published private(set) var system: [Double] = []
    @Published private(set) var services: [String: [Double]] = [:]
    private var timer: Timer?

    func start(manager: ServiceManager) {
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self, weak manager] _ in
            MainActor.assumeIsolated {
                guard let self, let manager else { return }
                self.record(manager)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func record(_ manager: ServiceManager) {
        if let cpu = manager.systemUsage?.cpuPercent {
            system = Array((system + [cpu]).suffix(Self.capacity))
        }
        var next: [String: [Double]] = [:]
        for snapshot in manager.snapshots {
            guard let cpu = snapshot.cpuPercent else { continue }
            next[snapshot.id] = Array(((services[snapshot.id] ?? []) + [cpu]).suffix(Self.capacity))
        }
        services = next
    }
}

/// A text button that stays out of the way until it is pointed at.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Quiet(configuration: configuration)
    }

    private struct Quiet: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(TightLabelStyle(spacing: 4))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.4))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}
