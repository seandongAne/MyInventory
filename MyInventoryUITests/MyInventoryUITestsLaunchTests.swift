//
//  MyInventoryUITestsLaunchTests.swift
//  MyInventoryUITests
//
//  Created by Sean Dong on 2026-06-08.
//

import XCTest

final class MyInventoryUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]   // clean in-memory store + seeded sample data
        app.launch()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
