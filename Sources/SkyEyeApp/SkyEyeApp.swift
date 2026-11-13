import AppKit
import SkyEyeCore
import SwiftUI
import UserNotifications

@main
struct SkyEyeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appDelegate.manager)
                .environmentObject(appDelegate.monitor)
        } label: {
            MenuBarLabel(manager: appDelegate.manager)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var manager: ServiceManager

    var body: some View {
        let needsAttention = manager.snapshots.contains {
            [.crashed, .unhealthy, .pendingApproval].contains($0.state) || !$0.approved
        }
        Image(nsImage: needsAttention ? Self.badgedIcon : Self.icon)
    }

    private static let icon = symbol()

    /// The telescope with a dot cut into its top-right corner, still a template so it follows the menu bar's colors.
    private static let badgedIcon: NSImage = {
        let base = symbol()
        let size = NSSize(width: base.size.width + 2, height: base.size.height + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(at: NSPoint(x: 0, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
            let dot = NSRect(x: rect.maxX - 8, y: rect.maxY - 8, width: 8, height: 8)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func symbol() -> NSImage {
        let image = NSImage(contentsOf: Bundle.main.url(forResource: "Telescope", withExtension: "pdf")!)!
        image.size = NSSize(width: 19, height: 19)
        image.accessibilityDescription = "SkyEye"
        image.isTemplate = true
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = ServiceManager()
    private(set) lazy var monitor = NetworkMonitor(manager: manager)
    private var server: ControlServer?
    private let notifier = Notifier()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let socketPath = manager.paths.socketPath
        let ping = try? ControlClient(socketPath: socketPath, autoLaunch: false).send(ControlRequest(action: .ping))
        if ping?.ok == true {
            NSApp.terminate(nil)  // another SkyEye is already running
            return
        }

        manager.onEvent = { [weak self] event in
            guard let self, self.manager.config.settings.notifications else { return }
            self.notifier.post(event)
        }

        let manager = self.manager
        let server = ControlServer(socketPath: socketPath) { request in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { manager.handle(request) }
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("SkyEye: control server failed: \(error)")
        }
        manager.adoptDetached()
        manager.startMonitoring()
        UsageHistory.shared.start(manager: manager)
        manager.startConfiguredServices()
        notifier.requestAuthorization()
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--open-services") {
            let route = arguments.indices.contains(index + 1) ? Route(argument: arguments[index + 1]) : nil
            ServicesWindowController.shared.show(manager: manager, monitor: monitor, route: route ?? .list)
        }
        if CommandLine.arguments.contains("--open-canvas") {
            CanvasWindowController.shared.show(manager: manager)
        }
        if CommandLine.arguments.contains("--open-ports") {
            PortsWindowController.shared.show(manager: manager, monitor: monitor)
        } else {
            // One scan once things have settled, so the menu's Ports button knows whether anything needs a look.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [monitor] in monitor.rescanInBackground() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = manager.activeCount
        guard count > 0, !manager.config.settings.keepRunningOnQuit else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit SkyEye and stop services?"
        alert.informativeText = "Quitting will stop " + String(count)
            + (count == 1 ? " running service" : " running services")
            + " started by SkyEye. Enable “Keep services running when SkyEye quits” in Settings to leave them running."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Stop Services and Quit")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].hasDestructiveAction = true
        sender.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if manager.config.settings.keepRunningOnQuit { manager.detachAll() } else { manager.stopAll() }
        server?.stop()
    }
}

/// The menu's content in an ordinary window.
@MainActor
final class ServicesWindowController {
    static let shared = ServicesWindowController()
    private var window: NSWindow?

    func show(manager: ServiceManager, monitor: NetworkMonitor, route: Route = .list) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "SkyEye — Services"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: MenuContentView(route: route).environmentObject(manager).environmentObject(monitor)
            )
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func requestAuthorization() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ event: ServiceEvent) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        switch event {
        case let .crashed(name, detail):
            content.title = "\(name) crashed"
            content.body = detail
        case let .unhealthy(name, detail):
            content.title = "\(name) is unhealthy"
            content.body = detail
        case let .approvalNeeded(name, command):
            content.title = "Approve \(name)?"
            content.body = "A new command is waiting for approval in SkyEye:\n\(command)"
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
