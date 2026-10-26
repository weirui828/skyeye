import AppKit
import SkyEyeCore
import SwiftUI

// MARK: Editor

struct ServiceEditorView: View {
    @EnvironmentObject private var manager: ServiceManager
    let original: ServiceConfig?
    @Binding var route: Route

    // The values the editor opened with, kept so we can tell whether anything was edited.
    private let initialName: String
    private let initialPort: String
    private let initialCommand: String
    private let initialDirectory: String
    private let initialHealthPath: String
    private let initialGroup: String
    private let initialEnvText: String
    private let initialDependencies: [String]
    private let initialAutoRestart: Bool

    @State private var name: String
    @State private var port: String
    @State private var command: String
    @State private var directory: String
    @State private var healthPath: String
    @State private var group: String
    @State private var envText: String
    @State private var dependencies: Set<String>
    @State private var autoRestart: Bool
    private enum Tab: String, CaseIterable {
        case general = "General", dependencies = "Dependencies", environment = "Environment", health = "Health"
    }
    @State private var tab: Tab = .general

    @State private var showDiscardDialog = false
    @State private var error: String?
    @State private var directoryPanel: NSOpenPanel?

    init(original: ServiceConfig?, route: Binding<Route>) {
        self.original = original
        _route = route

        let initialName = original?.name ?? ""
        let initialPort = original?.port.map(String.init) ?? ""
        let initialCommand = original?.command ?? ""
        let initialDirectory = original?.directory ?? ""
        let initialHealthPath = original?.healthPath ?? ""
        let initialGroup = original?.group ?? ""
        let initialEnvText = original.map { service in
            service.env.keys.sorted().map { key in "\(key)=\(service.env[key]!)" }.joined(separator: "\n")
        } ?? ""
        let initialAutoRestart = original?.autoRestart ?? false

        self.initialName = initialName
        self.initialPort = initialPort
        self.initialCommand = initialCommand
        self.initialDirectory = initialDirectory
        self.initialHealthPath = initialHealthPath
        self.initialGroup = initialGroup
        self.initialEnvText = initialEnvText
        self.initialDependencies = original?.dependencies ?? []
        self.initialAutoRestart = initialAutoRestart

        _name = State(initialValue: initialName)
        _port = State(initialValue: initialPort)
        _command = State(initialValue: initialCommand)
        _directory = State(initialValue: initialDirectory)
        _healthPath = State(initialValue: initialHealthPath)
        _group = State(initialValue: initialGroup)
        _envText = State(initialValue: initialEnvText)
        _dependencies = State(initialValue: Set(original?.dependencies ?? []))
        _autoRestart = State(initialValue: initialAutoRestart)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: headerTitle, back: { requestLeave() }) {
                if let live = snapshot {
                    HStack(spacing: 5) {
                        StatusDot(state: live.state)
                        Text(live.state.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            MenuDivider()
            if let error {
                ErrorBanner(message: error) { self.error = nil }
                MenuDivider()
            }
            if needsApproval {
                Text("Waiting for approval — saving changes won't approve this command.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                MenuDivider()
            }
            Picker("Service settings category", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .general:
                        basics
                        workingDirectory
                        network
                        groupSection
                        behaviorSection
                    case .dependencies: dependencySection
                    case .environment: environmentSection
                    case .health: healthSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(height: 380)
            MenuDivider()
            footer
        }
        .confirmationDialog("Discard changes?", isPresented: $showDiscardDialog, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { route = .list }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(original.map { "Your edits to '\($0.name)' will be lost." } ?? "Your new service won't be saved.")
        }
    }

    // MARK: Sections

    private var basics: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Basics")
            field("Name", "api", $name, disabled: ownsProcess)
            if ownsProcess {
                Text("Stop the service to rename it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            field("Start command", "npm run dev", $command, monospaced: true)
            Text("Commands run in your login shell, so nvm, asdf and mise work.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if ownsProcess {
                Text("Changes to the command, port or health check apply after a restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Network")
            field("Port (optional)", "3000", $port)
            if let owner = duplicatePortOwner {
                Label("Port \(trimmedPort) is already used by '\(owner)'.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var workingDirectory: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Working directory")
            HStack(spacing: 6) {
                TextField("~/dev/my-project", text: $directory)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseDirectory() }
                    .controlSize(.small)
                    .help("Choose the folder the command runs in")
                    .accessibilityLabel("Choose working directory")
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                directory = url.path
                return true
            }
            Text("Tip: drop a folder on the field or use Choose…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Group")
            HStack(spacing: 6) {
                TextField("my-project", text: $group)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button("None") { group = "" }
                    if !existingGroups.isEmpty {
                        Divider()
                        ForEach(existingGroups, id: \.self) { existing in
                            Button(existing) { group = existing }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose an existing group")
                .accessibilityLabel("Choose an existing group")
            }
            Text("Optional — label related services and control them from the Groups menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dependencySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Depends on")
            let candidates = manager.config.services.filter { $0.name != original?.name }
            if candidates.isEmpty {
                Text("Add another service to define dependencies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(candidates) { service in
                Toggle(service.name, isOn: Binding(
                    get: { dependencies.contains(service.name) },
                    set: { selected in
                        if selected { dependencies.insert(service.name) }
                        else { dependencies.remove(service.name) }
                    }
                ))
                .toggleStyle(.checkbox)
            }
            Text("Dependencies start first. SkyEye waits for their ports and health checks before starting this service.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Readiness")
            field("Health check (optional)", "/health", $healthPath)
            Text("Use a path on this service's port, or a full HTTP URL. SkyEye waits for a successful response before marking the service ready or starting its dependents.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Leave empty to check only whether the port is open. Set the port in General.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Environment variables (\(envLineCount))")
            environmentEditor
            Text("One KEY=VALUE per line. These values are added to the service's shell environment.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var environmentEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $envText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 220)
                .padding(4)
                .accessibilityLabel("Environment variables, one KEY=VALUE per line")
            if envText.isEmpty {
                Text("KEY=VALUE per line")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 5)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Behavior")
            Toggle("Restart automatically if it crashes", isOn: $autoRestart)
                .toggleStyle(.switch)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { requestLeave() }
                .keyboardShortcut(.cancelAction)
            if ownsProcess && isDirty && !needsApproval {
                Button("Save & Restart") { save(restartAfterSaving: true) }
                    .help("Save the changes, then restart the service")
            }
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
    }

    private func field(
        _ label: String, _ placeholder: String, _ text: Binding<String>,
        monospaced: Bool = false, disabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(size: 12, design: .monospaced) : nil)
                .disabled(disabled)
        }
    }

    // MARK: Derived state

    private var headerTitle: String {
        if let original { return "Edit \(original.name)" }
        return "New Service"
    }

    /// The live snapshot of the service being edited, if it still exists.
    private var snapshot: ServiceSnapshot? {
        guard let original else { return nil }
        return manager.snapshots.first { $0.service.name == original.name }
    }

    /// SkyEye owns a process for this service, so its name can't change and command edits need a restart.
    /// This is deliberately not "the port is open": monitor-only and external services can be renamed
    /// or edited without restarting anything.
    private var ownsProcess: Bool { snapshot?.pid != nil }

    /// True when the live command isn't approved: the service may be stopped waiting for approval,
    /// or already running with an older approved command.
    private var needsApproval: Bool { snapshot?.approved == false }

    private var trimmedPort: String { port.trimmingCharacters(in: .whitespaces) }

    /// Another service that already uses the port being typed.
    private var duplicatePortOwner: String? {
        guard let value = Int(trimmedPort), (1...65535).contains(value) else { return nil }
        return manager.config.services.first { $0.port == value && $0.name != original?.name }?.name
    }

    private var envLineCount: Int {
        envText.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }.count
    }

    private var existingGroups: [String] {
        let groups = manager.config.services.compactMap { service -> String? in
            guard let group = service.group?.trimmingCharacters(in: .whitespaces), !group.isEmpty else { return nil }
            return group
        }
        return Array(Set(groups)).sorted()
    }

    private var isDirty: Bool {
        name != initialName
            || port != initialPort
            || command != initialCommand
            || directory != initialDirectory
            || healthPath != initialHealthPath
            || group != initialGroup
            || envText != initialEnvText
            || dependencies != Set(initialDependencies)
            || autoRestart != initialAutoRestart
    }

    // MARK: Actions

    private func requestLeave() {
        if isDirty {
            showDiscardDialog = true
        } else {
            route = .list
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let current = (directory.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if !current.isEmpty,
           FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory),
           isDirectory.boolValue {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        NSApp.activate()
        // Use the async panel: an app-modal run loop from a MenuBarExtra window can hide
        // the menu panel while the picker is up.
        directoryPanel = panel
        panel.begin { response in
            if response == .OK, let url = panel.url { directory = url.path }
            directoryPanel = nil
        }
    }

    /// Builds the config to save, validating the fields first. Returns nil and sets the error when it can't.
    private func validatedService() -> ServiceConfig? {
        let trimmedPort = port.trimmingCharacters(in: .whitespaces)
        var portNumber: Int?
        if !trimmedPort.isEmpty {
            guard let parsed = Int(trimmedPort) else {
                tab = .general
                error = "Port must be a number."
                return nil
            }
            guard (1...65535).contains(parsed) else {
                tab = .general
                error = "Port must be between 1 and 65535."
                return nil
            }
            portNumber = parsed
        }

        var env: [String: String] = [:]
        for line in envText.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eq = trimmed.firstIndex(of: "="), eq != trimmed.startIndex else {
                tab = .environment
                error = "Environment lines must look like KEY=VALUE: \(trimmed)"
                return nil
            }
            env[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
        }

        var service = original ?? ServiceConfig(name: "")
        service.name = name
        service.port = portNumber
        service.command = command
        service.directory = directory
        service.healthPath = healthPath
        service.dependencies = dependencies.sorted()
        service.group = group
        service.env = env
        service.autoRestart = autoRestart
        return service
    }

    private func save(restartAfterSaving: Bool = false) {
        guard let service = validatedService() else { return }
        // Editing a command that is still waiting for approval must not count as approving it.
        let trusted = !needsApproval
        do {
            let saved: ServiceConfig
            if let original {
                saved = try manager.updateService(named: original.name, to: service, trusted: trusted)
            } else {
                saved = try manager.addService(service, trusted: trusted)
            }
            if restartAfterSaving {
                let response = manager.handle(ControlRequest(action: .restart, name: saved.name))
                if !response.ok {
                    error = response.error ?? "Couldn't restart '\(saved.name)'."
                    return
                }
            }
            route = .list
        } catch {
            self.error = error.localizedDescription
        }
    }
}
