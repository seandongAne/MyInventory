//
//  MyInventoryTests.swift
//  MyInventoryTests
//
//  Unit coverage for the silent-failure-prone logic: derived status (incl.
//  needsAttention + overdue precedence), status labels, fuzzy search, the
//  notification planner (never-checked included / overdue & never-expires
//  excluded / cap / ordering), and the Uncategorized move.
//

import XCTest
import SwiftData
@testable import MyInventory

@MainActor
final class MyInventoryTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let cal = Calendar.current

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    // MARK: Helpers

    @discardableResult
    private func makeItem(name: String = "Item", intervalMonths: Int?) -> SupplyItem {
        let item = SupplyItem(name: name, checkIntervalMonths: intervalMonths)
        context.insert(item)
        try? context.save()
        return item
    }

    private func addCheck(_ item: SupplyItem, date: Date, result: CheckResult = .ok) {
        let record = CheckRecord(date: date, result: result)
        record.item = item
        context.insert(record)
        try? context.save()
    }

    /// Builds an item whose next due date lands exactly `dueOffsetDays` from `now`,
    /// by back-dating its single check by `intervalMonths`.
    private func makeItem(name: String = "Item",
                          intervalMonths: Int,
                          dueOffsetDays: Int,
                          lastResult: CheckResult = .ok,
                          now: Date) -> SupplyItem {
        let item = makeItem(name: name, intervalMonths: intervalMonths)
        let dueTarget = cal.date(byAdding: .day, value: dueOffsetDays, to: now)!
        let checkDate = cal.date(byAdding: .month, value: -intervalMonths, to: dueTarget)!
        addCheck(item, date: checkDate, result: lastResult)
        return item
    }

    // MARK: - Derived status

    func testNeverExpiresWhenNoInterval() {
        let item = makeItem(intervalMonths: nil)
        XCTAssertEqual(item.status(leadTimeDays: 7), .neverExpires)
    }

    func testNeverCheckedWhenIntervalButNoChecks() {
        let item = makeItem(intervalMonths: 6)
        XCTAssertEqual(item.status(leadTimeDays: 7), .neverChecked)
    }

    func testOkWhenDueIsFarFuture() {
        let now = Date.now
        let item = makeItem(intervalMonths: 12, dueOffsetDays: 60, now: now)
        XCTAssertEqual(item.status(leadTimeDays: 7, now: now), .ok)
    }

    func testDueSoonInsideLeadWindow() {
        let now = Date.now
        let item = makeItem(intervalMonths: 12, dueOffsetDays: 4, now: now)
        XCTAssertEqual(item.status(leadTimeDays: 7, now: now), .dueSoon)
    }

    func testOverdueWhenPastDue() {
        let now = Date.now
        let item = makeItem(intervalMonths: 6, dueOffsetDays: -5, now: now)
        XCTAssertEqual(item.status(leadTimeDays: 7, now: now), .overdue)
    }

    func testOverdueAtExactDueInstant() {
        // Fixed mid-month date so the ±6 month round-trip is exact, making
        // nextDueDate == now precisely — the `now >= due` boundary.
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 12))!
        let item = makeItem(intervalMonths: 6)
        addCheck(item, date: cal.date(byAdding: .month, value: -6, to: now)!)
        XCTAssertEqual(item.nextDueDate(), now)
        XCTAssertEqual(item.status(leadTimeDays: 7, now: now), .overdue)
    }

    // MARK: - needsAttention (P1-a)

    func testNeedsAttentionSurfacesWhenNotOverdue() {
        let now = Date.now
        // Due far in the future, but last check was flagged.
        let item = makeItem(intervalMonths: 12, dueOffsetDays: 60, lastResult: .needsAttention, now: now)
        XCTAssertEqual(item.status(leadTimeDays: 7, now: now), .needsAttention)
    }

    func testOverdueBeatsNeedsAttention() {
        let now = Date.now
        let item = makeItem(intervalMonths: 6, dueOffsetDays: -10, lastResult: .needsAttention, now: now)
        XCTAssertEqual(item.status(leadTimeDays: 7, now: now), .overdue)
    }

    func testNeverExpiresStillHonorsNeedsAttentionFlag() {
        // Decision: an explicit "Needs attention" must not be lost even on a no-expiry item.
        let item = makeItem(intervalMonths: nil)
        addCheck(item, date: .now, result: .needsAttention)
        XCTAssertEqual(item.status(leadTimeDays: 7), .needsAttention)
    }

    func testLaterOkCheckClearsAttention() {
        let now = Date.now
        let item = makeItem(intervalMonths: 12)
        addCheck(item, date: cal.date(byAdding: .day, value: -10, to: now)!, result: .needsAttention)
        addCheck(item, date: cal.date(byAdding: .day, value: -1, to: now)!, result: .ok)
        XCTAssertEqual(item.status(leadTimeDays: 7, now: now), .ok)
    }

    func testStatusSortPriorityOrder() {
        XCTAssertLessThan(SupplyStatus.overdue.sortPriority, SupplyStatus.needsAttention.sortPriority)
        XCTAssertLessThan(SupplyStatus.needsAttention.sortPriority, SupplyStatus.neverChecked.sortPriority)
        XCTAssertLessThan(SupplyStatus.neverChecked.sortPriority, SupplyStatus.dueSoon.sortPriority)
        XCTAssertLessThan(SupplyStatus.dueSoon.sortPriority, SupplyStatus.ok.sortPriority)
        XCTAssertLessThan(SupplyStatus.ok.sortPriority, SupplyStatus.neverExpires.sortPriority)
    }

    // MARK: - Status detail label

    func testStatusDetailLabels() {
        let now = Date.now
        XCTAssertEqual(makeItem(intervalMonths: nil).statusDetailLabel(globalLead: 7), "No expiry")
        XCTAssertEqual(makeItem(intervalMonths: 6).statusDetailLabel(globalLead: 7), "Needs first check")

        let overdue = makeItem(intervalMonths: 6, dueOffsetDays: -3, now: now)
        XCTAssertTrue(overdue.statusDetailLabel(globalLead: 7, now: now).hasPrefix("Overdue"))

        let attention = makeItem(intervalMonths: 12, dueOffsetDays: 60, lastResult: .needsAttention, now: now)
        XCTAssertEqual(attention.statusDetailLabel(globalLead: 7, now: now), "Flagged at last check")
    }

    func testDaysUntilDue() {
        let now = Date.now
        let item = makeItem(intervalMonths: 12, dueOffsetDays: 5, now: now)
        XCTAssertEqual(item.daysUntilDue(now: now), 5)
    }

    // MARK: - Fuzzy search

    func testFuzzyEmptyQueryReturnsAll() {
        let a = makeItem(name: "Water", intervalMonths: nil)
        let b = makeItem(name: "Knife", intervalMonths: nil)
        XCTAssertEqual(FuzzySearch.rank([a, b], query: "   ").count, 2)
    }

    func testFuzzyRanksExactAndPrefixAboveTypos() {
        let tuna = makeItem(name: "Tuna", intervalMonths: nil)
        let tunic = makeItem(name: "Tunic", intervalMonths: nil)
        let canned = makeItem(name: "Canned tuna", intervalMonths: nil)

        let results = FuzzySearch.rank([tunic, canned, tuna], query: "tuna")
        XCTAssertEqual(results.first?.name, "Tuna")             // exact wins
        XCTAssertTrue(results.contains { $0.name == "Canned tuna" })  // token match included
    }

    func testFuzzyToleratesTypo() {
        let knife = makeItem(name: "Knife", intervalMonths: nil)
        let results = FuzzySearch.rank([knife], query: "knfe")
        XCTAssertEqual(results.first?.name, "Knife")
    }

    func testFuzzyMatchesContextName() throws {
        let supplyCtx = SupplyContext(name: "Vehicle", sortOrder: 0)
        context.insert(supplyCtx)
        let cat = SupplyCategory(name: "Kit", sortOrder: 0)
        cat.context = supplyCtx
        context.insert(cat)
        let item = makeItem(name: "Flashlight", intervalMonths: nil)
        item.category = cat
        try context.save()

        XCTAssertEqual(FuzzySearch.rank([item], query: "vehicle").count, 1)
    }

    func testFuzzyMatchesCheckComment() {
        let item = makeItem(name: "Power Bank", intervalMonths: nil)
        let record = CheckRecord(date: .now, result: .replaced, comment: "swapped the lithium cells")
        record.item = item
        context.insert(record)
        try? context.save()

        XCTAssertEqual(FuzzySearch.rank([item], query: "lithium").count, 1)
        XCTAssertTrue(FuzzySearch.rank([item], query: "zzzz").isEmpty)
    }

    // MARK: - Notification planner (P1-b / P2-b)

    func testPlannerExcludesNeverExpires() {
        let item = makeItem(intervalMonths: nil)
        let plans = NotificationManager.plannedNotifications(
            for: [item], now: .now, globalLeadTimeDays: 7, maxPending: 60)
        XCTAssertTrue(plans.isEmpty)
    }

    func testPlannerExcludesNeverChecked() {
        // Never-checked items are surfaced by the attention DIGEST, not a
        // per-item nag — adding 20 new items must not queue 20 notifications.
        let now = Date.now
        let item = makeItem(intervalMonths: 6)   // interval, zero checks
        let plans = NotificationManager.plannedNotifications(
            for: [item], now: now, globalLeadTimeDays: 7, maxPending: 60)
        XCTAssertTrue(plans.isEmpty)
    }

    func testPlannerSchedulesFutureDueWithLead() {
        let now = Date.now
        let item = makeItem(intervalMonths: 12, dueOffsetDays: 30, now: now)
        let plans = NotificationManager.plannedNotifications(
            for: [item], now: now, globalLeadTimeDays: 7, maxPending: 60)
        XCTAssertTrue(plans.contains { $0.kind == .due })
        XCTAssertTrue(plans.contains { $0.kind == .lead && $0.leadDays == 7 })
    }

    func testPlannerExcludesOverdueWithHistory() {
        let now = Date.now
        let item = makeItem(intervalMonths: 6, dueOffsetDays: -10, now: now)
        let plans = NotificationManager.plannedNotifications(
            for: [item], now: now, globalLeadTimeDays: 7, maxPending: 60)
        XCTAssertTrue(plans.isEmpty)
    }

    func testPlannerSchedulesFarFutureDue() {
        let now = Date.now
        // A due date far in the future (well beyond the old 90-day window) must now
        // be scheduled — a personal-scale inventory never exhausts the 64 cap.
        let item = makeItem(intervalMonths: 24, dueOffsetDays: 200, now: now)
        let plans = NotificationManager.plannedNotifications(
            for: [item], now: now, globalLeadTimeDays: 7, maxPending: 60)
        XCTAssertTrue(plans.contains { $0.kind == .due })
    }

    func testPlannerRespectsCap() {
        let now = Date.now
        let a = makeItem(name: "A", intervalMonths: 12, dueOffsetDays: 10, now: now)
        let b = makeItem(name: "B", intervalMonths: 12, dueOffsetDays: 20, now: now)
        let plans = NotificationManager.plannedNotifications(
            for: [a, b], now: now, globalLeadTimeDays: 7, maxPending: 1)
        XCTAssertEqual(plans.count, 1)
    }

    func testPlannerSortsSoonestFirst() {
        let now = Date.now
        let later = makeItem(name: "Later", intervalMonths: 12, dueOffsetDays: 40, now: now)
        let sooner = makeItem(name: "Sooner", intervalMonths: 12, dueOffsetDays: 10, now: now)
        let plans = NotificationManager.plannedNotifications(
            for: [later, sooner], now: now, globalLeadTimeDays: 0, maxPending: 60)
        XCTAssertEqual(plans.first?.itemUUIDs, [sooner.uuid])
    }

    func testPlannerCapPrefersSoonestFireAcrossDueAndLead() {
        let now = Date.now
        // Item A: due in 30 days, lead 10 → its LEAD fires on day 20.
        let a = makeItem(name: "A", intervalMonths: 12, dueOffsetDays: 30, now: now)
        a.leadTimeDaysOverride = 10
        // Item B: due in 25 days, no lead.
        let b = makeItem(name: "B", intervalMonths: 12, dueOffsetDays: 25, now: now)
        b.leadTimeDaysOverride = 0
        try? context.save()

        // With a single slot, it must go to A's lead (fires day 20) — the soonest
        // FIRING notification — not B's due (day 25).
        let plans = NotificationManager.plannedNotifications(
            for: [a, b], now: now, globalLeadTimeDays: 7, maxPending: 1)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.itemUUIDs, [a.uuid])
        XCTAssertEqual(plans.first?.kind, .lead)
    }

    // MARK: - Day batching (keeps a large, infrequently-opened inventory under the cap)

    func testPlannerBatchesSameDayDuesIntoOneNotification() {
        let now = Date.now
        // 40 items bulk-checked together → all due the SAME day two years out.
        // Without batching that's 40 due reminders; with it, a single grouped one.
        let items = (0..<40).map {
            makeItem(name: "Item\($0)", intervalMonths: 24, dueOffsetDays: 200, now: now)
        }
        let plans = NotificationManager.plannedNotifications(
            for: items, now: now, globalLeadTimeDays: 0, maxPending: 60)
        let due = plans.filter { $0.kind == .due }
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.itemUUIDs.count, 40)
        XCTAssertEqual(due.first?.isBatch, true)
        XCTAssertEqual(due.first?.identifier.hasPrefix("due-day-"), true)
    }

    func testPlannerKeepsPerItemIdentifierForSingleItemDay() {
        let now = Date.now
        // A lone item on its own due day keeps the per-item id, so its tap deep
        // link and "Mark as Checked" action still work.
        let item = makeItem(intervalMonths: 12, dueOffsetDays: 30, now: now)
        let plans = NotificationManager.plannedNotifications(
            for: [item], now: now, globalLeadTimeDays: 0, maxPending: 60)
        let due = plans.first { $0.kind == .due }
        XCTAssertEqual(due?.isBatch, false)
        XCTAssertEqual(due?.identifier, "item-\(item.uuid.uuidString)-due")
    }

    func testPlannerCapCountsDaysNotItems() {
        let now = Date.now
        // 70 items on the SAME due day fit in a single slot — 70 per-item
        // notifications would blow straight past the iOS 64-cap.
        let items = (0..<70).map {
            makeItem(name: "Item\($0)", intervalMonths: 24, dueOffsetDays: 200, now: now)
        }
        let plans = NotificationManager.plannedNotifications(
            for: items, now: now, globalLeadTimeDays: 0, maxPending: 60)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.itemUUIDs.count, 70)
    }

    // MARK: - Attention digest (overdue / flagged / never-checked → ONE notification)

    func testDigestCountsAllAttentionStates() {
        let now = Date.now
        _ = makeItem(name: "Overdue", intervalMonths: 6, dueOffsetDays: -10, now: now)
        _ = makeItem(name: "Flagged", intervalMonths: 12, dueOffsetDays: 60,
                     lastResult: .needsAttention, now: now)
        let neverChecked = makeItem(name: "New", intervalMonths: 6)
        _ = neverChecked
        _ = makeItem(name: "Fine", intervalMonths: 12, dueOffsetDays: 60, now: now)
        _ = makeItem(name: "NoExpiry", intervalMonths: nil)

        let items = try! context.fetch(FetchDescriptor<SupplyItem>())
        let digest = NotificationManager.attentionSummary(
            for: items, globalLeadTimeDays: 7, now: now)
        XCTAssertEqual(digest?.overdue, 1)
        XCTAssertEqual(digest?.flagged, 1)
        XCTAssertEqual(digest?.neverChecked, 1)
        XCTAssertEqual(digest?.total, 3)
    }

    func testDigestNilWhenNothingNeedsAttention() {
        let now = Date.now
        _ = makeItem(name: "Fine", intervalMonths: 12, dueOffsetDays: 60, now: now)
        _ = makeItem(name: "NoExpiry", intervalMonths: nil)

        let items = try! context.fetch(FetchDescriptor<SupplyItem>())
        XCTAssertNil(NotificationManager.attentionSummary(
            for: items, globalLeadTimeDays: 7, now: now))
    }

    func testDigestCoversItemThatSlippedOverdueBetweenReschedules() {
        // The lost-window case: an item whose due instant passed earlier today.
        // Its per-item due notification is gone, but the digest must pick it up.
        let now = Date.now
        let item = makeItem(intervalMonths: 6, dueOffsetDays: 0, now: now)
        _ = item
        let items = try! context.fetch(FetchDescriptor<SupplyItem>())

        XCTAssertTrue(NotificationManager.plannedNotifications(
            for: items, now: now, globalLeadTimeDays: 7, maxPending: 60).isEmpty)
        XCTAssertEqual(NotificationManager.attentionSummary(
            for: items, globalLeadTimeDays: 7, now: now)?.total, 1)
    }

    // MARK: - Fire-date clamping (extracted from add() so it's testable)

    func testResolvedFireDateBeforeFireHourFiresSameDay() {
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 8))!
        let fireAt = NotificationManager.resolvedFireDate(targetDay: now, now: now, fireHour: 9)
        XCTAssertEqual(cal.dateComponents([.day, .hour], from: fireAt).day, 9)
        XCTAssertEqual(cal.dateComponents([.hour], from: fireAt).hour, 9)
    }

    func testResolvedFireDateAfterFireHourBumpsToNextDay() {
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 10))!
        let fireAt = NotificationManager.resolvedFireDate(targetDay: now, now: now, fireHour: 9)
        XCTAssertEqual(cal.dateComponents([.day], from: fireAt).day, 10)
        XCTAssertEqual(cal.dateComponents([.hour], from: fireAt).hour, 9)
    }

    func testResolvedFireDateFutureDayFiresAtFireHour() {
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 10))!
        let target = cal.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 15))!
        let fireAt = NotificationManager.resolvedFireDate(targetDay: target, now: now, fireHour: 21)
        XCTAssertEqual(cal.dateComponents([.day], from: fireAt).day, 20)
        XCTAssertEqual(cal.dateComponents([.hour], from: fireAt).hour, 21)
    }

    // MARK: - Notification deep-link identifier parsing

    func testDeepLinkParsing() {
        let uuid = UUID()
        XCTAssertEqual(NotificationManager.deepLink(forNotificationIdentifier: "item-\(uuid.uuidString)-due"),
                       .item(uuid))
        XCTAssertEqual(NotificationManager.deepLink(forNotificationIdentifier: "item-\(uuid.uuidString)-lead"),
                       .item(uuid))
        XCTAssertEqual(NotificationManager.deepLink(forNotificationIdentifier: NotificationManager.digestIdentifier),
                       .attention)
        // Batched day reminders cover several items → attention list, not one item.
        XCTAssertEqual(NotificationManager.deepLink(forNotificationIdentifier: "due-day-2027-1-7"), .attention)
        XCTAssertEqual(NotificationManager.deepLink(forNotificationIdentifier: "lead-day-2027-1-7"), .attention)
        XCTAssertNil(NotificationManager.deepLink(forNotificationIdentifier: "something-else"))
        XCTAssertNil(NotificationManager.deepLink(forNotificationIdentifier: "item-not-a-uuid-due"))
    }

    // MARK: - Export

    func testExportRoundTripsHierarchy() throws {
        let supplyCtx = SupplyContext(name: "Vehicle", sortOrder: 0)
        context.insert(supplyCtx)
        let cat = SupplyCategory(name: "Kit", sortOrder: 0)
        cat.context = supplyCtx
        context.insert(cat)
        let item = SupplyItem(name: "First Aid Kit", checkIntervalMonths: 6)
        item.quantity = 2
        item.category = cat
        context.insert(item)
        let check = CheckRecord(date: .now, result: .replaced, comment: "restocked")
        check.item = item
        context.insert(check)
        try context.save()

        let data = try DataExporter.makeExport(from: context)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(DataExporter.Export.self, from: data)

        XCTAssertEqual(export.contexts.count, 1)
        XCTAssertEqual(export.contexts.first?.categories.count, 1)
        let exportedItem = export.contexts.first?.categories.first?.items.first
        XCTAssertEqual(exportedItem?.name, "First Aid Kit")
        XCTAssertEqual(exportedItem?.quantity, 2)
        XCTAssertEqual(exportedItem?.checks.count, 1)
        XCTAssertEqual(exportedItem?.checks.first?.result, CheckResult.replaced.rawValue)
    }

    // MARK: - Templates

    func testTemplateApplyIsIdempotent() throws {
        let supplyCtx = SupplyContext(name: "Vehicle", sortOrder: 0)
        context.insert(supplyCtx)
        try context.save()

        let added = try Templates.apply(Templates.vehicleKit, to: supplyCtx, in: context)
        XCTAssertEqual(added, Templates.vehicleKit.itemCount)

        // Re-applying must not duplicate categories or items.
        let addedAgain = try Templates.apply(Templates.vehicleKit, to: supplyCtx, in: context)
        XCTAssertEqual(addedAgain, 0)
        XCTAssertEqual(supplyCtx.unwrappedCategories.count, Templates.vehicleKit.categories.count)
        XCTAssertEqual(supplyCtx.allItems.count, Templates.vehicleKit.itemCount)
    }

    // MARK: - Uncategorized bucket (shared find-or-create)

    func testUncategorizedBucketIsCreatedOnceAndReused() throws {
        let supplyCtx = SupplyContext(name: "Vehicle", sortOrder: 0)
        context.insert(supplyCtx)
        try context.save()

        let first = SupplyCategory.uncategorizedBucket(in: supplyCtx, modelContext: context)
        try context.save()
        let second = SupplyCategory.uncategorizedBucket(in: supplyCtx, modelContext: context)

        XCTAssertTrue(first.isUncategorized)
        XCTAssertEqual(first.persistentModelID, second.persistentModelID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SupplyCategory>()), 1)
    }

    // MARK: - Check deletion (mistaken check must be correctable)

    func testDeletingLatestCheckRestoresPreviousDueDate() throws {
        let now = Date.now
        let item = makeItem(intervalMonths: 6)
        let olderDate = cal.date(byAdding: .month, value: -2, to: now)!
        addCheck(item, date: olderDate)
        addCheck(item, date: now)   // the mistaken check
        XCTAssertEqual(item.lastCheck!.date.timeIntervalSince1970,
                       now.timeIntervalSince1970, accuracy: 1)

        context.delete(item.lastCheck!)
        try context.save()

        // Status/due date derive from lastCheck, so deleting the mistaken check
        // falls straight back to the older one — nothing else to fix up.
        XCTAssertEqual(item.lastCheck!.date.timeIntervalSince1970,
                       olderDate.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CheckRecord>()), 1)
    }

    // MARK: - Uncategorized move (model level)

    func testMovingItemToBucketEmptiesSourceCategory() throws {
        let supplyCtx = SupplyContext(name: "Vehicle", sortOrder: 0)
        context.insert(supplyCtx)
        let source = SupplyCategory(name: "Emergency Kit", sortOrder: 0)
        source.context = supplyCtx
        context.insert(source)
        let bucket = SupplyCategory(name: SupplyCategory.uncategorizedName, sortOrder: 1)
        bucket.context = supplyCtx
        context.insert(bucket)

        let item = SupplyItem(name: "Flares", checkIntervalMonths: nil)
        item.category = source
        context.insert(item)
        try context.save()

        item.category = bucket
        try context.save()

        XCTAssertEqual(item.category?.name, SupplyCategory.uncategorizedName)
        XCTAssertTrue(source.unwrappedItems.isEmpty)
        XCTAssertEqual(bucket.unwrappedItems.count, 1)
        XCTAssertTrue(bucket.isUncategorized)
    }

    // MARK: - Context deletion (orphan safety, #3)

    func testDeletingContextDeletesItemsLeavingNoOrphans() throws {
        // Context -> Category -> Item -> Check.
        let supplyCtx = SupplyContext(name: "Cabin", sortOrder: 0)
        context.insert(supplyCtx)
        let cat = SupplyCategory(name: "Stove Kit", sortOrder: 0)
        cat.context = supplyCtx
        context.insert(cat)
        let item = SupplyItem(name: "Fuel Canister", checkIntervalMonths: 12)
        item.category = cat
        context.insert(item)
        let check = CheckRecord(date: .now, result: .ok)
        check.item = item
        context.insert(check)
        try context.save()

        // Delete exactly as ContentView.deleteContext does: items first (so the
        // .nullify category->item rule can't orphan them), then the context (whose
        // .cascade removes its categories; item->check .cascade removes history).
        for it in supplyCtx.allItems { context.delete(it) }
        context.delete(supplyCtx)
        try context.save()

        // Nothing left behind — no orphaned context, category, item, or check.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SupplyContext>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SupplyCategory>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SupplyItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CheckRecord>()), 0)
    }
}
