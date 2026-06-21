//
//  MyInventoryUITests.swift
//  MyInventoryUITests
//
//  End-to-end UI coverage: launch state, the cross-context global search, and
//  context drill-down. Every test launches the app with `-uiTesting`, which makes
//  it use a throwaway in-memory store seeded with deterministic sample data
//  (SeedData.seedUITestSampleIfNeeded) and stay on the sidebar — so each run starts
//  from a known state and never touches the user's real data.
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

    /// The app launches onto the sidebar showing the three seeded contexts and the
    /// app-wide search field.
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

    /// Selecting a context shows that context's items in the content column.
    @MainActor
    func testContextListShowsSeededItem() throws {
        let app = launchApp()

        let vehicle = app.staticTexts["Vehicle"]
        XCTAssertTrue(vehicle.waitForExistence(timeout: 10))
        vehicle.tap()

        // The item card combines its accessibility into one label
        // ("First Aid Kit, <status>"), so match on a substring.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "First Aid Kit"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    /// Adding a context from the sidebar makes it appear in the list.
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

        // Grant notifications → requestAuthorization + an authorized rescheduleAll
        // over the seeded same-day dues (batch path) + the inactivity nudge.
        let enable = app.buttons["Enable Notifications"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        enable.tap()

        // The system permission alert is owned by Springboard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        // Authorization completed once the "Enable Notifications" button is gone
        // (status left .notDetermined). `enableNotifications` fires the reschedule
        // immediately afterwards.
        XCTAssertTrue(enable.waitForNonExistence(timeout: 12),
                      "Enable button should disappear once authorized")

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
}
