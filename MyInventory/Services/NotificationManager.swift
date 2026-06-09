//
//  NotificationManager.swift
//  MyInventory
//
//  Local notifications for due / due-soon items, plus a single "needs attention"
//  digest (Dev Plan §5, §M4).
//
//  Key constraints handled here:
//   • iOS caps pending local notifications at 64 → we schedule the
//     soonest-FIRING notifications up to a cap kept well under 64. There is no
//     look-ahead window: far-future dues are scheduled too (a personal-scale
//     inventory never approaches the cap). Refresh on app foreground.
//   • Never-expires (nil interval) items schedule nothing.
//   • Items needing action NOW (overdue, flagged, never-checked) are batched into
//     ONE digest notification at the next fire hour — never one nag per item, and
//     an item that slips overdue between reschedules still gets surfaced instead
//     of silently losing its (clamped-forward) due notification.
//   • A fetch failure must NEVER wipe existing reminders — `rescheduleAll(in:)`
//     skips the pass instead of treating the store as empty.
//   • We only remove our OWN requests that are no longer planned; the ones we're
//     about to re-add are never pre-deleted, so a failed `add` can't leave an
//     item with no reminder. Add failures are counted and surfaced, not swallowed.
//   • The delegate shows banners in the foreground, deep-links taps to the item
//     (or the attention list for the digest), and handles the "Mark as Checked"
//     action without opening the app.
//

import Foundation
import Observation
import SwiftData
import UserNotifications

@MainActor
@Observable
final class NotificationManager {

    /// One instance shared by the app scene and App Intents (both run in-process
    /// and must funnel through the same serialized reschedule queue).
    static let shared = NotificationManager()

    /// Hard ceiling well under the iOS 64-notification limit (leaves headroom
    /// for the digest + slack).
    private let maxPending = 60

    /// Stable identifier of the single "needs attention" digest notification.
    /// NOT "item-"-prefixed, so the stale-removal pass never touches it.
    static let digestIdentifier = "attention-digest"

    /// Identifiers for the notification category / action.
    static let itemCategoryID = "SUPPLY_ITEM"
    static let markCheckedActionID = "MARK_CHECKED"

    /// Hour of day (local) notifications fire. Read from settings when configured.
    var fireHour: Int { settings?.notificationFireHour ?? 9 }

    private let center = UNUserNotificationCenter.current()
    private let delegateAdapter = NotificationDelegateAdapter()

    /// Wired up once at app launch (used by the Mark-as-Checked action handler).
    private(set) var container: ModelContainer?
    private(set) var settings: SettingsStore?

    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Number of notifications that failed to schedule on the last pass (0 = all good).
    /// Surfaced in Settings so a silent `add` failure is visible and retryable (P2).
    var lastSchedulingFailureCount = 0

    /// Set when the user taps a notification; ContentView observes it and navigates.
    var pendingDeepLink: DeepLink?

    enum DeepLink: Equatable {
        case item(UUID)
        case attention
    }

    /// Serializes reschedule passes so two overlapping runs can't race.
    private var inFlight: Task<Void, Never>?

    init() {
        // The delegate must be in place before launch finishes so a tap that
        // cold-starts the app is still delivered.
        delegateAdapter.onResponse = { [weak self] identifier, action in
            Task { @MainActor [weak self] in
                await self?.handleNotificationResponse(identifier: identifier, action: action)
            }
        }
        center.delegate = delegateAdapter
        registerCategories()
    }

    /// Called once from MyInventoryApp so background notification actions can
    /// reach the store and the configured fire hour.
    func configure(container: ModelContainer, settings: SettingsStore) {
        self.container = container
        self.settings = settings
    }

