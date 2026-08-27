import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One of the two on-device browsing roots shown under "Device Files".
enum DeviceLocation: String, Identifiable, Hashable, Codable, CaseIterable, Sendable {
    case iCloudDrive
    case onMyDevice

    var id: String { rawValue }

    /// Sidebar title. "On My …" is resolved per platform so an iPad doesn't say
    /// "On My iPhone".
    var title: String {
        switch self {
        case .iCloudDrive:
            return "iCloud Drive"
        case .onMyDevice:
            #if os(macOS)
            return "On My Mac"
            #else
            return UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
            #endif
        }
    }

    var symbolName: String {
        switch self {
        case .iCloudDrive: return "icloud"
        case .onMyDevice:
            #if os(macOS)
            return "desktopcomputer"
            #else
            return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            #endif
        }
    }
}
