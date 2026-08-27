import Foundation

/// A saved SMB connection.
///
/// Only non-secret metadata lives here; this struct is persisted to
/// `UserDefaults` via `ServerStore`. The password is held separately in the
/// Keychain, keyed by `id`, so serialising a profile can never leak it.
struct ServerProfile: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var shareName: String
    var username: String
    /// When false, the password is not written to the Keychain and the user is
    /// prompted on each connection attempt.
    var saveCredentials: Bool
    var domain: String

    static let defaultPort = 445

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = ServerProfile.defaultPort,
        shareName: String = "",
        username: String = "",
        saveCredentials: Bool = true,
        domain: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.shareName = shareName
        self.username = username
        self.saveCredentials = saveCredentials
        self.domain = domain
    }
}

extension ServerProfile {
    /// Display name, falling back to the host so a profile is never nameless.
    var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? host : name
    }

    var subtitle: String {
        let hostPart = port == Self.defaultPort ? host : "\(host):\(port)"
        return shareName.isEmpty ? hostPart : "\(hostPart)/\(shareName)"
    }

    /// The `smb://` URL AMSMB2 requires. `SMB2Manager.init` is failable and
    /// rejects anything without an `smb` scheme and a host, so this is the one
    /// place that shape is constructed.
    var smbURL: URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "smb"
        components.host = trimmedHost
        if port != Self.defaultPort { components.port = port }
        return components.url
    }

    /// Fields the user must supply before a connection can be attempted.
    var validationError: String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Host or IP address is required." }
        if shareName.trimmingCharacters(in: .whitespaces).isEmpty { return "Share name is required." }
        if !(1...65535).contains(port) { return "Port must be between 1 and 65535." }
        if smbURL == nil { return "\"\(host)\" is not a valid host name." }
        return nil
    }

    var isValid: Bool { validationError == nil }
}
