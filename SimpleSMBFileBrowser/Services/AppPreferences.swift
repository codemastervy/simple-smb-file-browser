import Foundation
import Observation

/// User settings that are not secrets, persisted in `UserDefaults`.
///
/// Injectable defaults so tests and previews get a clean slate.
@MainActor
@Observable
final class AppPreferences {
    private enum Key {
        static let viewMode = "prefs.defaultViewMode"
        static let sortField = "prefs.defaultSortField"
        static let sortDirection = "prefs.defaultSortDirection"
        static let recursiveSearch = "prefs.recursiveSearch"
        static let recoveryAppName = "prefs.recoveryAppName"
        static let recoveryAppScheme = "prefs.recoveryAppScheme"
        static let showHiddenFiles = "prefs.showHiddenFiles"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedMode = defaults.string(forKey: Key.viewMode)
        self.defaultViewMode = storedMode.flatMap(BrowserViewMode.init(rawValue:)) ?? .list

        let field = defaults.string(forKey: Key.sortField).flatMap(SortField.init(rawValue:)) ?? .name
        let direction = defaults.string(forKey: Key.sortDirection)
            .flatMap(SortDirection.init(rawValue:)) ?? .ascending
        self.defaultSort = SortOption(field: field, direction: direction)

        self.recursiveSearch = defaults.bool(forKey: Key.recursiveSearch)
        self.showHiddenFiles = defaults.bool(forKey: Key.showHiddenFiles)

        if let scheme = defaults.string(forKey: Key.recoveryAppScheme), !scheme.isEmpty {
            self.recoveryApp = RecoveryApp(
                name: defaults.string(forKey: Key.recoveryAppName) ?? scheme,
                scheme: scheme
            )
        } else {
            self.recoveryApp = nil
        }
    }

    var defaultViewMode: BrowserViewMode {
        didSet { defaults.set(defaultViewMode.rawValue, forKey: Key.viewMode) }
    }

    var defaultSort: SortOption {
        didSet {
            defaults.set(defaultSort.field.rawValue, forKey: Key.sortField)
            defaults.set(defaultSort.direction.rawValue, forKey: Key.sortDirection)
        }
    }

    var recursiveSearch: Bool {
        didSet { defaults.set(recursiveSearch, forKey: Key.recursiveSearch) }
    }

    var showHiddenFiles: Bool {
        didSet { defaults.set(showHiddenFiles, forKey: Key.showHiddenFiles) }
    }

    /// App offered as a recovery action when a server can't be reached.
    var recoveryApp: RecoveryApp? {
        didSet {
            defaults.set(recoveryApp?.name ?? "", forKey: Key.recoveryAppName)
            defaults.set(recoveryApp?.scheme ?? "", forKey: Key.recoveryAppScheme)
        }
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
