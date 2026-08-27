import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Launches another app by URL scheme, used for the recovery-app action.
enum AppLauncher {
    /// Attempts to open `url`, reporting whether it worked.
    ///
    /// `canOpenURL` is deliberately not consulted first: it only answers for
    /// schemes declared in `LSApplicationQueriesSchemes`, and the user can enter
    /// any scheme they like. Opening directly and reading the result handles
    /// arbitrary schemes correctly.
    @MainActor
    static func open(_ url: URL) async -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #else
        return await UIApplication.shared.open(url)
        #endif
    }

    /// Whether the system reports a handler for `url`. Only meaningful for
    /// declared schemes on iOS, so treat `false` as "unknown", not "missing".
    @MainActor
    static func isLikelyInstalled(_ url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        #else
        return UIApplication.shared.canOpenURL(url)
        #endif
    }
}
