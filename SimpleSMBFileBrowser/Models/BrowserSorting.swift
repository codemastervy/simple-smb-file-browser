import Foundation

enum SortField: String, CaseIterable, Codable, Sendable {
    case name, dateModified, size, type

    var title: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        case .size: return "Size"
        case .type: return "Type"
        }
    }

    var symbolName: String {
        switch self {
        case .name: return "textformat"
        case .dateModified: return "calendar"
        case .size: return "arrow.up.arrow.down.square"
        case .type: return "tag"
        }
    }
}

enum SortDirection: String, CaseIterable, Codable, Sendable {
    case ascending, descending

    var toggled: SortDirection { self == .ascending ? .descending : .ascending }
    var symbolName: String { self == .ascending ? "chevron.up" : "chevron.down" }
}

struct SortOption: Equatable, Codable, Sendable {
    var field: SortField = .name
    var direction: SortDirection = .ascending

    static let `default` = SortOption()
}

enum BrowserViewMode: String, CaseIterable, Codable, Sendable {
    case list, grid

    var symbolName: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    var toggled: BrowserViewMode { self == .list ? .grid : .list }
}

extension Array where Element == FileItem {
    /// Sorts with directories pinned above files, which is what every file
    /// browser does and what users expect regardless of the active sort field.
    func sorted(by option: SortOption) -> [FileItem] {
        let ascending = option.direction == .ascending
        return sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let ordered: Bool
            switch option.field {
            case .name:
                ordered = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .dateModified:
                ordered = (lhs.modifiedDate ?? .distantPast) < (rhs.modifiedDate ?? .distantPast)
            case .size:
                ordered = lhs.size < rhs.size
            case .type:
                let l = lhs.fileExtension, r = rhs.fileExtension
                ordered = l == r
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : l.localizedStandardCompare(r) == .orderedAscending
            }
            return ascending ? ordered : !ordered
        }
    }
}
