import SwiftUI

/// Add or edit an SMB connection.
struct ServerFormView: View {
    @Bindable var model: AppModel
    /// Nil when adding.
    let existing: ServerProfile?

    @Environment(\.dismiss) private var dismiss

    @State private var profile: ServerProfile
    @State private var password = ""
    @State private var makeDefault: Bool
    @State private var portText: String
    @State private var isTesting = false
    @State private var testResult: TestResult?

    private enum TestResult: Equatable {
        case success(shareCount: Int)
        case failure(BrowseFailure)
    }

    init(model: AppModel, existing: ServerProfile? = nil) {
        self.model = model
        self.existing = existing
        let base = existing ?? ServerProfile()
        self._profile = State(initialValue: base)
        self._portText = State(initialValue: String(base.port))
        self._makeDefault = State(
            initialValue: existing.map { model.servers.defaultServerID == $0.id } ?? model.servers.isEmpty
        )
        self._password = State(initialValue: existing.flatMap { model.servers.password(for: $0) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledField("Name", text: $profile.name, prompt: "Home NAS")
                        .accessibilityIdentifier("serverForm.name")
                    LabeledField("Host or IP", text: $profile.host, prompt: "192.168.1.50")
                        .textContentType(.URL)
                        #if !os(macOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("serverForm.host")
                    LabeledField("Port", text: $portText, prompt: "445")
                        #if !os(macOS)
                        .keyboardType(.numberPad)
                        #endif
                        .accessibilityIdentifier("serverForm.port")
                    LabeledField("Share", text: $profile.shareName, prompt: "Media")
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("serverForm.share")
                }

                Section("Sign In") {
                    LabeledField("Username", text: $profile.username, prompt: "guest")
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("serverForm.username")
                    HStack {
                        Text("Password")
                            .frame(width: 92, alignment: .leading)
                            .foregroundStyle(.secondary)
                        SecureField("Password", text: $password, prompt: Text("Optional"))
                            .labelsHidden()
                            .textContentType(.password)
                            .accessibilityIdentifier("serverForm.password")
                    }
                    LabeledField("Domain", text: $profile.domain, prompt: "Optional (WORKGROUP)")
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif

                    Toggle("Save Credentials", isOn: $profile.saveCredentials)
                        .accessibilityIdentifier("serverForm.saveCredentials")
                    if !profile.saveCredentials {
                        Text("The password won't be stored in the Keychain, and any password already saved for this server will be removed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Set as Default", isOn: $makeDefault)
                        .accessibilityIdentifier("serverForm.setDefault")
                } footer: {
                    Text("The default server connects automatically when the app opens.")
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "bolt.horizontal.circle")
                            if isTesting {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(isTesting || !isPortValid || profile.host.isEmpty)
                    .accessibilityIdentifier("serverForm.test")

                    if let testResult {
                        testResultRow(testResult)
                    }
                }

                if let error = validationMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "Add Server" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(validationMessage != nil)
                        .accessibilityIdentifier("serverForm.save")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func testResultRow(_ result: TestResult) -> some View {
        switch result {
        case .success(let shareCount):
            Label(
                shareCount > 0
                    ? "Connected. \(shareCount) share\(shareCount == 1 ? "" : "s") visible."
                    : "Connected.",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.footnote)
        case .failure(let failure):
            VStack(alignment: .leading, spacing: 4) {
                Label(failure.title, systemImage: failure.symbolName)
                    .foregroundStyle(.red)
                Text(failure.message)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
    }

    // MARK: - Validation

    private var isPortValid: Bool {
        guard let port = Int(portText) else { return false }
        return (1...65535).contains(port)
    }

    private var validationMessage: String? {
        guard isPortValid else { return "Port must be a number between 1 and 65535." }
        var candidate = profile
        candidate.port = Int(portText) ?? ServerProfile.defaultPort
        return candidate.validationError
    }

    private var resolvedProfile: ServerProfile {
        var candidate = profile
        candidate.port = Int(portText) ?? ServerProfile.defaultPort
        return candidate
    }

    // MARK: - Actions

    private func testConnection() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        let candidate = resolvedProfile
        let service = SMBService(profile: candidate, password: password)
        do {
            try await service.connect()
            let shares = (try? await service.listShares()) ?? []
            testResult = .success(shareCount: shares.count)
            await service.disconnect()
        } catch {
            testResult = .failure(BrowseFailure(error: error, target: candidate.host))
        }
    }

    private func save() {
        let candidate = resolvedProfile
        let passwordToStore = candidate.saveCredentials ? password : nil
        dismiss()
        Task {
            await model.saveServer(candidate, password: passwordToStore, makeDefault: makeDefault)
        }
    }
}

/// Label-plus-field row, sized so labels line up across a form.
private struct LabeledField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    init(_ title: String, text: Binding<String>, prompt: String) {
        self.title = title
        self._text = text
        self.prompt = prompt
    }

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 92, alignment: .leading)
                .foregroundStyle(.secondary)
            // The example text goes in `prompt:`, not in the title position.
            // A TextField's title is a *label*, and inside a Form on macOS it
            // renders as visible text beside the field rather than as
            // placeholder text — so it never cleared as you typed, and the
            // caret sat to the right of it. labelsHidden() suppresses the
            // duplicate label, since this row already draws its own.
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden()
        }
    }
}
