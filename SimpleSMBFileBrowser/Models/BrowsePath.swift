import Foundation

/// Path arithmetic for browser locations.
///
/// SMB and POSIX paths differ in one annoying way: AMSMB2 treats `"/"` as the
/// share root and accepts share-relative paths without a leading slash, while
/// local paths are absolute. Centralising the joins here keeps that difference
/// from leaking into every view model.
enum BrowsePath {
    static let smbRoot = "/"

    /// Appends a single component to a directory path.
    ///
    /// Joining onto the root yields an absolute path ("/Movies"), matching the
    /// `.pathKey` values AMSMB2 returns from a listing. Keeping the two forms
    /// identical means a path the app builds and a path the server reported are
    /// interchangeable.
    static func appending(_ component: String, to directory: String) -> String {
        guard !directory.isEmpty else { return component }
        guard directory != smbRoot else { return smbRoot + component }
        return directory.hasSuffix("/") ? directory + component : directory + "/" + component
    }

    /// The parent of `path`, or `nil` when already at the root.
    static func parent(of path: String) -> String? {
        guard path != smbRoot, !path.isEmpty else { return nil }
        var components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        components.removeLast()
        if components.isEmpty {
            return path.hasPrefix("/") ? smbRoot : ""
        }
        let joined = components.joined(separator: "/")
        return path.hasPrefix("/") ? "/" + joined : joined
    }

    /// Breadcrumb trail from the root down to `path`, as `(title, path)` pairs.
    /// The first element is always the root, labelled by `rootTitle`.
    static func breadcrumbs(for path: String, rootTitle: String) -> [(title: String, path: String)] {
        var trail: [(title: String, path: String)] = [(rootTitle, smbRoot)]
        let absolute = path.hasPrefix("/")
        var accumulated = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            accumulated = accumulated.isEmpty ? String(component) : accumulated + "/" + component
            trail.append((String(component), absolute ? "/" + accumulated : accumulated))
        }
        return trail
    }

    /// Splits a filename into base and extension so "report.pdf" can be renamed
    /// to "report 2.pdf" when resolving a collision.
    static func uniqueName(for name: String, avoiding existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }
}
