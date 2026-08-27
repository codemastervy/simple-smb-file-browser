import Foundation
import UniformTypeIdentifiers

/// A single entry in a browsable directory.
///
/// `FileItem` is deliberately backend-agnostic: the same type represents an
/// entry on an SMB share, in iCloud Drive, or on the local filesystem, so the
/// browser UI can be written once and reused across every location. See
/// `BrowserLocation` for the set of backends.
struct FileItem: Identifiable, Hashable, Sendable {
    /// Backend-relative path. For SMB this is relative to the share root using
    /// forward slashes (AMSMB2's convention, where `"/"` is the root). For local
    /// and iCloud locations this is an absolute POSIX path.
    let path: String
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    /// Size in bytes. Always 0 for directories — SMB does not report a
    /// meaningful recursive size without walking the tree.
    let size: Int64
    let modifiedDate: Date?
    let creationDate: Date?

    var id: String { path }

    init(
        path: String,
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool = false,
        size: Int64 = 0,
        modifiedDate: Date? = nil,
        creationDate: Date? = nil
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modifiedDate = modifiedDate
        self.creationDate = creationDate
    }
}

// MARK: - Derived presentation values

extension FileItem {
    var fileExtension: String {
        isDirectory ? "" : (name as NSString).pathExtension.lowercased()
    }

    /// Best-effort content type inferred from the filename. SMB gives us no MIME
    /// information, so the extension is all we have to go on.
    var contentType: UTType? {
        guard !isDirectory else { return .folder }
        guard !fileExtension.isEmpty else { return nil }
        return UTType(filenameExtension: fileExtension)
    }

    /// True when QuickLook is likely to render this without a full download.
    var isPreviewable: Bool {
        guard let contentType else { return false }
        return contentType.conforms(to: .image)
            || contentType.conforms(to: .pdf)
            || contentType.conforms(to: .text)
            || contentType.conforms(to: .audiovisualContent)
    }

    var symbolName: String {
        if isDirectory { return "folder.fill" }
        guard let contentType else { return "doc" }
        if contentType.conforms(to: .image) { return "photo" }
        if contentType.conforms(to: .pdf) { return "doc.richtext" }
        if contentType.conforms(to: .movie) || contentType.conforms(to: .video) { return "film" }
        if contentType.conforms(to: .audio) { return "music.note" }
        if contentType.conforms(to: .archive) { return "doc.zipper" }
        if contentType.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if contentType.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    var formattedSize: String? {
        guard !isDirectory else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
