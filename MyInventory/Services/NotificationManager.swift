//
//  NotificationManager.swift
//  MyInventory
//
//  Local notifications for due / due-soon / first-check items (Dev Plan §5, §M4).
//
//  Key constraints handled here:
//   • iOS caps pending local notifications at 64 → we schedule the
//     soonest-FIRING notifications up to a cap kept well under 64. There is no
//     look-ahead window: far-future dues are scheduled too (a personal-scale
//     inventory never approaches the cap). Refresh on app foreground.
//   • Never-expires (nil interval) items schedule nothing.
//   • Never-checked items (interval, zero checks) DO get a first-check reminder.
//   • A fetch failure must NEVER wipe existing reminders — `rescheduleAll(in:)`
//     skips the pass instead of treating the store as empty.
//   • We only remove our OWN requests that are no longer planned; the ones we're
//     about to re-add are never pre-deleted, so a failed `add` can't leave an
//     item with no reminder. Add failures are counted and surfaced, not swallowed.
//

import Foundation
import Observation
import SwiftData
import UserNotifications

@MainActor
@Observable
final class NotificationManager {

    /// Hard ceiling well under the iOS 64-notification limit (leaves headroom).
    private let maxPending = 60

    /// Hour of day (local) the notification fires.
    private let fireHour = 9

    private let center = UNUserNotificationCenter.current()

    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Number of notifications that failed to schedule on the last pass (0 = all good).
    /// Surfaced in Settings so a silent `add` failure is visible and retryable (P2).
    var lastSchedulingFailureCount = 0

    /// Serializes reschedule passes so two overlapping runs can't race.
    private var inFlight: Task<Void, Never>?

