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

    /// Persisted keys whose mere presence means the user configured a SYNCED setting
    /// on a prior version — each is written only by an actual edit (`didSet`) or by
    /// the legacy migration, never by `register(defaults:)`. Read BEFORE registering
    /// fallbacks, which would otherwise mask a never-written key with its default.
    private static let syncedSettingKeys = [
        Key.defaultIntervalMonths,   // legacy months-only default (pre value+unit)
        Key.globalLeadTimeDays,
        Key.notificationFireHour,
        Key.defaultIntervalValue,
        Key.defaultIntervalUnit
    ]

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults

        // Decide the synced-settings LWW baseline from the PERSISTED domain only. This
        // store loads every field with an explicit fallback instead of
        // `register(defaults:)`, precisely so `object(forKey:)` never returns a shared
        // registration-domain default — a non-nil persisted key is then unambiguously
        // one the user configured (the registration domain is process-global and leaks
        // across every UserDefaults suite, which would make this detection always true).
        //
        // A stored `settingsModifiedAt` always wins. Otherwise: an UPGRADE that already
        // carries a user-configured synced setting must win LWW over a brand-new peer,
        // so it's stamped with the upgrade moment (`now`) and persisted; a truly fresh
        // install keeps the epoch baseline, so its untouched defaults never clobber an
        // edited peer.
        let storedModifiedAt = defaults.object(forKey: Key.settingsModifiedAt) as? Date
        let hasPriorSyncedSettings = Self.syncedSettingKeys.contains {
            defaults.object(forKey: $0) != nil
        }

        // One-time migration of the legacy months-only default into value+unit. The
        // legacy key only exists on an upgrade and is removed here, so it and the
        // value+unit keys never coexist — migrating unconditionally on its presence
        // is safe.
        if let legacyMonths = defaults.object(forKey: Key.defaultIntervalMonths) as? Int {
            defaults.set(legacyMonths, forKey: Key.defaultIntervalValue)
            defaults.set(IntervalUnit.months.rawValue, forKey: Key.defaultIntervalUnit)
            defaults.removeObject(forKey: Key.defaultIntervalMonths)
        }

        // Load each field with its default inline (no shared registration domain).
        self.globalLeadTimeDays = (defaults.object(forKey: Key.globalLeadTimeDays) as? Int) ?? 7
        self.defaultIntervalValue = (defaults.object(forKey: Key.defaultIntervalValue) as? Int) ?? 0
        self.defaultIntervalUnit = defaults.string(forKey: Key.defaultIntervalUnit)
            ?? IntervalUnit.months.rawValue
        self.settingsModifiedAt = storedModifiedAt ?? (hasPriorSyncedSettings ? now : Self.epoch)
        self.notificationsRequested = defaults.bool(forKey: Key.notificationsRequested)
        self.notificationFireHour = (defaults.object(forKey: Key.notificationFireHour) as? Int) ?? 9
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)

        // Persist a synthesized upgrade baseline (didSet doesn't fire during init) so
        // it's stable across launches. The epoch baseline is intentionally left unstored
        // so the first real edit is what first writes a timestamp.
        if storedModifiedAt == nil && hasPriorSyncedSettings {
            defaults.set(self.settingsModifiedAt, forKey: Key.settingsModifiedAt)
        }

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
