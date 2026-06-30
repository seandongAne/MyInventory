//
//  SettingsStoreTests.swift
//  MyInventoryTests
//
//  Covers the default-interval value+unit split and the one-time migration from
//  the legacy months-only `defaultIntervalMonths` key (sync schema §4 / decision #5).
//

import XCTest
@testable import MyInventory

final class SettingsStoreTests: XCTestCase {

    /// A throwaway UserDefaults domain so each test starts clean and never touches
    /// the real `.standard` suite.
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "SettingsStoreTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: Fresh install

    func testFreshInstallHasNoDefaultInterval() {
        let store = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(store.defaultIntervalValue, 0)
        XCTAssertEqual(store.defaultIntervalUnit, IntervalUnit.months.rawValue)
        XCTAssertNil(store.defaultIntervalValueOrNil)
        XCTAssertEqual(store.defaultIntervalUnitValue, .months)
    }

    // MARK: value+unit persistence + accessors

    func testValueAndUnitPersistAcrossInstances() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        store.defaultIntervalValue = 3
        store.defaultIntervalUnit = IntervalUnit.years.rawValue

        // A second store over the same domain reads back the persisted values.
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.defaultIntervalValue, 3)
        XCTAssertEqual(reloaded.defaultIntervalUnitValue, .years)
        XCTAssertEqual(reloaded.defaultIntervalValueOrNil, 3)
    }

    func testValueOrNilIsNilWhenZero() {
        let store = SettingsStore(defaults: freshDefaults())
        store.defaultIntervalValue = 0
        XCTAssertNil(store.defaultIntervalValueOrNil)
    }

    func testUnitValueFallsBackToMonthsOnBadRawValue() {
        let store = SettingsStore(defaults: freshDefaults())
        store.defaultIntervalUnit = "fortnights"   // not a valid IntervalUnit
        XCTAssertEqual(store.defaultIntervalUnitValue, .months)
    }

    // MARK: legacy migration

    func testLegacyMonthsMigratesToValueAndMonthsUnit() {
        let defaults = freshDefaults()
        defaults.set(6, forKey: "defaultIntervalMonths")   // legacy key

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.defaultIntervalValue, 6)
        XCTAssertEqual(store.defaultIntervalUnitValue, .months)
        // Legacy key is consumed and removed.
        XCTAssertNil(defaults.object(forKey: "defaultIntervalMonths"))
    }

    func testLegacyZeroMigratesToNoDefault() {
        let defaults = freshDefaults()
        defaults.set(0, forKey: "defaultIntervalMonths")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.defaultIntervalValue, 0)
        XCTAssertNil(store.defaultIntervalValueOrNil)
        XCTAssertNil(defaults.object(forKey: "defaultIntervalMonths"))
    }

    func testMigrationRunsOnceThenLeavesUserEditsAlone() {
        let defaults = freshDefaults()
        defaults.set(6, forKey: "defaultIntervalMonths")

        // First launch migrates 6 months → value+unit and consumes the legacy key.
        let first = SettingsStore(defaults: defaults)
        XCTAssertEqual(first.defaultIntervalValue, 6)
        XCTAssertNil(defaults.object(forKey: "defaultIntervalMonths"))

        // User then changes the default to 3 years.
        first.defaultIntervalValue = 3
        first.defaultIntervalUnit = IntervalUnit.years.rawValue

        // A later launch must not re-migrate (legacy key is gone) and keeps the edit.
        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.defaultIntervalValue, 3)
        XCTAssertEqual(second.defaultIntervalUnitValue, .years)
    }
}
