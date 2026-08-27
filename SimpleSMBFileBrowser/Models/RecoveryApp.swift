import Foundation

/// A VPN/tunnel app offered as a one-tap recovery action when an SMB server
/// can't be reached.
///
/// Most such apps have no documented, stable URL scheme, so the list below is a
/// convenience only — the user can always type their own scheme, which is why
/// `custom` exists and why launching never depends on `canOpenURL`.
struct RecoveryApp: Identifiable, Hashable, Codable, Sendable {
    var name: String
    /// URL scheme without the `://`, e.g. `tailscale`.
    var scheme: String

    var id: String { scheme }

    /// The URL used to launch the app.
    var launchURL: URL? {
        let trimmed = scheme.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "://", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "\(trimmed)://")
    }

    static let suggestions: [RecoveryApp] = [
        RecoveryApp(name: "Tailscale", scheme: "tailscale"),
        RecoveryApp(name: "WireGuard", scheme: "wireguard"),
        RecoveryApp(name: "Pangolin", scheme: "pangolin"),
        RecoveryApp(name: "OpenVPN Connect", scheme: "openvpn"),
        RecoveryApp(name: "Shadowrocket", scheme: "shadowrocket"),
    ]
}
