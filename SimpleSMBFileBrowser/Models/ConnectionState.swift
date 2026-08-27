import Foundation

/// Connection lifecycle for one server profile, surfaced as the status dot in
/// the sidebar and as the loading state in the browser.
enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(SMBFailure)

    var isConnected: Bool { self == .connected }
    var isBusy: Bool { self == .connecting }

    var failure: SMBFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}
