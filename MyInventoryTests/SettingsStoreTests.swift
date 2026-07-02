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

    /// A dictionary-backed store so each test starts clean and never touches the real
    /// `.standard` suite. `InMemoryDefaults` is a plain `SettingsDefaults` (NOT a
    /// `UserDefaults` subclass) because both a real transient suite and a `UserDefaults`
    /// subclass intermittently crashed the CI test host with a malloc double-free.
    private func freshDefaults(_ name: String = #function) -> SettingsDefaults {
        InMemoryDefaults()
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

    // MARK: Monotonic modifiedAt (clock-skew hardening)

    /// After adopting a peer's future-dated `settingsModifiedAt` via LWW, a local
    /// edit must stamp STRICTLY NEWER than the adopted instant — a plain `.now`
    /// would be older, so the peer's blob would revert the edit on every re-merge.
    func testEditAfterAdoptingFutureTimestampStaysStrictlyNewer() {
        let store = SettingsStore(defaults: freshDefaults())
        let future = Date.now.addingTimeInterval(60 * 60 * 24 * 365)
        store.applyMergedSettings(globalLeadTimeDays: 30, defaultIntervalValue: 2,
                                  defaultIntervalUnit: "years", notificationFireHour: 8,
                                  modifiedAt: future)

        store.globalLeadTimeDays = 10

        XCTAssertGreaterThan(store.settingsModifiedAt, future)
    }

    // MARK: Range guards on load

    /// Out-of-range PERSISTED values (a synced peer or an older build may have
    /// written them) are clamped on load, mirroring the import-time clamp.
    func testPersistedOutOfRangeValuesAreClampedOnLoad() {
        let defaults = freshDefaults()
        defaults.set(-999, forKey: "notificationFireHour")
        defaults.set(-30, forKey: "globalLeadTimeDays")
        defaults.set(-5, forKey: "defaultIntervalValue")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.notificationFireHour, 0)
        XCTAssertEqual(store.globalLeadTimeDays, 0)
        XCTAssertEqual(store.defaultIntervalValue, 0)
    }

    // MARK: Upgrade seeds a real LWW baseline (not epoch)

    /// A fresh install keeps the epoch baseline (so its untouched defaults never win
    /// LWW over an edited peer), and doesn't pre-write a timestamp.
    func testFreshInstallKeepsEpochBaseline() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settingsModifiedAt, SettingsStore.epoch)
        XCTAssertNil(defaults.object(forKey: "settingsModifiedAt"))
    }

    /// An UPGRADE that already carries a user-configured synced setting but no stored
    /// `settingsModifiedAt` must stamp the upgrade moment (not epoch) and persist it —
    /// otherwise its export ties a fresh peer at the epoch and never syncs.
    func testUpgradeWithExistingSettingStampsBaselineAndPersists() {
        let defaults = freshDefaults()
        defaults.set(30, forKey: "globalLeadTimeDays")   // pre-value+unit install, edited
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)

        let store = SettingsStore(defaults: defaults, now: stamp)

        XCTAssertEqual(store.settingsModifiedAt, stamp)
        XCTAssertGreaterThan(store.settingsModifiedAt, SettingsStore.epoch)
        // Persisted, so a later launch reads the same baseline instead of re-stamping.
        XCTAssertEqual(defaults.object(forKey: "settingsModifiedAt") as? Date, stamp)
        let reloaded = SettingsStore(defaults: defaults, now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(reloaded.settingsModifiedAt, stamp)
    }

    /// The legacy-months upgrade path also seeds a non-epoch baseline.
    func testLegacyMonthsUpgradeStampsBaseline() {
        let defaults = freshDefaults()
        defaults.set(6, forKey: "defaultIntervalMonths")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        let store = SettingsStore(defaults: defaults, now: stamp)

        XCTAssertEqual(store.defaultIntervalValue, 6)
        XCTAssertEqual(store.settingsModifiedAt, stamp)
    }
}
