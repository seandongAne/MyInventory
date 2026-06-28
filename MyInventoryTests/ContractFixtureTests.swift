//
//  ContractFixtureTests.swift
//  MyInventoryTests
//
//  Asserts iOS due-date math against the SHARED cross-platform contract fixtures
//  (docs/fixtures/contract-fixtures.json). The Android app's test suite asserts
//  against a byte-identical copy, so passing here on both sides guarantees the
//  two apps compute the same next-due dates from the same inputs.
//
//  The fixture file is read straight from the source tree via #filePath (tests
//  run locally with the repo present), so there's no bundle-resource wiring.
//

import XCTest
import Foundation
@testable import MyInventory

final class ContractFixtureTests: XCTestCase {

    private struct Fixtures: Decodable {
        struct NextDueCase: Decodable {
            let id: String
            let lastChecked: String
            let value: Int
            let unit: String
            let nextDue: String
        }
        struct DaysCase: Decodable {
            let id: String
            let today: String
            let nextDue: String
            let days: Int
        }
        let nextDueCases: [NextDueCase]
        let daysUntilDueCases: [DaysCase]
    }

    /// UTC Gregorian calendar so calendar-date math is timezone-independent and
    /// matches the Android side (which computes in UTC).
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Parse "YYYY-MM-DD" as a UTC start-of-day instant.
    private func date(_ iso: String) -> Date {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    private func loadFixtures() throws -> Fixtures {
        // <repo>/MyInventoryTests/ContractFixtureTests.swift -> <repo>
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appending(path: "docs/fixtures/contract-fixtures.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixtures.self, from: data)
    }

    func testNextDueDateMatchesSharedContract() throws {
        let fixtures = try loadFixtures()
        for c in fixtures.nextDueCases {
            let item = SupplyItem(name: c.id)
            item.intervalValue = c.value
            item.intervalUnit = c.unit
            let check = CheckRecord(date: date(c.lastChecked))
            item.checks = [check]

            let due = item.nextDueDate(calendar: calendar)
            XCTAssertEqual(due, date(c.nextDue),
                           "nextDue mismatch for case \(c.id): \(c.lastChecked) + \(c.value) \(c.unit)")
        }
    }

    func testDaysUntilDueMatchesSharedContract() throws {
        let fixtures = try loadFixtures()
        for c in fixtures.daysUntilDueCases {
            // Construct an item whose next-due lands exactly on c.nextDue: a 1-day
            // interval checked on the day before.
            let dayBefore = calendar.date(byAdding: .day, value: -1, to: date(c.nextDue))!
            let item = SupplyItem(name: c.id)
            item.intervalValue = 1
            item.intervalUnit = IntervalUnit.days.rawValue
            item.checks = [CheckRecord(date: dayBefore)]

            XCTAssertEqual(item.nextDueDate(calendar: calendar), date(c.nextDue),
                           "setup: nextDue should equal fixture nextDue for \(c.id)")
            let days = item.daysUntilDue(now: date(c.today), calendar: calendar)
            XCTAssertEqual(days, c.days, "daysUntilDue mismatch for case \(c.id)")
        }
    }

    /// Sanity: a nil interval value is "never expires" — no due date regardless of unit.
    func testNilIntervalNeverExpires() {
        let item = SupplyItem(name: "Road map")
        item.intervalValue = nil
        item.checks = [CheckRecord(date: date("2026-01-01"))]
        XCTAssertNil(item.nextDueDate(calendar: calendar))
        XCTAssertTrue(item.neverExpires)
    }
}