    private func registerCategories() {
        let markChecked = UNNotificationAction(
            identifier: Self.markCheckedActionID,
            title: "Mark as Checked",
            options: []   // background — no need to open the app
        )
        let itemCategory = UNNotificationCategory(
            identifier: Self.itemCategoryID,
            actions: [markChecked],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([itemCategory])
    }

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
    /// Also refreshes the widget snapshot (independent of notification permission).
    func rescheduleAll(in context: ModelContext, globalLeadTimeDays: Int) {
        let previous = inFlight
        inFlight = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard let items = try? context.fetch(FetchDescriptor<SupplyItem>()) else { return }
            // Widgets reflect the data regardless of notification permission.
            WidgetBridge.writeSnapshot(for: items, globalLeadTimeDays: globalLeadTimeDays)
            guard self.authorizationStatus == .authorized || self.authorizationStatus == .provisional else {
                // Nothing is scheduled while unauthorized — don't show a stale
                // failure count from an earlier authorized pass.
                self.lastSchedulingFailureCount = 0
                return
            }
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
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else {
            lastSchedulingFailureCount = 0
            return
        }

        let plans = Self.plannedNotifications(
            for: items,
            now: now,
            globalLeadTimeDays: globalLeadTimeDays,
            maxPending: maxPending,
            calendar: calendar
        )
        let plannedIDs = Set(plans.map(\.identifier))
        let digest = Self.attentionSummary(for: items,
                                           globalLeadTimeDays: globalLeadTimeDays,
                                           now: now,
                                           calendar: calendar)

        // Remove only OUR requests that are no longer planned. Never pre-delete the
        // ones we're about to re-add — `add` replaces a same-identifier request in
        // place, so a failed add can't leave the item with nothing (P2).
        let pending = await center.pendingNotificationRequests()
        var stale = pending.map(\.identifier).filter { $0.hasPrefix("item-") && !plannedIDs.contains($0) }
        if digest == nil { stale.append(Self.digestIdentifier) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        let byUUID = Dictionary(items.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var failures = 0
        for plan in plans {
            let (title, body) = notificationText(for: plan, item: byUUID[plan.itemUUID])
            let scheduled = await add(identifier: plan.identifier, title: title, body: body,
                                      categoryIdentifier: Self.itemCategoryID,
                                      targetDay: plan.fireDate, now: now, calendar: calendar)
            if !scheduled { failures += 1 }
        }

        // One digest for everything actionable right now (overdue / flagged /
        // never checked). Re-armed for the next fire hour on every pass, so it
        // fires at most once a day and only while something still needs attention.
        if let digest {
            let scheduled = await add(identifier: Self.digestIdentifier,
                                      title: "Supplies need attention",
                                      body: digest.summaryLine,
                                      categoryIdentifier: nil,
                                      targetDay: now, now: now, calendar: calendar)
            if !scheduled { failures += 1 }
        }

        // App icon badge mirrors the attention count.
        try? await center.setBadgeCount(digest?.total ?? 0)

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

    /// Decides which per-item notifications to schedule. Builds every candidate
    /// (due + lead), sorts by ACTUAL fire date, then caps — so the soonest-firing
    /// notifications win the scarce slots (a lead can correctly outrank a later
    /// item's due) (P2).
    ///
    /// Rules:
    ///  • nil interval (never expires)             → nothing.
    ///  • interval + any future due                → a due reminder + optional lead.
    ///  • needs-action-now states (never checked,
    ///    overdue, flagged)                        → handled by the digest, not here.
    static func plannedNotifications(for items: [SupplyItem],
                                     now: Date,
                                     globalLeadTimeDays: Int,
                                     maxPending: Int,
                                     calendar: Calendar = .current) -> [PlannedNotification] {
        var candidates: [PlannedNotification] = []
        for item in items {
            guard item.checkIntervalMonths != nil else { continue }   // never expires
            guard let due = item.nextDueDate(calendar: calendar), due > now else { continue }
            candidates.append(PlannedNotification(itemUUID: item.uuid, kind: .due, fireDate: due))
            let lead = item.effectiveLeadTimeDays(globalLead: globalLeadTimeDays)
            if lead > 0,
               let leadDate = calendar.date(byAdding: .day, value: -lead, to: due),
               leadDate > now {
                candidates.append(PlannedNotification(itemUUID: item.uuid, kind: .lead,
                                                      fireDate: leadDate, leadDays: lead))
            }
        }

        return Array(
            candidates
                .sorted { $0.fireDate < $1.fireDate }   // true soonest-fire-first
                .prefix(maxPending)
        )
    }

    /// What needs the user's attention RIGHT NOW (drives the digest + app badge).
    /// nil when nothing does.
    struct AttentionSummary: Equatable {
        var overdue = 0
        var flagged = 0
        var neverChecked = 0

        var total: Int { overdue + flagged + neverChecked }

        var summaryLine: String {
            var parts: [String] = []
            if overdue > 0 { parts.append("\(overdue) overdue") }
            if flagged > 0 { parts.append("\(flagged) flagged") }
            if neverChecked > 0 { parts.append("\(neverChecked) never checked") }
            let detail = parts.joined(separator: " · ")
            return "\(total) suppl\(total == 1 ? "y needs" : "ies need") a check — \(detail)."
        }
    }

    static func attentionSummary(for items: [SupplyItem],
                                 globalLeadTimeDays: Int,
                                 now: Date,
                                 calendar: Calendar = .current) -> AttentionSummary? {
        var summary = AttentionSummary()
        for item in items {
            switch item.status(leadTimeDays: globalLeadTimeDays, now: now, calendar: calendar) {
            case .overdue: summary.overdue += 1
            case .needsAttention: summary.flagged += 1
            case .neverChecked: summary.neverChecked += 1
            default: break
            }
        }
        return summary.total > 0 ? summary : nil
    }

    /// Concrete fire instant for a target day: that day at `fireHour`, bumped to
    /// the next day if the instant has already passed (so it actually delivers).
    static func resolvedFireDate(targetDay: Date,
                                 now: Date,
                                 fireHour: Int,
                                 calendar: Calendar = .current) -> Date {
        var dayComponents = calendar.dateComponents([.year, .month, .day], from: targetDay)
        dayComponents.hour = fireHour
        dayComponents.minute = 0
        var fireAt = calendar.date(from: dayComponents) ?? targetDay
        if fireAt <= now {
            fireAt = calendar.date(byAdding: .day, value: 1, to: fireAt) ?? fireAt
        }
        return fireAt
    }

    /// Maps a notification request identifier back to an in-app destination.
    static func deepLink(forNotificationIdentifier identifier: String) -> DeepLink? {
        if identifier == digestIdentifier { return .attention }
        guard identifier.hasPrefix("item-") else { return nil }
        var core = String(identifier.dropFirst("item-".count))
        for suffix in ["-due", "-lead"] where core.hasSuffix(suffix) {
            core = String(core.dropLast(suffix.count))
        }
        return UUID(uuidString: core).map { .item($0) }
    }

    // MARK: Notification responses (taps + actions)

    func handleNotificationResponse(identifier: String, action: String) async {
        let link = Self.deepLink(forNotificationIdentifier: identifier)
        if action == Self.markCheckedActionID {
            if case .item(let uuid) = link {
                await markChecked(itemUUID: uuid)
            }
            return
        }
        // Default tap → navigate once the UI is up.
        pendingDeepLink = link
    }

    /// Handles the background "Mark as Checked" action: logs an OK check and
    /// reschedules. A save failure is surfaced as an immediate notification —
    /// there is no UI to show an alert in.
    private func markChecked(itemUUID: UUID) async {
        guard let container else { return }
        let modelContext = container.mainContext
        var descriptor = FetchDescriptor<SupplyItem>(predicate: #Predicate { $0.uuid == itemUUID })
        descriptor.fetchLimit = 1
        guard let item = try? modelContext.fetch(descriptor).first else { return }

        let record = CheckRecord(date: .now, result: .ok)
        record.item = item
        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            let content = UNMutableNotificationContent()
            content.title = "Check wasn't saved"
            content.body = "Couldn't record the check for “\(item.name)”. Open MyInventory and try again."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "item-\(itemUUID.uuidString)-savefailure",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            try? await center.add(request)
            return
        }

        rescheduleAll(in: modelContext, globalLeadTimeDays: settings?.globalLeadTimeDays ?? 7)
    }

    // MARK: Helpers

    private func notificationText(for plan: PlannedNotification,
                                  item: SupplyItem?) -> (title: String, body: String) {
        let name = displayName(item)
        switch plan.kind {
        case .due:
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
                     categoryIdentifier: String?,
                     targetDay: Date,
                     now: Date,
                     calendar: Calendar) async -> Bool {
        let fireAt = Self.resolvedFireDate(targetDay: targetDay, now: now,
                                           fireHour: fireHour, calendar: calendar)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }

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

// MARK: - Delegate adapter

/// Small NSObject delegate kept separate from the @Observable manager. Forwards
/// system callbacks (arriving on arbitrary queues) back to the MainActor.
private final class NotificationDelegateAdapter: NSObject, UNUserNotificationCenterDelegate {

    /// (notification request identifier, action identifier)
    var onResponse: (@Sendable (String, String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Without this, notifications arriving while the app is foregrounded are
        // silently swallowed by the system.
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        onResponse?(response.notification.request.identifier, response.actionIdentifier)
    }
}
