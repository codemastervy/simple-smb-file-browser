import XCTest

/// UI tests for the file-operation behaviours: multi-select delete, and
/// drag-and-drop between panes on iPad and Mac.
///
/// These run against the on-device location seeded by `-uiTestSeedFiles`, so
/// they exercise real file operations without needing an SMB server.
final class FileOperationsUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestSeedFiles"] + extraArguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var isRegularWidth: Bool {
        #if os(macOS)
        return true
        #else
        return XCUIDevice.shared.orientation.isLandscape || UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    /// Opens "On My …" and drills into the seeded UITestFiles folder.
    private func openSeededFolder(_ app: XCUIApplication) {
        element(app, "sidebar.deviceFiles").tap()

        // The row title is device-dependent ("On My iPhone"/"iPad"/"Mac"), so
        // match the one that exists rather than hard-coding a device.
        let candidates = ["On My iPhone", "On My iPad", "On My Mac"]
        var opened = false
        for title in candidates {
            let row = app.staticTexts[title]
            if row.waitForExistence(timeout: 3) {
                row.tap()
                opened = true
                break
            }
        }
        XCTAssertTrue(opened, "Expected an on-device location in the sidebar")

        let folder = app.staticTexts["UITestFiles"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "The seeded folder should be listed")
        folder.tap()

        XCTAssertTrue(
            app.staticTexts["sample-1.txt"].waitForExistence(timeout: 10),
            "The seeded files should be listed"
        )
    }

    // MARK: - Multi-select delete

    func testMultiSelectDeleteRemovesChosenFiles() {
        let app = launch()
        openSeededFolder(app)

        element(app, "browser.select").tap()

        app.staticTexts["sample-1.txt"].tap()
        app.staticTexts["sample-2.txt"].tap()

        let deleteButton = element(app, "browser.batchDelete")
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: 5),
            "The batch action bar should appear once items are selected"
        )
        deleteButton.tap()

        // Scoped to the alert: the batch action bar also has a button labelled
        // "Delete", so an unscoped query matches whether or not the confirmation
        // is actually up.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: 10),
            "Deleting should ask for confirmation. Element tree:\n\(app.debugDescription)"
        )
        alert.buttons["Delete"].tap()

        XCTAssertTrue(
            waitForDisappearance(app.staticTexts["sample-1.txt"], timeout: 10),
            "Deleted files should leave the listing"
        )
        XCTAssertFalse(app.staticTexts["sample-2.txt"].exists)
        XCTAssertTrue(app.staticTexts["sample-3.txt"].exists, "Unselected files must survive")
    }

    func testDeleteCanBeCancelled() {
        let app = launch()
        openSeededFolder(app)

        element(app, "browser.select").tap()
        app.staticTexts["sample-1.txt"].tap()
        element(app, "browser.batchDelete").tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: 10),
            "Deleting should ask for confirmation. Element tree:\n\(app.debugDescription)"
        )

        let cancel = alert.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "The confirmation must offer Cancel")
        cancel.tap()

        XCTAssertTrue(
            app.staticTexts["sample-1.txt"].waitForExistence(timeout: 5),
            "Cancelling the confirmation must not delete anything"
        )
    }

    // MARK: - View mode and sorting

    func testViewModeTogglesBetweenListAndGrid() {
        let app = launch()
        openSeededFolder(app)

        XCTAssertTrue(element(app, "browser.list").waitForExistence(timeout: 10))

        element(app, "browser.viewMode").tap()

        XCTAssertTrue(
            element(app, "browser.grid").waitForExistence(timeout: 5),
            "Toggling the view mode should switch to the grid"
        )
    }

    func testNewFolderCreatesADirectory() {
        let app = launch()
        openSeededFolder(app)

        element(app, "browser.add").tap()
        app.buttons["New Folder"].firstMatch.tap()

        // Matched via the alert rather than by identifier: SwiftUI doesn't
        // reliably forward an accessibilityIdentifier onto a TextField inside an
        // alert.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Expected the New Folder alert")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Created By UI Test")
        alert.buttons["Create"].tap()

        XCTAssertTrue(
            app.staticTexts["Created By UI Test"].waitForExistence(timeout: 10),
            "The new folder should appear in the listing"
        )
    }

    // MARK: - Drag and drop between panes

    func testDragAndDropBetweenPanes() throws {
        try XCTSkipUnless(isRegularWidth, "Dual-pane browsing is iPad and Mac only")

        let app = launch()
        openSeededFolder(app)

        // Open a second pane on the same location via the sidebar context menu.
        let deviceRow = ["On My iPhone", "On My iPad", "On My Mac"]
            .map { app.staticTexts[$0] }
            .first { $0.exists }
        let row = try XCTUnwrap(deviceRow, "Expected an on-device sidebar row")

        #if os(macOS)
        row.rightClick()
        #else
        row.press(forDuration: 1.0)
        #endif

        let openInSecondPane = app.buttons["Open in Second Pane"].firstMatch
        try XCTSkipUnless(
            openInSecondPane.waitForExistence(timeout: 5),
            "Second-pane action unavailable in this configuration"
        )
        openInSecondPane.tap()

        let primaryPane = element(app, "browser.primary.list")
        let secondaryPane = element(app, "browser.secondary.list")
        XCTAssertTrue(primaryPane.waitForExistence(timeout: 15), "Primary pane should be visible")
        XCTAssertTrue(secondaryPane.waitForExistence(timeout: 15), "Second pane should be visible")

        // Drag from the first pane onto the second. Targeting the pane's own
        // element rather than a wrapper: a container identifier resolved as a
        // non-hittable element and the drag had nothing to land on.
        let source = primaryPane.staticTexts["sample-3.txt"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), "Expected sample-3.txt in the first pane")

        // Coordinate-based drag with an explicit velocity and a hold at the end.
        // Element.press(forDuration:thenDragTo:) frequently fails to initiate a
        // SwiftUI .draggable session at all — the lift isn't recognised — whereas
        // the XCUICoordinate variant is the API intended for iPad drag-and-drop.
        let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = secondaryPane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(
            forDuration: 1.0,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 1.5
        )

        // The drop copies with a de-duplicated name rather than clobbering.
        let copied = app.staticTexts["sample-3 2.txt"]
        XCTAssertTrue(
            copied.waitForExistence(timeout: 20),
            "Dropping into the same directory should produce a de-duplicated copy"
        )
    }

    // MARK: - Helpers

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            _ = element.waitForExistence(timeout: 0.5)
        }
        return !element.exists
    }
}
