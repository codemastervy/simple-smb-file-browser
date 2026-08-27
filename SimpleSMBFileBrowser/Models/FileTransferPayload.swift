import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Private type used only for in-app drags between browser panes. Declared
    /// in Info.plist under UTExportedTypeDeclarations; a custom type is used
    /// rather than public.data so a drag from this app is never mistaken for an
    /// arbitrary file drop.
    static let smbFileReference = UTType(
        exportedAs: "eu.org.amirulandalib.SimpleSMBFileBrowser.file-reference"
    )
}

/// What actually travels during a drag: a reference to items in a pane, not
/// their bytes. The drop side asks the coordinator to do the transfer, so a
/// 4 GB file never has to be materialised to start a drag.
struct FileTransferPayload: Codable, Transferable, Sendable {
    /// `FileProviding.providerID` of the pane the drag started in.
    let sourceProviderID: String
    /// Identifies the specific pane, so a drag released back onto its own pane
    /// can be treated as a no-op without also blocking a cross-pane drop onto
    /// the same directory (which is a legitimate duplicate).
    let sourcePaneID: String
    let items: [Item]

    struct Item: Codable, Sendable {
        let path: String
        let name: String
        let isDirectory: Bool
        let size: Int64

        init(_ item: FileItem) {
            self.path = item.path
            self.name = item.name
            self.isDirectory = item.isDirectory
            self.size = item.size
        }

        var fileItem: FileItem {
            FileItem(path: path, name: name, isDirectory: isDirectory, size: size)
        }
    }

    var fileItems: [FileItem] { items.map(\.fileItem) }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .smbFileReference)
    }
}
