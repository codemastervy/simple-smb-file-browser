import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Root application state: stores, live connections, pane routing, and modals.
@MainActor
@Observable
final class AppModel {
    let preferences: AppPreferences
    let servers: ServerStore
    let transfers: TransferCenter
    let transferCoordinator: TransferCoordinator
    private let deviceFiles: DeviceFileService
    private let clientFactory: any SMBClientFactory

    /// Connection status per server, shown as the sidebar dot.
    private(set) var connectionStates: [UUID: ConnectionState] = [:]

    /// Collapsed on every launch by requirement, so this is intentionally not
    /// persisted to UserDefaults.
    var isDeviceFilesExpanded = false

    var selectedLocation: BrowserLocation?
    /// Second pane, used for side-by-side browsing on iPad and Mac.
    var secondaryLocation: BrowserLocation?
    var isDualPaneEnabled = false

    // Routing for sheets and the failure modal.
    var editingServer: ServerProfile?
    var isAddingServer = false
    var isShowingSettings = false
    var isShowingTransfers = false
    /// The failure currently presented full-screen, with the pane it came from.
    var presentedFailure: PresentedFailure?

    struct PresentedFailure: Identifiable {
        let id = UUID()
        let failure: BrowseFailure
        let serverID: UUID?
    }

    private var browsers: [String: FileBrowserViewModel] = [:]
    private var services: [UUID: SMBService] = [:]

    // Defaults are nil rather than constructed inline: default-argument
    // expressions are evaluated in a nonisolated context, and these types are
    // main-actor isolated.
    init(
        preferences: AppPreferences? = nil,
        servers: ServerStore? = nil,
        deviceFiles: DeviceFileService = DeviceFileService(),
        clientFactory: any SMBClientFactory = AMSMB2ClientFactory()
    ) {
        let transfers = TransferCenter()
        self.preferences = preferences ?? AppPreferences()
        self.servers = servers ?? ServerStore()
        self.transfers = transfers
        self.transferCoordinator = TransferCoordinator(center: transfers)
        self.deviceFiles = deviceFiles
        self.clientFactory = clientFactory
    }

    // MARK: - Launch

    /// Auto-connects to the saved default server, silently, so the app opens
    /// straight into the browser rather than an onboarding screen.
    func performLaunchConnect() async {
        guard let profile = servers.launchServer else { return }
        selectedLocation = .server(profile.id)
        await connect(to: profile.id)
    }

    var hasNoServers: Bool { servers.isEmpty }

    // MARK: - Connections

    func connectionState(for id: UUID) -> ConnectionState {
        connectionStates[id] ?? .disconnected
    }

    func connect(to id: UUID) async {
        guard let profile = servers.profile(id: id) else { return }
        connectionStates[id] = .connecting

        let service = service(for: profile)
        do {
            try await service.connect()
            connectionStates[id] = .connected
        } catch {
            let failure = BrowseFailure(error: error, target: profile.host)
            connectionStates[id] = .failed(failure)
            presentedFailure = PresentedFailure(failure: failure, serverID: id)
        }
    }

    func disconnect(from id: UUID) async {
        if let service = services[id] {
            await service.disconnect()
        }
        connectionStates[id] = .disconnected
    }

    /// Retries a failed connection and reloads the pane showing it.
    func retryConnection(for id: UUID?) async {
        presentedFailure = nil
        guard let id else {
            if let location = selectedLocation {
                await browser(for: location)?.retry()
            }
            return
        }
        services[id] = nil
        browsers[BrowserLocation.server(id).id] = nil
        await connect(to: id)
        if connectionStates[id]?.isConnected == true {
            await browser(for: .server(id))?.load()
        }
    }

    private func service(for profile: ServerProfile) -> SMBService {
        if let existing = services[profile.id] { return existing }
        let service = SMBService(
            profile: profile,
            password: servers.password(for: profile),
            factory: clientFactory
        )
        services[profile.id] = service
        return service
    }

