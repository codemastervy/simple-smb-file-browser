import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var customScheme = ""
    @State private var customName = ""
    @State private var testMessage: TestMessage?

    private struct TestMessage: Identifiable {
        let id = UUID()
        let text: String
        let isSuccess: Bool
    }

    var body: some View {
        NavigationStack {
            Form {
                recoveryAppSection
                browsingSection
                serversSection
                transfersSection
                aboutSection
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $model.editingServer) { profile in
                ServerFormView(model: model, existing: profile)
            }
        }
        .frame(minWidth: 460, minHeight: 560)
        .accessibilityIdentifier("settings")
    }

    // MARK: - Recovery app

    private var recoveryAppSection: some View {
        Section {
            Picker("Recovery App", selection: recoverySelection) {
                Text("None").tag(String?.none)
                ForEach(RecoveryApp.suggestions) { app in
                    Text(app.name).tag(Optional(app.scheme))
                }
                Text("Custom…").tag(Optional("__custom__"))
            }
            .accessibilityIdentifier("settings.recoveryAppPicker")

            if isCustomSelected {
                // Label in the title, example in the prompt: without the
                // split, the title behaves as a label on macOS and as a
                // placeholder on iOS, which reads differently per platform.
                TextField("App name", text: $customName, prompt: Text("Tailscale"))
                    .accessibilityIdentifier("settings.customName")
                TextField("URL scheme", text: $customScheme, prompt: Text("tailscale"))
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("settings.customScheme")
                Button("Use This App") {
                    let scheme = customScheme.trimmingCharacters(in: .whitespaces)
                    guard !scheme.isEmpty else { return }
                    model.preferences.recoveryApp = RecoveryApp(
                        name: customName.isEmpty ? scheme : customName,
                        scheme: scheme
                    )
                }
                .disabled(customScheme.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let app = model.preferences.recoveryApp {
                HStack {
                    Label("\(app.name) · \(app.scheme)://", systemImage: "arrow.up.forward.app")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Test") {
                        Task { await testRecoveryApp(app) }
                    }
                    .accessibilityIdentifier("settings.testRecoveryApp")
                }
            }

            if let testMessage {
                Label(testMessage.text, systemImage: testMessage.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(testMessage.isSuccess ? .green : .orange)
            }
        } header: {
            Text("Recovery App")
        } footer: {
            Text("Offered when a server can't be reached — useful for a VPN or tunnel app like Tailscale, WireGuard or Pangolin. Most of these apps don't publish a stable URL scheme, so use Test to confirm yours actually opens.")
        }
    }

    private var recoverySelection: Binding<String?> {
        Binding(
            get: {
                guard let app = model.preferences.recoveryApp else { return nil }
                return RecoveryApp.suggestions.contains(where: { $0.scheme == app.scheme })
                    ? app.scheme
                    : "__custom__"
            },
            set: { newValue in
                switch newValue {
                case .none:
                    model.preferences.recoveryApp = nil
                case .some("__custom__"):
                    // Keep whatever custom entry already exists; the fields
                    // below commit a new one.
                    if let existing = model.preferences.recoveryApp {
                        customName = existing.name
                        customScheme = existing.scheme
                    }
                    model.preferences.recoveryApp = model.preferences.recoveryApp
                        ?? RecoveryApp(name: customName, scheme: customScheme)
                case .some(let scheme):
                    if let match = RecoveryApp.suggestions.first(where: { $0.scheme == scheme }) {
                        model.preferences.recoveryApp = match
                    }
                }
                testMessage = nil
            }
        )
    }

    private var isCustomSelected: Bool {
        guard let app = model.preferences.recoveryApp else { return false }
        return !RecoveryApp.suggestions.contains(where: { $0.scheme == app.scheme })
    }

    private func testRecoveryApp(_ app: RecoveryApp) async {
        guard let url = app.launchURL else {
            testMessage = TestMessage(text: "“\(app.scheme)” isn't a usable URL scheme.", isSuccess: false)
            return
        }
        let launched = await AppLauncher.open(url)
        testMessage = launched
            ? TestMessage(text: "Opened \(app.name).", isSuccess: true)
            : TestMessage(
                text: "Nothing handled \(app.scheme)://. The app may not be installed, or may use a different scheme.",
                isSuccess: false
            )
    }

    // MARK: - Browsing defaults

    // AppPreferences is reached through a `let` on AppModel, so bindings can't
    // be projected through it — the section takes the object directly instead.
    private var browsingSection: some View {
        BrowsingDefaultsSection(preferences: model.preferences)
    }

    // MARK: - Servers

    private var serversSection: some View {
        Section("Saved Servers") {
            if model.servers.isEmpty {
                Text("No servers saved yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.servers.profiles) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                        Text(profile.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.servers.defaultServerID == profile.id {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Default")
                    }
                    Button {
                        model.editingServer = profile
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        Task { await model.removeServer(id: profile.id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                model.isAddingServer = true
            } label: {
                Label("Add Server", systemImage: "plus.circle")
            }
        }
    }

    // MARK: - Transfers

    private var transfersSection: some View {
        Section("Transfers") {
            HStack {
                Text("History")
                Spacer()
                Text("\(model.transfers.recent.count) item\(model.transfers.recent.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                model.transfers.clearHistory()
            } label: {
                Label("Clear Transfer History", systemImage: "trash")
            }
            .disabled(model.transfers.recent.isEmpty)
            .accessibilityIdentifier("settings.clearHistory")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: model.preferences.appVersion)
            LabeledContent("SMB Backend", value: SMBClientEnvironment.backend)
            LabeledContent("Platform", value: SMBClientEnvironment.platformName)
            LabeledContent("iCloud Drive", value: model.isICloudAvailable ? "Available" : "Not configured")
        }
    }
}

/// Browsing defaults. Split out so `@Bindable` can bind straight to
/// `AppPreferences`.
private struct BrowsingDefaultsSection: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Section("Browsing") {
            Picker("Default View", selection: $preferences.defaultViewMode) {
                ForEach(BrowserViewMode.allCases, id: \.self) { mode in
                    Label(mode == .list ? "List" : "Icons", systemImage: mode.symbolName).tag(mode)
                }
            }
            Picker("Sort By", selection: $preferences.defaultSort.field) {
                ForEach(SortField.allCases, id: \.self) { field in
                    Text(field.title).tag(field)
                }
            }
            Picker("Order", selection: $preferences.defaultSort.direction) {
                Text("Ascending").tag(SortDirection.ascending)
                Text("Descending").tag(SortDirection.descending)
            }
            Toggle("Search Subfolders by Default", isOn: $preferences.recursiveSearch)
            Toggle("Show Hidden Files", isOn: $preferences.showHiddenFiles)
        }
    }
}
