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
}
