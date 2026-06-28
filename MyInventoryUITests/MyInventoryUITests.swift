//
//  MyInventoryUITests.swift
//  MyInventoryUITests
//
//  End-to-end UI coverage: launch state, the cross-context global search, and
//  selecting a program. Every test launches the app with `-uiTesting`, which makes
//  it use a throwaway in-memory store seeded with deterministic sample data
//  (SeedData.seedUITestSampleIfNeeded) and start on the Programs placeholder (no
//  program selected) — so each run starts from a known state and never touches the
//  user's real data.
//

import XCTest

final class MyInventoryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
        return app
    }

    /// The app launches showing the three seeded programs in the Programs bar and
    /// the app-wide search field.
    @MainActor
    func testLaunchShowsContextsAndGlobalSearch() throws {
        let app = launchApp()
        XCTAssertTrue(app.staticTexts["Vehicle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Bag"].exists)
        XCTAssertTrue(app.staticTexts["House"].exists)
        XCTAssertTrue(app.searchFields["Search all supplies"].exists)
    }

    /// The headline feature: a sidebar search finds an item that lives in a
    /// *different* context and tapping it opens that item's detail.
    @MainActor
    func testGlobalSearchFindsItemAcrossContexts() throws {
        let app = launchApp()

        let search = app.searchFields["Search all supplies"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("tuna")

        // "Canned Tuna" is seeded under House — it must surface from the sidebar.
        let result = app.staticTexts["Canned Tuna"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()

        // Tapping the result opens the item's detail (its title is the item name).
        XCTAssertTrue(app.navigationBars["Canned Tuna"].waitForExistence(timeout: 5))
    }

    /// Selecting a program from the Programs bar shows that context's items below.
    @MainActor
    func testContextListShowsSeededItem() throws {
        let app = launchApp()

        let vehicle = app.staticTexts["Vehicle"]
        XCTAssertTrue(vehicle.waitForExistence(timeout: 10))
        vehicle.tap()

        // The item card shows the item name as a static text.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "First Aid Kit"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    /// Adding a context from the Programs bar makes it appear as a new program card.
    @MainActor
    func testAddContextAppearsInSidebar() throws {
        let app = launchApp()
        XCTAssertTrue(app.staticTexts["Vehicle"].waitForExistence(timeout: 10))

        app.buttons["Add Context"].tap()

        let nameField = app.alerts.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Cabin")
        app.alerts.buttons["Add"].tap()

        XCTAssertTrue(app.staticTexts["Cabin"].waitForExistence(timeout: 5))
    }

    // NOTE: Deleting a context (swipe-to-delete → confirm) is covered at the model
    // level by MyInventoryTests.testDeletingContextDeletesItemsLeavingNoOrphans,
    // which proves the orphan-safe deletion. A UI test for it is intentionally
    // omitted: automating swipe-to-delete on a NavigationSplitView sidebar row is
    // unreliable (the swipe is interpreted as row selection, navigating into the
    // context instead of revealing the Delete action). The UI trigger itself is the
    // same .onDelete + confirmationDialog pattern used by CategoryManagerView.

    /// Runtime check for the day-batched reminders + inactivity nudge: granting
    /// notification permission triggers an AUTHORIZED `rescheduleAll`. With
    /// `-seedBatch` the store holds three same-interval items checked today, so
    /// their dues collapse onto one day and the planner takes the BATCH branch —
    /// the exact integration the (process-isolated) unit tests can't drive. We
    /// assert the app survives that pass and reports NO scheduling failure.
    @MainActor
    func testGrantingNotificationsReschedulesBatchedDuesWithoutFailure() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "-seedBatch"]
        app.launch()

        // App is up.
        XCTAssertTrue(app.staticTexts["Vehicle"].waitForExistence(timeout: 10))

        // Open Settings (gear button → sheet).
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        // The batched-dues reschedule runs on launch (refreshNotifications) AND
        // again if we grant permission here. Notification authorization is
        // SIMULATOR-WIDE and survives between runs, so "Enable Notifications" only
        // appears while the status is still .notDetermined (first run after a
        // privacy reset). Drive the grant when it's offered; otherwise the app is
        // already authorized/denied and the launch reschedule already exercised the
        // batch path — either way the assertion below is identical. (This keeps the
        // test deterministic without depending on a pre-run `simctl privacy reset`.)
        let enable = app.buttons["Enable Notifications"]
        if enable.waitForExistence(timeout: 5) {
            enable.tap()
            // The system permission alert is owned by Springboard.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 8) { allow.tap() }
            // `enableNotifications` fires the authorized rescheduleAll once the
            // button disappears (status left .notDetermined).
            XCTAssertTrue(enable.waitForNonExistence(timeout: 12),
                          "Enable button should disappear once authorized")
        }

        // Let the async reschedule (batch + nudge) settle, then assert NO failure
        // surfaced — the failure Label renders only when a reminder fails to add.
        Thread.sleep(forTimeInterval: 3)
        let failure = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "couldn't be scheduled")).firstMatch
        XCTAssertFalse(failure.exists, "No reminder should fail to schedule")

        // App is still responsive (no crash in the authorized batch pass).
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Vehicle"].waitForExistence(timeout: 5))
    }

    /// The JSON backup goes through the system share sheet (so it can be emailed /
    /// saved to Files / sent to a computer). The `ShareLink` only renders once
    /// `prepareBackup()` has successfully written the file — so its appearance is
    /// itself proof that the export ran at runtime without crashing — and tapping
    /// it must present the share sheet.
    @MainActor
    func testExportSharesBackupViaShareSheet() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Vehicle"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()

        // Backup prepared OK → the share button is shown (not stuck on
        // "Preparing backup…") and no export-failed alert appeared. On iPad the
        // Settings sheet is a shorter page sheet whose List lazily renders rows, so
        // export/restore (near the bottom) may start below the fold — scroll down
        // until the lower of the two (Restore) is rendered; Export sits just above.
        let export = app.buttons["Export All Data…"]
        let restore = app.buttons["Restore from Backup…"]
        var scrolls = 0
        while !restore.exists && scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(export.waitForExistence(timeout: 6),
                      "Backup should be prepared and the Export share button shown")
        XCTAssertFalse(app.alerts["Export failed"].exists)

        // The restore counterpart is offered alongside export (it opens a system
        // file picker, which is owned by another process and not driven here).
        XCTAssertTrue(restore.exists,
                      "Restore should be offered next to Export")

        // Tapping opens the system share UI (a popover on iPad; identifiers vary by
        // iOS version, so accept the activity container, the ubiquitous Copy action,
        // or the popover itself).
        export.tap()
        let appeared = app.otherElements["ActivityListView"].waitForExistence(timeout: 6)
            || app.buttons["Copy"].waitForExistence(timeout: 2)
            || app.popovers.firstMatch.waitForExistence(timeout: 2)
        XCTAssertTrue(appeared, "Tapping Export should present the system share sheet")
    }

    /// First-run guide: the welcome cards appear and can be completed with the
    /// visible buttons (never relying on the swipe being discovered). `-showOnboarding`
    /// forces the guide regardless of the persisted flag.
    @MainActor
    func testWelcomeGuideCanBeCompleted() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "-showOnboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to MyInventory"].waitForExistence(timeout: 10))

        for _ in 0..<3 {
            let cont = app.buttons["Continue"]
            XCTAssertTrue(cont.waitForExistence(timeout: 5))
            cont.tap()
        }
        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
        getStarted.tap()

        // Guide closed, back in the app (no crash). On compact iPhone there are no
        // coach-marks, so the sidebar with the seeded contexts is shown.
        XCTAssertTrue(app.staticTexts["Vehicle"].waitForExistence(timeout: 8))
    }

    /// The card's inline "Check" button is borderless: a tap checks the item in
    /// place rather than pushing its detail. Captures a screenshot as evidence.
    @MainActor
    func testItemRowCheckButtonChecksInPlace() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()

        let vehicle = app.staticTexts["Vehicle"]
        XCTAssertTrue(vehicle.waitForExistence(timeout: 10))
        vehicle.tap()

        XCTAssertTrue(app.staticTexts["First Aid Kit"].waitForExistence(timeout: 8))

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "context-grid-with-check-button"
        shot.lifetime = .keepAlways
        add(shot)

        // The card exposes a labeled "Check" button (sitting outside the card's
        // navigation link), so tap it directly.
        let check = app.buttons["Check"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        check.tap()

        // The check fired in place — it did NOT push the item detail (which would
        // add a "First Aid Kit" navigation bar). We stay on the main screen.
        XCTAssertTrue(app.navigationBars["Supplies Check"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["First Aid Kit"].exists,
                       "Tapping Check must check in place, not open the detail")
    }
}
