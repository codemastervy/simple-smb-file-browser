import Foundation
import AMSMB2
#if os(iOS)
import UIKit
#endif

/// Reports which SMB backend the running build uses.
///
/// This is also the AMSMB2 link smoke test: it touches `SMB2Manager` so a
/// broken package integration fails at build time rather than at first connect.
enum SMBClientEnvironment {
    /// AMSMB2 is used on every platform, including macOS. See README
    /// ("Why AMSMB2 on macOS too") for why native NetFS mounting was not used.
    static let backend = "AMSMB2 (libsmb2)"

    static var platformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #else
        return "unknown"
        #endif
    }

    /// True when AMSMB2 can construct a client at all — a cheap guard that the
    /// package is linked and its URL validation behaves as expected.
    static var isClientAvailable: Bool {
        guard let url = URL(string: "smb://127.0.0.1") else { return false }
        return SMB2Manager(url: url, credential: nil) != nil
    }

    static var summary: String {
        "\(platformName) · \(backend)\nclient available: \(isClientAvailable ? "yes" : "no")"
    }
}