    // MARK: Authorization

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()
            return granted
        } catch {
            return false
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    // MARK: Public scheduling entry point

    /// Fetch-safe, serialized reschedule. Fetches items itself and — crucially —
    /// if the fetch fails it SKIPS the pass rather than wiping all reminders.
    func rescheduleAll(in context: ModelContext, globalLeadTimeDays: Int) {
        let previous = inFlight
        inFlight = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard self.authorizationStatus == .authorized || self.authorizationStatus == .provisional else { return }
            guard let items = try? context.fetch(FetchDescriptor<SupplyItem>()) else { return }
            await self.reschedule(items: items, globalLeadTimeDays: globalLeadTimeDays)
        }
    }

    // MARK: Scheduling core

    /// Re-schedules the planned set. Removes only our now-stale requests, then
    /// (re)adds each planned one. Internal so tests can drive it explicitly.
    func reschedule(items: [SupplyItem],
                    globalLeadTimeDays: Int,
                    now: Date = .now,
                    calendar: Calendar = .current) async {
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        let plans = Self.plannedNotifications(
            for: items,
            now: now,
            globalLeadTimeDays: globalLeadTimeDays,
            maxPending: maxPending,
            calendar: calendar
        )
        let plannedIDs = Set(plans.map(\.identifier))

        // Remove only OUR requests that are no longer planned. Never pre-delete the
        // ones we're about to re-add — `add` replaces a same-identifier request in
        // place, so a failed add can't leave the item with nothing (P2).
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix("item-") && !plannedIDs.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        let byUUID = Dictionary(items.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var failures = 0
        for plan in plans {
            let (title, body) = notificationText(for: plan, item: byUUID[plan.itemUUID])
            let scheduled = await add(identifier: plan.identifier, title: title, body: body,
                                      targetDay: plan.fireDate, now: now, calendar: calendar)
            if !scheduled { failures += 1 }
        }
        // Surface failures instead of silently dropping reminders (P2).
        lastSchedulingFailureCount = failures
    }

    /// Removes both scheduled requests for a single item (e.g. when deleted).
    func cancelNotifications(forItemUUID uuid: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [
            "item-\(uuid.uuidString)-due",
            "item-\(uuid.uuidString)-lead"
        ])
    }

    // MARK: Pure planning (testable, no side effects)

    struct PlannedNotification: Equatable {
        enum Kind: Equatable { case due, lead }
        let itemUUID: UUID
        let kind: Kind
        /// Target calendar day; the concrete fire time is this day at `fireHour`,
        /// clamped forward if that instant has already passed.
        let fireDate: Date
        /// Lead days (for `.lead` kind; 0 for `.due`).
        var leadDays: Int = 0

        var identifier: String { "item-\(itemUUID.uuidString)-\(kind == .due ? "due" : "lead")" }
    }

    /// Decides which notifications to schedule. Builds every candidate (due + lead),
    /// sorts by ACTUAL fire date, then caps — so the soonest-firing notifications win
    /// the scarce slots (a lead can correctly outrank a later item's due) (P2).
    ///
    /// Rules:
    ///  • nil interval (never expires)            → nothing.
    ///  • interval + no checks (never checked)    → a first-check reminder "now".
    ///  • interval + any future due               → a due reminder + optional lead.
    ///  • interval + already overdue (has checks)  → nothing (surfaced in-app).
    static func plannedNotifications(for items: [SupplyItem],
                                     now: Date,
                                     globalLeadTimeDays: Int,
                                     maxPending: Int,
                                     calendar: Calendar = .current) -> [PlannedNotification] {
        var candidates: [PlannedNotification] = []
        for item in items {
            guard item.checkIntervalMonths != nil else { continue }   // never expires
            if item.lastCheck == nil {
                // First-check reminder — scheduled "now" (clamped to next 9am in add()).
                candidates.append(PlannedNotification(itemUUID: item.uuid, kind: .due, fireDate: now))
            } else if let due = item.nextDueDate(calendar: calendar), due > now {
                candidates.append(PlannedNotification(itemUUID: item.uuid, kind: .due, fireDate: due))
                let lead = item.effectiveLeadTimeDays(globalLead: globalLeadTimeDays)
                if lead > 0,
                   let leadDate = calendar.date(byAdding: .day, value: -lead, to: due),
                   leadDate > now {
                    candidates.append(PlannedNotification(itemUUID: item.uuid, kind: .lead,
                                                          fireDate: leadDate, leadDays: lead))
                }
            }
            // overdue-with-history → intentionally not scheduled.
        }

        return Array(
            candidates
                .sorted { $0.fireDate < $1.fireDate }   // true soonest-fire-first
                .prefix(maxPending)
        )
    }

    // MARK: Helpers

    private func notificationText(for plan: PlannedNotification,
                                  item: SupplyItem?) -> (title: String, body: String) {
        let name = displayName(item)
        switch plan.kind {
        case .due:
            if let item, item.lastCheck == nil {
                return ("First check needed", "\(name) hasn't been checked yet.")
            }
            return ("Check due", "\(name) is due for a check.")
        case .lead:
            let days = max(plan.leadDays, 1)
            return ("Check coming up", "\(name) is due in \(days) day\(days == 1 ? "" : "s").")
        }
    }

    /// Fires on `targetDay` at `fireHour`; if that instant is already in the past,
    /// bumps to the next day so the notification actually delivers. Returns whether
    /// the request was accepted.
    @discardableResult
    private func add(identifier: String,
                     title: String,
                     body: String,
                     targetDay: Date,
                     now: Date,
                     calendar: Calendar) async -> Bool {
        var dayComponents = calendar.dateComponents([.year, .month, .day], from: targetDay)
        dayComponents.hour = fireHour
        dayComponents.minute = 0
        var fireAt = calendar.date(from: dayComponents) ?? targetDay
        if fireAt <= now {
            fireAt = calendar.date(byAdding: .day, value: 1, to: fireAt) ?? fireAt
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let triggerComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    private func displayName(_ item: SupplyItem?) -> String {
        guard let item else { return "An item" }
        let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "An item" : trimmed
        // Include context so multi-context users know which Vehicle/Bag/House item is due (F3).
        if let contextName = item.context?.name {
            return "\(base) (\(contextName))"
        }
        return base
    }
}
