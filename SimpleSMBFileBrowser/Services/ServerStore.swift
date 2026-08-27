import Foundation
import Observation

/// Persistence for saved SMB connections.
///
/// Non-secret metadata (name, host, port, share, username) is kept in
/// `UserDefaults` as JSON; passwords live in the injected `CredentialStoring`.
/// Both stores are injectable so tests never touch real user data.
@MainActor
@Observable
final class ServerStore {
    private enum Key {
        static let profiles = "servers.profiles"
        static let defaultID = "servers.defaultID"
    }

    private(set) var profiles: [ServerProfile] = []
    private(set) var defaultServerID: UUID?

    private let defaults: UserDefaults
    private let credentials: any CredentialStoring

    init(defaults: UserDefaults = .standard, credentials: any CredentialStoring = KeychainService()) {
        self.defaults = defaults
        self.credentials = credentials
        load()
    }

    // MARK: - Loading and saving

    private func load() {
        if let data = defaults.data(forKey: Key.profiles),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
        if let raw = defaults.string(forKey: Key.defaultID) {
            defaultServerID = UUID(uuidString: raw)
        }
        // Drop a dangling default pointer rather than letting launch auto-connect
        // to a profile that no longer exists.
        if let id = defaultServerID, !profiles.contains(where: { $0.id == id }) {
            defaultServerID = nil
            defaults.removeObject(forKey: Key.defaultID)
        }
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Key.profiles)
    }

    // MARK: - Queries

    var defaultServer: ServerProfile? {
        guard let defaultServerID else { return nil }
        return profiles.first { $0.id == defaultServerID }
    }

    /// The profile the app should try at launch: the explicit default, else the
    /// first saved profile so a single-server setup needs no configuration.
    var launchServer: ServerProfile? {
        defaultServer ?? profiles.first
    }

    var isEmpty: Bool { profiles.isEmpty }

    func profile(id: UUID) -> ServerProfile? {
        profiles.first { $0.id == id }
    }

    // MARK: - Mutations

    /// Adds a new profile, or replaces an existing one with the same id.
    /// Passing a password of `nil` leaves any stored password untouched.
    func save(_ profile: ServerProfile, password: String?, makeDefault: Bool = false) throws {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }

        if profile.saveCredentials {
            if let password, !password.isEmpty {
                try credentials.setPassword(password, for: profile.id)
            }
        } else {
            // Toggling "Save credentials" off must actively clear the secret,
            // not just stop writing new ones.
            try credentials.removePassword(for: profile.id)
        }

        persistProfiles()
        if makeDefault { setDefault(profile.id) }
    }

    func remove(id: UUID) throws {
        profiles.removeAll { $0.id == id }
        try credentials.removePassword(for: id)
        persistProfiles()
        if defaultServerID == id {
            defaultServerID = nil
            defaults.removeObject(forKey: Key.defaultID)
        }
    }

    func setDefault(_ id: UUID?) {
        guard let id else {
            defaultServerID = nil
            defaults.removeObject(forKey: Key.defaultID)
            return
        }
        guard profiles.contains(where: { $0.id == id }) else { return }
        defaultServerID = id
        defaults.set(id.uuidString, forKey: Key.defaultID)
    }

    func password(for profile: ServerProfile) -> String? {
        guard profile.saveCredentials else { return nil }
        return try? credentials.password(for: profile.id)
    }
}