    // MARK: - Browsers

    /// The view model for a location, created on demand and cached so a pane
    /// keeps its path and selection while the user switches around.
    func browser(for location: BrowserLocation) -> FileBrowserViewModel? {
        if let existing = browsers[location.id] { return existing }
        guard let provider = makeProvider(for: location) else { return nil }
        let model = FileBrowserViewModel(
            provider: provider, location: location, preferences: preferences
        )
        browsers[location.id] = model
        return model
    }

    private func makeProvider(for location: BrowserLocation) -> (any FileProviding)? {
        switch location {
        case .server(let id):
            guard let profile = servers.profile(id: id) else { return nil }
            return SMBFileProvider(
                service: service(for: profile),
                label: profile.displayName,
                profileID: profile.id
            )
        case .device(let deviceLocation):
            return DeviceFileProvider(
                service: deviceFiles,
                location: deviceLocation,
                rootPath: deviceRootPath(for: deviceLocation)
            )
        }
    }

    /// Resolved eagerly and synchronously so the provider has a root before its
    /// first listing. iCloud falls back to the local root when unavailable,
    /// which the browser surfaces as an empty directory rather than a crash.
    private var cachedDeviceRoots: [DeviceLocation: String] = [:]

    private func deviceRootPath(for location: DeviceLocation) -> String {
        if let cached = cachedDeviceRoots[location] { return cached }
        let fileManager = FileManager.default
        let url: URL
        switch location {
        case .onMyDevice:
            url = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
        case .iCloudDrive:
            if let container = fileManager.url(forUbiquityContainerIdentifier: nil) {
                let documents = container.appendingPathComponent("Documents", isDirectory: true)
                try? fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
                url = documents
            } else {
                url = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                    ?? fileManager.temporaryDirectory
            }
        }
        cachedDeviceRoots[location] = url.path
        return url.path
    }

    var isICloudAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
    }

    // MARK: - Server management

    func saveServer(_ profile: ServerProfile, password: String?, makeDefault: Bool) async {
        do {
            try servers.save(profile, password: password, makeDefault: makeDefault)
            // Drop cached state so the next connect picks up new credentials.
            services[profile.id] = nil
            browsers[BrowserLocation.server(profile.id).id] = nil
            connectionStates[profile.id] = .disconnected
            selectedLocation = .server(profile.id)
            await connect(to: profile.id)
        } catch {
            presentedFailure = PresentedFailure(
                failure: BrowseFailure(localError: error, target: profile.displayName),
                serverID: profile.id
            )
        }
    }

    func removeServer(id: UUID) async {
        await disconnect(from: id)
        services[id] = nil
        browsers[BrowserLocation.server(id).id] = nil
        connectionStates[id] = nil
        try? servers.remove(id: id)
        if selectedLocation?.serverID == id { selectedLocation = servers.launchServer.map { .server($0.id) } }
        if secondaryLocation?.serverID == id { secondaryLocation = nil }
    }

    // MARK: - Dual pane

    /// Side-by-side browsing is offered on iPad and Mac only; an iPhone has no
    /// room for two panes.
    var isDualPaneSupported: Bool {
        #if os(macOS)
        return true
        #else
        return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    func openInSecondPane(_ location: BrowserLocation) {
        guard isDualPaneSupported else { return }
        secondaryLocation = location
        isDualPaneEnabled = true
        if let id = location.serverID, connectionState(for: id).isConnected == false {
            Task { await connect(to: id) }
        }
    }

    func closeSecondPane() {
        isDualPaneEnabled = false
        secondaryLocation = nil
    }

    // MARK: - Recovery app

    var recoveryApp: RecoveryApp? { preferences.recoveryApp }

    @discardableResult
    func launchRecoveryApp() async -> Bool {
        guard let url = preferences.recoveryApp?.launchURL else { return false }
        return await AppLauncher.open(url)
    }
}
