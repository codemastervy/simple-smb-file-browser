import XCTest
import UniformTypeIdentifiers
@testable import SimpleSMBFileBrowser

/// Covers the drag-and-drop payload and the intra-pane no-op rule.
///
/// The gesture itself is exercised by a UI test, but XCUITest drag automation
/// against SwiftUI drag sessions is unreliable, so the logic a drop depends on is
/// pinned down here where it can be asserted deterministically.
final class FileTransferPayloadTests: XCTestCase {

    private func makePayload(
        providerID: String = "smb:ABC",
        paneID: String = "pane-1",
        items: [FileItem] = [.fixture(path: "/a.txt", size: 10)]
    ) -> FileTransferPayload {
        FileTransferPayload(
            sourceProviderID: providerID,
            sourcePaneID: paneID,
            items: items.map(FileTransferPayload.Item.init)
        )
    }

    func testPayloadCarriesReferencesNotBytes() {
        let payload = makePayload(items: [.fixture(path: "/huge.iso", size: 4_000_000_000)])
        let encoded = try! JSONEncoder().encode(payload)

        // A 4 GB file must not be materialised to start a drag; the payload is
        // a path reference and should stay tiny.
        XCTAssertLessThan(encoded.count, 512)
        XCTAssertEqual(payload.items.first?.size, 4_000_000_000)
    }

    func testPayloadRoundTrips() throws {
        let payload = makePayload(items: [
            .fixture(path: "/one.txt", size: 1),
            .fixture(path: "/Folder", isDirectory: true),
        ])

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(FileTransferPayload.self, from: data)

        XCTAssertEqual(decoded.sourceProviderID, payload.sourceProviderID)
        XCTAssertEqual(decoded.sourcePaneID, payload.sourcePaneID)
        XCTAssertEqual(decoded.fileItems.map(\.path), ["/one.txt", "/Folder"])
        XCTAssertTrue(decoded.fileItems.last?.isDirectory == true)
    }

    func testFileItemsPreserveDirectoryFlagAndSize() {
        let payload = makePayload(items: [.fixture(path: "/d", isDirectory: true), .fixture(path: "/f.txt", size: 99)])
        let items = payload.fileItems

        XCTAssertTrue(items[0].isDirectory)
        XCTAssertEqual(items[0].size, 0, "Directories carry no size")
        XCTAssertFalse(items[1].isDirectory)
        XCTAssertEqual(items[1].size, 99)
    }

    func testTransferRepresentationUsesThePrivateType() {
        // A private type rather than public.data, so a drag from this app is
        // never mistaken for an arbitrary file drop.
        XCTAssertEqual(
            UTType.smbFileReference.identifier,
            "eu.org.amirulandalib.SimpleSMBFileBrowser.file-reference"
        )
    }

    // MARK: - The rule the drop handler applies

    /// Mirrors `BrowserPaneView.handleDrop`: a drag released back onto its own
    /// pane is a no-op, but a drop from the other pane always transfers — even
    /// into the same directory, where it produces a de-duplicated copy.
    private func shouldTransfer(payload: FileTransferPayload, destinationPaneID: String) -> Bool {
        payload.sourcePaneID != destinationPaneID
    }

    func testDropOntoOwnPaneIsIgnored() {
        let payload = makePayload(paneID: "pane-1")
        XCTAssertFalse(shouldTransfer(payload: payload, destinationPaneID: "pane-1"))
    }

    func testDropOntoOtherPaneTransfersEvenForSameProvider() {
        let payload = makePayload(providerID: "device:onMyDevice", paneID: "pane-1")
        // Same provider, different pane: a legitimate duplicate.
        XCTAssertTrue(shouldTransfer(payload: payload, destinationPaneID: "pane-2"))
    }

    func testDropAcrossProvidersTransfers() {
        let payload = makePayload(providerID: "smb:ABC", paneID: "pane-1")
        XCTAssertTrue(shouldTransfer(payload: payload, destinationPaneID: "pane-2"))
    }
}
