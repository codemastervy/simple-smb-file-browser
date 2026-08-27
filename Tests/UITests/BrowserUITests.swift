import XCTest

/// UI tests for the behaviours the requirements call out explicitly.
///
/// The app is launched with `-uiTesting` plus seeding flags (see
/// `UITestSupport`), which gives each test isolated UserDefaults, in-memory
/// credentials, and — where needed — an SMB client that always fails. Without
/// that, the connection-failure modal could not be exercised deterministically.
final class BrowserUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launch(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + extraArguments
        app.launch()
        return app
    }

    /// True when the layout shows sidebar and detail at once (iPad, Mac).
    private func isRegularWidth(_ app: XCUIApplication) -> Bool {
        #if os(macOS)
        return true
        #else
        // An iPhone collapses NavigationSplitView into a stack.
        return app.windows.firstMatch.frame.width > 700
        #endif
    }

    private func sidebarRow(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        // The same identifier can surface as different element types across
        // platforms, so match on any descendant.
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - Launch behaviour

    func testLaunchesStraightIntoBrowserWithSavedServer() {
        let app = launch(["-uiTestSeedServer"])

        // No onboarding screen: the sidebar is present immediately.
        XCTAssertTrue(
            sidebarRow(app, "sidebar.addServer").waitForExistence(timeout: 10),
            "The sidebar should be on screen at launch, with no onboarding step"
        )
        // The seeded server is the default, so it is selected automatically.
        XCTAssertTrue(app.staticTexts["UI Test NAS"].waitForExistence(timeout: 10))
    }

    func testNoServersShowsInlinePromptNotABlockingModal() {
        let app = launch()

        let addServerRow = sidebarRow(app, "sidebar.addServer")
        XCTAssertTrue(addServerRow.waitForExistence(timeout: 10))
        // The sidebar remains usable, which is what makes the prompt inline
        // rather than modal.
        XCTAssertTrue(addServerRow.isHittable)
        XCTAssertTrue(sidebarRow(app, "sidebar.deviceFiles").exists)

        if isRegularWidth(app) {
            XCTAssertTrue(
                sidebarRow(app, "detail.noServers").waitForExistence(timeout: 5),
                "The detail column should offer the inline add-server prompt"
            )
        }
    }

    // MARK: - Device Files

    func testDeviceFilesIsCollapsedOnLaunchAndExpandsOnTap() {
        let app = launch()

        let disclosure = sidebarRow(app, "sidebar.deviceFiles")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10))

        // Collapsed on every launch by requirement.
        XCTAssertFalse(
            app.staticTexts["iCloud Drive"].exists,
            "Device Files should start collapsed, hiding its children"
        )

        disclosure.tap()

        XCTAssertTrue(
            app.staticTexts["iCloud Drive"].waitForExistence(timeout: 5),
            "Tapping Device Files should reveal its locations"
        )
    }

    func testDeviceFilesStaysCollapsedOnRelaunch() {
        let app = launch()
        let disclosure = sidebarRow(app, "sidebar.deviceFiles")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
        disclosure.tap()
        XCTAssertTrue(app.staticTexts["iCloud Drive"].waitForExistence(timeout: 5))

        app.terminate()
        let relaunched = launch()

        XCTAssertTrue(sidebarRow(relaunched, "sidebar.deviceFiles").waitForExistence(timeout: 10))
        XCTAssertFalse(
            relaunched.staticTexts["iCloud Drive"].exists,
            "Expansion must not persist across launches"
        )
    }

    // MARK: - Add server

    func testAddServerFlow() {
        let app = launch()

        sidebarRow(app, "sidebar.addServer").tap()

        let hostField = app.textFields["serverForm.host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 5), "The add-server form should appear")

        app.textFields["serverForm.name"].tap()
        app.textFields["serverForm.name"].typeText("Test Server")
        hostField.tap()
        hostField.typeText("10.0.0.9")
        app.textFields["serverForm.share"].tap()
        app.textFields["serverForm.share"].typeText("Public")

        let save = app.buttons["serverForm.save"]
        XCTAssertTrue(save.isEnabled, "Save should enable once host and share are filled")
        save.tap()

        XCTAssertTrue(
            app.staticTexts["Test Server"].waitForExistence(timeout: 10),
            "The saved server should appear in the sidebar"
        )
    }

    func testAddServerSaveIsDisabledWithoutRequiredFields() {
        let app = launch()

        sidebarRow(app, "sidebar.addServer").tap()
        XCTAssertTrue(app.textFields["serverForm.host"].waitForExistence(timeout: 5))

        XCTAssertFalse(
            app.buttons["serverForm.save"].isEnabled,
            "Save should stay disabled until the required fields are present"
        )
    }

    // MARK: - Connection failure modal

    func testFailureModalAppearsOnConnectionTimeout() {
        let app = launch(["-uiTestSeedServer", "-uiTestFailure", "timedOut"])

        let modal = sidebarRow(app, "failureModal")
        XCTAssertTrue(modal.waitForExistence(timeout: 15), "A failed auto-connect should raise the failure modal")

        XCTAssertTrue(app.staticTexts["Connection Timed Out"].exists)
        XCTAssertTrue(app.buttons["failureModal.retry"].exists)
        XCTAssertTrue(app.buttons["failureModal.openSettings"].exists)
    }

    func testFailureModalShowsRecoveryAppWhenConfigured() {
        let app = launch([
            "-uiTestSeedServer", "-uiTestFailure", "timedOut", "-uiTestRecoveryApp",
        ])

        XCTAssertTrue(sidebarRow(app, "failureModal").waitForExistence(timeout: 15))

        let recovery = app.buttons["failureModal.recoveryApp"]
        XCTAssertTrue(recovery.exists, "A timeout with a configured recovery app should offer it")
        XCTAssertTrue(recovery.label.contains("Test VPN"))
    }

    func testFailureModalHidesRecoveryAppWhenNotConfigured() {
        let app = launch(["-uiTestSeedServer", "-uiTestFailure", "timedOut"])

        XCTAssertTrue(sidebarRow(app, "failureModal").waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["failureModal.recoveryApp"].exists)
    }

    func testFailureModalAuthFailureLeadsWithEditConnection() {
        let app = launch(["-uiTestSeedServer", "-uiTestFailure", "authenticationFailed"])

        XCTAssertTrue(sidebarRow(app, "failureModal").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Sign-In Failed"].exists)
        XCTAssertTrue(
            app.buttons["failureModal.editConnection"].exists,
            "A rejected password should offer editing the connection"
        )
    }

    func testFailureModalEditConnectionOpensForm() {
        let app = launch(["-uiTestSeedServer", "-uiTestFailure", "authenticationFailed"])
        XCTAssertTrue(sidebarRow(app, "failureModal").waitForExistence(timeout: 15))

        app.buttons["failureModal.editConnection"].tap()

        XCTAssertTrue(
            app.textFields["serverForm.host"].waitForExistence(timeout: 10),
            "Edit Connection should open the server form"
        )
    }

    func testFailureModalOpenSettingsShowsSettings() {
        let app = launch(["-uiTestSeedServer", "-uiTestFailure", "timedOut"])
        XCTAssertTrue(sidebarRow(app, "failureModal").waitForExistence(timeout: 15))

        app.buttons["failureModal.openSettings"].tap()

        XCTAssertTrue(
            sidebarRow(app, "settings").waitForExistence(timeout: 10),
            "Open Settings should present the settings screen"
        )
    }

    func testFailureModalRetryReattemptsAndKeepsModalOnRepeatedFailure() {
        let app = launch(["-uiTestSeedServer", "-uiTestFailure", "timedOut"])
        XCTAssertTrue(sidebarRow(app, "failureModal").waitForExistence(timeout: 15))

        app.buttons["failureModal.retry"].tap()

        // The seeded client always fails, so a retry must surface the failure
        // again rather than silently leaving the user on an empty browser.
        XCTAssertTrue(
            sidebarRow(app, "failureModal").waitForExistence(timeout: 15),
            "Retry against a still-broken server should report the failure again"
        )
    }

    func testFailureModalDismissReturnsToBrowser() {
        let app = launch(["-uiTestSeedServer", "-uiTestFailure", "timedOut"])
        XCTAssertTrue(sidebarRow(app, "failureModal").waitForExistence(timeout: 15))

        app.buttons["failureModal.dismiss"].tap()

        XCTAssertTrue(
            sidebarRow(app, "sidebar.addServer").waitForExistence(timeout: 10),
            "Dismissing should leave the app on the browser, not a dead end"
        )
    }

    // MARK: - Settings

    func testSettingsOpensAndShowsRecoveryAppPicker() {
        let app = launch()

        sidebarRow(app, "sidebar.settings").tap()

        XCTAssertTrue(sidebarRow(app, "settings").waitForExistence(timeout: 10))
        XCTAssertTrue(sidebarRow(app, "settings.recoveryAppPicker").exists)
    }

    func testTransfersPanelOpens() {
        let app = launch()

        sidebarRow(app, "sidebar.transfers").tap()

        XCTAssertTrue(sidebarRow(app, "transfersPanel").waitForExistence(timeout: 10))
    }
}
