import Foundation

/// A place the browser can be pointed at: a saved SMB server, or one of the
/// on-device locations.
enum BrowserLocation: Identifiable, Hashable, Codable, Sendable {
    case server(UUID)
    case device(DeviceLocation)

    var id: String {
        switch self {
        case .server(let id): return "server:\(id.uuidString)"
        case .device(let location): return "device:\(location.rawValue)"
        }
    }

    var serverID: UUID? {
        if case .server(let id) = self { return id }
        return nil
    }

    var isServer: Bool { serverID != nil }
}
