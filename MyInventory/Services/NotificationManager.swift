//
//  NotificationManager.swift
//  MyInventory
//
//  Local notifications for due / due-soon items, plus a single "needs attention"
//  digest (Dev Plan §5, §M4).
//
//  Key constraints handled here:
//   • iOS caps pending local notifications at 64 → reminders are BATCHED BY DAY
//     (same-day dues collapse into one "N supplies due" reminder) so the scarce
//     slots scale with the number of distinct due-days, not the item count. We
//     schedule the soonest-FIRING groups up to a cap kept well under 64; there is
//     no look-ahead window (far-future dues are scheduled too). A large inventory
//     opened only every few months relies on this — see `plannedNotifications`.
//     Refresh on app foreground.
//   • Never-expires (nil interval) items schedule nothing.
//   • Items needing action NOW (overdue, flagged, never-checked) are batched into
//     ONE digest notification at the next fire hour — never one nag per item, and
//     an item that slips overdue between reschedules still gets surfaced instead
//     of silently losing its (clamped-forward) due notification.
//   • A single "inactivity nudge" is armed ~1 month out and pushed forward on
//     every reschedule, so it only fires if the app goes untouched for a month —
//     pulling an infrequent user back so reminders + the digest stay fresh.
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

    /// Stable identifier of the single inactivity nudge. Like the digest, it has a
    /// fixed id (not a managed prefix) and is re-armed every pass, so the
    /// stale-removal sweep never touches it.
    static let inactivityNudgeIdentifier = "inactivity-nudge"

    /// Identifier prefixes we own in the pending queue: per-item reminders and
    /// day-batched reminders. The stale-removal sweep only ever touches these; the
    /// digest + nudge use fixed ids handled explicitly.
    private static let managedPrefixes = ["item-", "due-day-", "lead-day-"]

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
        var stale = pending.map(\.identifier).filter { id in
            Self.managedPrefixes.contains(where: id.hasPrefix) && !plannedIDs.contains(id)
        }
        if digest == nil { stale.append(Self.digestIdentifier) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        let byUUID = Dictionary(items.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var failures = 0
        for plan in plans {
            let (title, body) = notificationText(for: plan, byUUID: byUUID)
            // The "Mark as Checked" action targets a single item, so only
            // single-item reminders carry it; a batched day reminder deep-links to
            // the attention list instead.
            let category = plan.isBatch ? nil : Self.itemCategoryID
            let scheduled = await add(identifier: plan.identifier, title: title, body: body,
                                      categoryIdentifier: category,
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

        // Inactivity nudge: one reminder armed ~1 month out and pushed forward on
        // every reschedule. Opening the app keeps resetting it, so an active user
        // never sees it; if the app goes untouched for a month it fires once,
        // pulling the user back to refresh reminders + the digest. Cleared when
        // there's nothing to track.
        if !items.isEmpty,
           let nudgeDay = calendar.date(byAdding: .month, value: 1, to: now) {
            let scheduled = await add(identifier: Self.inactivityNudgeIdentifier,
                                      title: "Time to review your supplies",
                                      body: "Open MyInventory to make sure nothing's overdue.",
                                      categoryIdentifier: nil,
                                      targetDay: nudgeDay, now: now, calendar: calendar)
            if !scheduled { failures += 1 }
        } else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.inactivityNudgeIdentifier])
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
        let kind: Kind
        /// Target calendar day; the concrete fire time is this day at `fireHour`,
        /// clamped forward if that instant has already passed.
        let fireDate: Date
        /// Items sharing this day + kind. One → a personalised reminder carrying
        /// the "Mark as Checked" action and a per-item deep link; many → a single
        /// batched reminder ("N supplies …") that deep-links to the attention list.
        let itemUUIDs: [UUID]
        /// Pre-computed at planning time (a batch id is keyed by day, not item, so
        /// it can't be derived from a single uuid later).
        let identifier: String
        /// Lead days for the single-item lead text; 0 for due / batched lead.
        var leadDays: Int = 0

        var isBatch: Bool { itemUUIDs.count > 1 }
    }

    /// Decides which notifications to schedule, **batched by day** so the scarce
    /// notification slots scale with the number of distinct due-days, not the item
    /// count: a bulk check that lands 40 items on the same due date two years out
    /// collapses to ONE reminder instead of 40. The 64-cap is the real risk for a
    /// large inventory opened only every few months — batching is what keeps every
    /// future reminder armed across long gaps between app opens (Dev Plan §M4).
    /// Builds every day-group (due + lead), sorts by fire date, then caps — so the
    /// soonest-firing groups win the slots (a lead can correctly outrank a later
    /// day's due).
    ///
    /// Rules:
    ///  • nil interval (never expires)             → nothing.
    ///  • interval + any future due                → a due reminder + optional lead,
    ///                                               merged per calendar day.
    ///  • needs-action-now states (never checked,
    ///    overdue, flagged)                        → handled by the digest, not here.
    static func plannedNotifications(for items: [SupplyItem],
                                     now: Date,
                                     globalLeadTimeDays: Int,
                                     maxPending: Int,
                                     calendar: Calendar = .current) -> [PlannedNotification] {
        var dueByDay: [Date: [UUID]] = [:]
        var leadByDay: [Date: [(uuid: UUID, days: Int)]] = [:]

        for item in items {
            guard item.checkIntervalMonths != nil else { continue }   // never expires
            guard let due = item.nextDueDate(calendar: calendar), due > now else { continue }
            dueByDay[calendar.startOfDay(for: due), default: []].append(item.uuid)

            let lead = item.effectiveLeadTimeDays(globalLead: globalLeadTimeDays)
            if lead > 0,
               let leadDate = calendar.date(byAdding: .day, value: -lead, to: due),
               leadDate > now {
                leadByDay[calendar.startOfDay(for: leadDate), default: []].append((item.uuid, lead))
            }
        }

        var groups: [PlannedNotification] = []
        for (day, uuids) in dueByDay {
            groups.append(PlannedNotification(
                kind: .due, fireDate: day, itemUUIDs: uuids,
                identifier: scheduleIdentifier(kind: .due, day: day, uuids: uuids, calendar: calendar)))
        }
        for (day, entries) in leadByDay {
            let uuids = entries.map(\.uuid)
            groups.append(PlannedNotification(
                kind: .lead, fireDate: day, itemUUIDs: uuids,
                identifier: scheduleIdentifier(kind: .lead, day: day, uuids: uuids, calendar: calendar),
                leadDays: uuids.count == 1 ? entries[0].days : 0))
        }

        return Array(
            groups
                // Soonest-fire-first; the id tiebreak keeps the cap boundary
                // deterministic regardless of dictionary iteration order.
                .sorted {
                    $0.fireDate != $1.fireDate ? $0.fireDate < $1.fireDate
                                               : $0.identifier < $1.identifier
                }
                .prefix(maxPending)
        )
    }

    /// A single item → the per-item id (keeps the deep link + "Mark as Checked"
    /// action); several → a day-keyed batch id.
    private static func scheduleIdentifier(kind: PlannedNotification.Kind,
                                           day: Date,
                                           uuids: [UUID],
                                           calendar: Calendar) -> String {
        let suffix = kind == .due ? "due" : "lead"
        if uuids.count == 1 {
            return "item-\(uuids[0].uuidString)-\(suffix)"
        }
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return "\(suffix)-day-\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
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
        // Batched day reminders cover several items → land on the attention list.
        if identifier.hasPrefix("due-day-") || identifier.hasPrefix("lead-day-") { return .attention }
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
                                  byUUID: [UUID: SupplyItem]) -> (title: String, body: String) {
        let name = displayName(plan.itemUUIDs.first.flatMap { byUUID[$0] })
        switch plan.kind {
        case .due:
            if plan.isBatch {
                return ("Checks due", "\(plan.itemUUIDs.count) supplies are due for a check.")
            }
            return ("Check due", "\(name) is due for a check.")
        case .lead:
            if plan.isBatch {
                return ("Checks coming up", "\(plan.itemUUIDs.count) supplies are due soon.")
            }
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
