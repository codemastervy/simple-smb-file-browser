import Foundation
import Observation

/// Drives one browser pane.
///
/// Backed by a `FileProviding`, so the same view model serves an SMB share,
/// iCloud Drive, or the local filesystem without branching — which is what
/// keeps the browser behaviour identical across all of them.
@MainActor
@Observable
final class FileBrowserViewModel {
    let provider: any FileProviding
    let location: BrowserLocation
    /// Stable per-pane identity. View models are cached by location, so this
    /// lives as long as the pane does.
    let paneID = UUID().uuidString

    private(set) var path: String
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    /// Set when loading or an operation failed. For remote providers this drives
    /// the full-screen failure modal; for local ones, an inline message.
    private(set) var failure: BrowseFailure?

    var searchText = ""
    var recursiveSearch: Bool
    var sort: SortOption
    var viewMode: BrowserViewMode
    /// Selected item paths. Paths rather than indices so selection survives a
    /// refresh that reorders the listing.
    var selection: Set<String> = []

    private let preferences: AppPreferences
    private var loadTask: Task<Void, Never>?

    init(
        provider: any FileProviding,
        location: BrowserLocation,
        preferences: AppPreferences
    ) {
        self.provider = provider
        self.location = location
        self.preferences = preferences
        self.path = provider.rootPath
        self.sort = preferences.defaultSort
        self.viewMode = preferences.defaultViewMode
        self.recursiveSearch = preferences.recursiveSearch
    }

    // MARK: - Derived state

    /// Items after search filtering and sorting.
    var displayedItems: [FileItem] {
        var result = items
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        if !preferences.showHiddenFiles {
            result = result.filter { !$0.name.hasPrefix(".") }
        }
        return result.sorted(by: sort)
    }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.id) }
    }

    var isAtRoot: Bool { path == provider.rootPath }
    var canGoUp: Bool { !isAtRoot }

    var breadcrumbs: [(title: String, path: String)] {
        guard !isAtRoot else { return [(provider.label, provider.rootPath)] }
        if provider.isRemote {
            return BrowsePath.breadcrumbs(for: path, rootTitle: provider.label)
        }
        // Local paths are absolute; show the trail relative to the provider root
        // so the user isn't shown their whole container path.
        let relative = path.hasPrefix(provider.rootPath)
            ? String(path.dropFirst(provider.rootPath.count))
            : path
        var trail: [(title: String, path: String)] = [(provider.label, provider.rootPath)]
        var accumulated = provider.rootPath
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            accumulated = provider.joining(String(component), to: accumulated)
            trail.append((String(component), accumulated))
        }
        return trail
    }

    var isEmptyDirectory: Bool {
        !isLoading && failure == nil && displayedItems.isEmpty
    }

    // MARK: - Navigation

    func load() async {
        loadTask?.cancel()
        let task = Task { @MainActor in
            isLoading = true
            defer { isLoading = false }
            do {
                try await provider.connect()
                let query = searchText.trimmingCharacters(in: .whitespaces)
                let recursive = recursiveSearch && !query.isEmpty
                let loaded = try await provider.list(at: path, recursive: recursive)
                guard !Task.isCancelled else { return }
                items = loaded
                failure = nil
            } catch is CancellationError {
                // Superseded by a newer load; leave existing items in place.
            } catch {
                guard !Task.isCancelled else { return }
                items = []
                failure = BrowseFailure(error: error, target: provider.label)
            }
        }
        loadTask = task
        await task.value
    }

    func refresh() async {
        await load()
    }

    func navigate(to newPath: String) async {
        guard newPath != path else { return }
        path = newPath
        selection.removeAll()
        await load()
    }

    func open(_ item: FileItem) async {
        guard item.isDirectory else { return }
        await navigate(to: item.path)
    }

    func goUp() async {
        guard canGoUp else { return }
        let parent: String
        if provider.isRemote {
            parent = BrowsePath.parent(of: path) ?? provider.rootPath
        } else {
            let candidate = (path as NSString).deletingLastPathComponent
            parent = candidate.count < provider.rootPath.count ? provider.rootPath : candidate
        }
        await navigate(to: parent)
    }

    func goToRoot() async {
        await navigate(to: provider.rootPath)
    }

    /// Re-runs the listing when the recursive-search toggle changes, since
    /// recursion happens provider-side rather than in `displayedItems`.
    func searchModeChanged() async {
        await load()
    }

    // MARK: - Operations

    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform {
            let target = self.provider.joining(trimmed, to: self.path)
            try await self.provider.createDirectory(at: target)
        }
    }

    func rename(_ item: FileItem, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        await perform {
            try await self.provider.rename(item, to: trimmed)
        }
    }

    func delete(_ itemsToDelete: [FileItem]) async {
        guard !itemsToDelete.isEmpty else { return }
        await perform {
            // Deleting many: keep going after a failure so one locked file does
            // not strand the rest, then surface the first problem.
            var firstFailure: BrowseFailure?
            for item in itemsToDelete {
                do {
                    try await self.provider.delete(item)
                } catch {
                    firstFailure = firstFailure ?? BrowseFailure(error: error, target: self.provider.label)
                }
            }
            self.selection.removeAll()
            if let firstFailure { throw firstFailure }
        }
    }

    /// Clears a failure so the modal can be dismissed and a retry attempted.
    func clearFailure() {
        failure = nil
    }

    func retry() async {
        failure = nil
        await load()
    }

    /// Runs a mutating operation then reloads, recording any failure.
    private func perform(_ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            await load()
        } catch {
            failure = BrowseFailure(error: error, target: provider.label)
        }
    }
}
