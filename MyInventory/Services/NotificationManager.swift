//
//  NotificationManager.swift
//  MyInventory
//
//  Local notifications for due / due-soon items (Dev Plan §5, §M4).
//
//  Key constraints handled here:
//   • iOS caps pending local notifications at 64 → we schedule only items whose
//     next due date falls inside a rolling window, soonest-first, and never
//     exceed the cap. Refresh on app foreground.
//   • Never-expires (nil interval) items schedule nothing.
//   • Re-scheduling is idempotent: we clear our own requests first (stable
//     "item-<uuid>-due" / "item-<uuid>-lead" identifiers), then re-add.
//

import Foundation
import Observation
import UserNotifications

@Observable
final class NotificationManager {

    /// How far ahead we schedule. Items due beyond this are picked up on a later refresh.
    var windowDays: Int = 90

    /// Hard ceiling well under the iOS 64-notification limit (leaves headroom).
    private let maxPending = 60

    /// Hour of day (local) the notification fires.
    private let fireHour = 9

    private let center = UNUserNotificationCenter.current()

    var authorizationStatus: UNAuthorizationStatus = .notDetermined

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

    // MARK: Scheduling

    /// Clears our scheduled requests and re-schedules due/lead notifications for
    /// the soonest items inside the rolling window, capped under the iOS limit.
    func reschedule(items: [SupplyItem],
                    globalLeadTimeDays: Int,
                    now: Date = .now,
                    calendar: Calendar = .current) async {
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        // Remove everything we previously scheduled (don't touch foreign requests).
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix("item-") }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        guard let windowEnd = calendar.date(byAdding: .day, value: windowDays, to: now) else { return }

        // Candidate items: have an interval, have a future due date inside the window.
        let candidates: [(item: SupplyItem, due: Date)] = items.compactMap { item in
            guard item.checkIntervalMonths != nil,
                  let due = item.nextDueDate(calendar: calendar),
                  due > now, due <= windowEnd
            else { return nil }
            return (item, due)
        }
        .sorted { $0.due < $1.due }   // soonest first → respect the cap fairly

        var scheduled = 0
        for entry in candidates {
            if scheduled >= maxPending { break }

            // Due-date notification.
            if await add(identifier: "item-\(entry.item.uuid.uuidString)-due",
                         title: "Check due",
                         body: "\(displayName(entry.item)) is due for a check.",
                         fireDate: entry.due,
                         calendar: calendar) {
                scheduled += 1
            }

            // Lead-time (advance warning) notification, if it lands in the future.
            let lead = entry.item.effectiveLeadTimeDays(globalLead: globalLeadTimeDays)
            if lead > 0, scheduled < maxPending,
               let leadDate = calendar.date(byAdding: .day, value: -lead, to: entry.due),
               leadDate > now {
                if await add(identifier: "item-\(entry.item.uuid.uuidString)-lead",
                             title: "Check coming up",
                             body: "\(displayName(entry.item)) is due in \(lead) day\(lead == 1 ? "" : "s").",
                             fireDate: leadDate,
                             calendar: calendar) {
                    scheduled += 1
                }
            }
        }
    }

    /// Removes both scheduled requests for a single item (e.g. when deleted).
    func cancelNotifications(forItemUUID uuid: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [
            "item-\(uuid.uuidString)-due",
            "item-\(uuid.uuidString)-lead"
        ])
    }

    // MARK: Helpers

    private func add(identifier: String,
                     title: String,
                     body: String,
                     fireDate: Date,
                     calendar: Calendar) async -> Bool {
        var components = calendar.dateComponents([.year, .month, .day], from: fireDate)
        components.hour = fireHour
        components.minute = 0

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    private func displayName(_ item: SupplyItem) -> String {
        let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "An item" : trimmed
        // Include context so multi-context users know which Vehicle/Bag/House item is due (F3).
        if let contextName = item.context?.name {
            return "\(base) (\(contextName))"
        }
        return base
    }
}
