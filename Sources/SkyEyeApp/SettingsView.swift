import AppKit
import ServiceManagement
import SkyEyeCore
import SwiftUI

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject private var manager: ServiceManager
    @Binding var route: Route

    private enum Tab: String, CaseIterable {
        case general = "General", logs = "Logs", agents = "AI agents", advanced = "Advanced"
    }
    @State private var tab: Tab = .general
    @State private var error: String?
    @State private var agent: Agent = .claude
    @State private var confirmingApprovalOff = false
    /// Bumped whenever the login item status is re-read so the switch refreshes even though the
    /// binding reads `SMAppService` directly (which SwiftUI can't observe).
    @State private var loginItemRefresh = 0
    @State private var shellText = ""
    @State private var shellError: String?
    @FocusState private var shellFocused: Bool

    private var mcpServerPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/skyeye-mcp").path
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Settings", back: {
                if commitShell() { route = .list }
            }) {}
            MenuDivider()
            if let error {
                ErrorBanner(message: error) { self.error = nil }
                MenuDivider()
            }
            Picker("Settings category", selection: Binding(
                get: { tab },
                set: { next in
                    guard tab != .advanced || commitShell() else { return }
                    shellFocused = false
                    tab = next
                }
            )) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .general: general
                    case .logs: logs
                    case .agents: aiAgents
                    case .advanced:
                        safety
                        advanced
                        configLocation
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: 320)
            Divider().padding(.horizontal, 12)
            Text("SkyEye \(version)")
                .font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .onAppear {
            loginItemRefresh &+= 1
            shellText = manager.config.settings.shell ?? ""
        }
        .onDisappear { _ = commitShell() }
        .confirmationDialog(
            "Turn off approval?",
            isPresented: $confirmingApprovalOff,
            titleVisibility: .visible
        ) {
            Button("Turn Off Approval", role: .destructive) { setRequireApproval(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything that can add or change a service — including the CLI and AI agents — could then run commands on this Mac without asking you first.")
        }
    }

    // MARK: Sections

    private var general: some View {
        section("General") {
            SettingsToggle(title: "Launch at login", isOn: launchAtLogin)
                .help("Open SkyEye automatically when you log in.")
            SettingsToggle(
                title: "Notify me when a service crashes or needs approval",
                isOn: boolSetting(\.notifications)
            )
            .help("Show a macOS notification when a service crashes or needs approval.")
            SettingsToggle(
                title: "Keep services running when SkyEye quits",
                isOn: boolSetting(\.keepRunningOnQuit)
            )
            .help("Services stay up after SkyEye quits and are taken back over on the next launch.")
            Divider()
            Picker("Start with SkyEye", selection: Binding(
                get: { manager.config.settings.autoStartMode },
                set: { mode in
                    var settings = manager.config.settings
                    settings.autoStartMode = mode
                    update(settings)
                }
            )) {
                Text("None").tag(AutoStartMode.none)
                Text("Selected services").tag(AutoStartMode.selected)
                Text("All services").tag(AutoStartMode.all)
            }
            .pickerStyle(.menu)
            if manager.config.settings.autoStartMode == .selected {
                let services = manager.config.services.filter { $0.command != nil }
                if services.isEmpty {
                    Text("Add a service with a start command to choose it here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(services) { service in
                    Toggle(service.name, isOn: Binding(
                        get: { manager.config.settings.autoStartServices.contains(service.name) },
                        set: { selected in
                            var settings = manager.config.settings
                            settings.autoStartServices.removeAll { $0 == service.name }
                            if selected { settings.autoStartServices.append(service.name) }
                            update(settings)
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            Text("Applies next time SkyEye opens. Dependencies start first; commands still require approval. Monitor-only services are not started.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var safety: some View {
        section("Command approval") {
            SettingsToggle(
                title: "Require approval for commands from the CLI or AI agents",
                isOn: requireApproval
            )
            .help("Anything that can add or change a service could run a command. Turning this off skips the approval prompt.")

        }
    }

    private var advanced: some View {
        section("Advanced") {
            SettingsToggle(
                title: "Load my shell profile (zsh -il)",
                isOn: boolSetting(\.loadShellProfile)
            )
            .help("Runs commands with your login shell so nvm, asdf, mise and PATH from your dotfiles work.")
            VStack(alignment: .leading, spacing: 4) {
                Text("Login shell")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("/bin/zsh", text: $shellText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($shellFocused)
                    .onSubmit { commitShell() }
                    .onChange(of: shellFocused) { _, focused in
                        if !focused { commitShell() }
                    }
                    .accessibilityLabel("Login shell")
                    .help("Leave empty to use your login shell.")
                if let shellError {
                    Text(shellError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var logs: some View {
        section("Logs") {
            Picker("Retention", selection: Binding(
                get: { manager.config.settings.logRetentionDays },
                set: { days in
                    var settings = manager.config.settings
                    settings.logRetentionDays = days
                    update(settings)
                }
            )) {
                Text("1 day").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("Keep forever").tag(0)
            }
            .pickerStyle(.menu)
            Text("Logs rotate daily after a service's next start. Older archives and inactive logs are cleaned up hourly while SkyEye is running. Active logs are preserved.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = manager.logCleanupError {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            Button {
                NSWorkspace.shared.open(manager.paths.logsDir)
            } label: {
                Label("Show Logs Folder", systemImage: "folder")
            }
            .controlSize(.small)
        }
    }

    private var aiAgents: some View {
        section("Connect AI agents") {
            Picker("AI agent", selection: $agent) {
                ForEach(Agent.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(agent.command(mcpPath: mcpServerPath))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    CopyButton(text: agent.command(mcpPath: mcpServerPath), help: "Copy \(agent.displayName) setup")
                }
                if let hint = agent.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
        }
    }

    private var configLocation: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([manager.paths.configFile])
        } label: {
            Label("Show Config in Finder", systemImage: "doc.text")
        }
        .controlSize(.small)
        .help("Reveal config.json in Finder")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: title)
            content()
        }
    }

    // MARK: Bindings

    /// Always shows the real login item status. The setter updates it and bumps `loginItemRefresh`
    /// so the switch snaps back to the actual state when registering or unregistering fails.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: {
                _ = loginItemRefresh
                return SMAppService.mainApp.status == .enabled
            },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                        if SMAppService.mainApp.status == .requiresApproval {
                            self.error = "Allow SkyEye in System Settings › General › Login Items to finish turning on launch at login."
                        }
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    self.error = "Couldn't change login item: \(error.localizedDescription)"
                }
                loginItemRefresh &+= 1
            }
        )
    }

    private func boolSetting(_ keyPath: WritableKeyPath<SkyEyeCore.Settings, Bool>) -> Binding<Bool> {
        Binding(
            get: { manager.config.settings[keyPath: keyPath] },
            set: { value in
                var settings = manager.config.settings
                settings[keyPath: keyPath] = value
                update(settings)
            }
        )
    }

    /// Commits the shell only when it points at an executable, so a half-typed path never gets
    /// persisted and breaks later service starts.
    @discardableResult
    private func commitShell() -> Bool {
        let raw = shellText.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            shellError = nil
            guard manager.config.settings.shell != nil else { return true }
            var settings = manager.config.settings
            settings.shell = nil
            update(settings)
            return true
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: expanded) else {
            shellError = "Not an executable shell: " + raw
            return false
        }
        shellError = nil
        if shellText != expanded { shellText = expanded }
        guard expanded != (manager.config.settings.shell ?? "") else { return true }
        var settings = manager.config.settings
        settings.shell = expanded
        update(settings)
        return true
    }

    /// Turning approval off is destructive, so it goes through a confirmation first.
    private var requireApproval: Binding<Bool> {
        Binding(
            get: { manager.config.settings.requireApproval },
            set: { enabled in
                if enabled {
                    setRequireApproval(true)
                } else {
                    confirmingApprovalOff = true
                }
            }
        )
    }

    private func setRequireApproval(_ enabled: Bool) {
        var settings = manager.config.settings
        settings.requireApproval = enabled
        update(settings)
    }

    private func update(_ settings: SkyEyeCore.Settings) {
        do { try manager.updateSettings(settings) } catch { self.error = error.localizedDescription }
    }
}

// MARK: Pieces

private struct SettingsToggle: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
    }
}

private enum Agent: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case gemini = "Gemini"
    case harness = "DeepSeek"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .harness: "DeepSeek Harness"
        }
    }

    /// Extra instructions for agents that are configured with a file rather than a CLI command.
    var hint: String? {
        switch self {
        case .harness: "Add this entry to ~/.dsh/profiles/<profile>/cordis.patch.yml and restart DeepSeek Harness."
        default: nil
        }
    }

    /// The MCP registration command or configuration for this agent, pointing at SkyEye.app's bundled server.
    func command(mcpPath: String) -> String {
        switch self {
        case .claude: "claude mcp add skyeye -- \"\(mcpPath)\""
        case .codex: "codex mcp add skyeye -- \"\(mcpPath)\""
        case .gemini: "gemini mcp add skyeye \"\(mcpPath)\""
        case .harness:
            """
            - id: mcp-skyeye
              name: '@deepseek-ai/dsh-mcp-client'
              config:
                serverName: skyeye
                transport: stdio
                command: "\(mcpPath)"
            """
        }
    }
}
