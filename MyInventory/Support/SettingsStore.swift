//
//  SettingsStore.swift
//  MyInventory
//
//  Single-user app settings, persisted in UserDefaults and observable by views
//  (Dev Plan §3). Lead time feeds both notification scheduling and the
//  "due soon" status threshold.
//
//  The SYNCED subset (lead window, default interval value+unit, reminder hour)
//  is a whole-object-LWW singleton in the SCBK1 wire format (sync plan §4/§9):
//  editing any of them bumps `settingsModifiedAt`; a backup with a newer
//  `settingsModifiedAt` replaces the whole set on import. `settingsModifiedAt`
//  starts at the epoch so an *unedited* device's defaults never win LWW over an
//  edited peer. `notificationsRequested` / `hasCompletedOnboarding` are local-only
//  (never synced, never bump the timestamp).
//

import Foundation
import Observation

@Observable
final class SettingsStore {

    private enum Key {
        static let globalLeadTimeDays = "globalLeadTimeDays"
        /// Legacy months-only default (pre value+unit). Migrated once on first launch
        /// into `defaultIntervalValue` + `defaultIntervalUnit`, then removed.
        static let defaultIntervalMonths = "defaultIntervalMonths"
        static let defaultIntervalValue = "defaultIntervalValue"
        static let defaultIntervalUnit = "defaultIntervalUnit"
        static let settingsModifiedAt = "settingsModifiedAt"
        static let notificationsRequested = "notificationsRequested"
        static let notificationFireHour = "notificationFireHour"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    /// Baseline for a never-edited device — always loses LWW to a real edit.
    static let epoch = Date(timeIntervalSince1970: 0)

    /// Days of advance warning before an item becomes overdue.
    var globalLeadTimeDays: Int {
        didSet {
            defaults.set(globalLeadTimeDays, forKey: Key.globalLeadTimeDays)
            bumpSettingsModified()
        }
    }

    /// Local hour of day (0–23) at which reminders fire.
    var notificationFireHour: Int {
        didSet {
            defaults.set(notificationFireHour, forKey: Key.notificationFireHour)
            bumpSettingsModified()
        }
    }

    /// Convenience default interval value pre-filled for new items. 0 == no default
    /// (mirrors `SupplyItem.intervalValue == nil`). Paired with `defaultIntervalUnit`.
    var defaultIntervalValue: Int {
        didSet {
            defaults.set(defaultIntervalValue, forKey: Key.defaultIntervalValue)
            bumpSettingsModified()
        }
    }

    /// Unit for `defaultIntervalValue` (raw `IntervalUnit`; retained even when the
    /// value is 0, for round-trip stability). Defaults to months.
    var defaultIntervalUnit: String {
        didSet {
            defaults.set(defaultIntervalUnit, forKey: Key.defaultIntervalUnit)
            bumpSettingsModified()
        }
    }

    /// When the synced settings subset was last changed (whole-object LWW key).
    var settingsModifiedAt: Date {
        didSet { defaults.set(settingsModifiedAt, forKey: Key.settingsModifiedAt) }
    }

    /// Whether we've already asked the system for notification permission once.
    /// Local-only — never synced, never bumps `settingsModifiedAt`.
    var notificationsRequested: Bool {
        didSet { defaults.set(notificationsRequested, forKey: Key.notificationsRequested) }
    }

    /// Whether the first-run welcome guide has been completed (or skipped). The
    /// guide can still be replayed on demand from Settings. Local-only.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    private let defaults: UserDefaults
    /// False during init so loading persisted values doesn't spuriously bump the
    /// modified timestamp; flipped true once construction finishes.
    private var isReady = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // One-time migration of the legacy months-only default into value+unit. The
        // legacy key only exists on an upgrade and is removed here, so it and the
        // value+unit keys never coexist — migrating unconditionally on its presence
        // is safe (and avoids depending on a registration-domain fallback masking
        // "never written" as 0).
        if let legacyMonths = defaults.object(forKey: Key.defaultIntervalMonths) as? Int {
            defaults.set(legacyMonths, forKey: Key.defaultIntervalValue)
            defaults.set(IntervalUnit.months.rawValue, forKey: Key.defaultIntervalUnit)
            defaults.removeObject(forKey: Key.defaultIntervalMonths)
        }

        // Register sensible defaults the first time.
        defaults.register(defaults: [
            Key.globalLeadTimeDays: 7,
            Key.defaultIntervalValue: 0,
            Key.defaultIntervalUnit: IntervalUnit.months.rawValue,
            Key.notificationsRequested: false,
            Key.notificationFireHour: 9,
            Key.hasCompletedOnboarding: false
        ])
        self.globalLeadTimeDays = defaults.integer(forKey: Key.globalLeadTimeDays)
        self.defaultIntervalValue = defaults.integer(forKey: Key.defaultIntervalValue)
        self.defaultIntervalUnit = defaults.string(forKey: Key.defaultIntervalUnit)
            ?? IntervalUnit.months.rawValue
        self.settingsModifiedAt = defaults.object(forKey: Key.settingsModifiedAt) as? Date
            ?? Self.epoch
        self.notificationsRequested = defaults.bool(forKey: Key.notificationsRequested)
        self.notificationFireHour = defaults.integer(forKey: Key.notificationFireHour)
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)

        isReady = true
    }

    /// nil when no convenience default is configured (value 0 == "no default").
    var defaultIntervalValueOrNil: Int? {
        defaultIntervalValue > 0 ? defaultIntervalValue : nil
    }

    /// Strongly-typed default unit (falls back to months on any bad raw value).
    var defaultIntervalUnitValue: IntervalUnit {
        IntervalUnit(rawValue: defaultIntervalUnit) ?? .months
    }

    /// Apply an incoming settings singleton that won whole-object LWW on import.
    /// Sets the synced fields, then stamps `settingsModifiedAt` to the incoming
    /// instant (NOT now, so a later export carries the winning timestamp). The
    /// field setters above each bump the timestamp to now; the trailing explicit
    /// assignment overrides that back to the incoming value. `value` uses 0 for the
    /// wire's null ("no default").
    func applyMergedSettings(globalLeadTimeDays: Int,
                             defaultIntervalValue: Int,
                             defaultIntervalUnit: String,
                             notificationFireHour: Int,
                             modifiedAt: Date) {
        self.globalLeadTimeDays = globalLeadTimeDays
        self.defaultIntervalValue = defaultIntervalValue
        self.defaultIntervalUnit = defaultIntervalUnit
        self.notificationFireHour = notificationFireHour
        self.settingsModifiedAt = modifiedAt
    }

    private func bumpSettingsModified(now: Date = .now) {
        guard isReady else { return }
        settingsModifiedAt = now
    }
}
