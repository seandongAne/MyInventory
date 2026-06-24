//
//  SettingsStore.swift
//  MyInventory
//
//  Single-user app settings, persisted in UserDefaults and observable by views
//  (Dev Plan §3). Lead time feeds both notification scheduling and the
//  "due soon" status threshold.
//

import Foundation
import Observation

@Observable
final class SettingsStore {

    private enum Key {
        static let globalLeadTimeDays = "globalLeadTimeDays"
        static let defaultIntervalMonths = "defaultIntervalMonths"
        static let notificationsRequested = "notificationsRequested"
        static let notificationFireHour = "notificationFireHour"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    /// Days of advance warning before an item becomes overdue.
    var globalLeadTimeDays: Int {
        didSet { defaults.set(globalLeadTimeDays, forKey: Key.globalLeadTimeDays) }
    }

    /// Local hour of day (0–23) at which reminders fire.
    var notificationFireHour: Int {
        didSet { defaults.set(notificationFireHour, forKey: Key.notificationFireHour) }
    }

    /// Convenience default interval (months) pre-filled for new items. 0 == none.
    var defaultIntervalMonths: Int {
        didSet { defaults.set(defaultIntervalMonths, forKey: Key.defaultIntervalMonths) }
    }

    /// Whether we've already asked the system for notification permission once.
    var notificationsRequested: Bool {
        didSet { defaults.set(notificationsRequested, forKey: Key.notificationsRequested) }
    }

    /// Whether the first-run welcome guide has been completed (or skipped). The
    /// guide can still be replayed on demand from Settings.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Register sensible defaults the first time.
        defaults.register(defaults: [
            Key.globalLeadTimeDays: 7,
            Key.defaultIntervalMonths: 0,
            Key.notificationsRequested: false,
            Key.notificationFireHour: 9,
            Key.hasCompletedOnboarding: false
        ])
        self.globalLeadTimeDays = defaults.integer(forKey: Key.globalLeadTimeDays)
        self.defaultIntervalMonths = defaults.integer(forKey: Key.defaultIntervalMonths)
        self.notificationsRequested = defaults.bool(forKey: Key.notificationsRequested)
        self.notificationFireHour = defaults.integer(forKey: Key.notificationFireHour)
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }

    /// nil when no convenience default is configured.
    var defaultIntervalMonthsOrNil: Int? {
        defaultIntervalMonths > 0 ? defaultIntervalMonths : nil
    }
}
