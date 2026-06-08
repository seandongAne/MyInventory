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

    // MARK: - Notification planner (P1-b / P2-b)

    func testPlannerExcludesNeverExpires() {
        let item = makeItem(intervalMonths: nil)
        let plans = NotificationManager.plannedNotifications(
            for: [item], now: .now, windowDays: 90, globalLeadTimeDays: 7, maxPending: 60)
        XCTAssertTrue(plans.isEmpty)
    }

    func testPlannerSchedulesNeverCheckedFirstCheckNoLead() {
        let now = Date.now
        let item = makeItem(intervalMonths: 6)   // interval, zero checks
        let plans = NotificationManager.plannedNotifications(
            for: [item], now: now, windowDays: 90, globalLeadTimeDays: 7, maxPending: 60)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.kind, .due)
        XCTAssertEqual(plans.first?.fireDate, now)        // scheduled "now" (clamped to next 9am at add())
        XCTAssertFalse(plans.contains { $0.kind == .lead })
    }

    func testPlannerSchedulesFutureDueWithLead() {
        let now = Date.now
        let item = makeItem(intervalMonths: 12, dueOffsetDays: 30, now: now)
        let plans = NotificationManager.plannedNotifications(
            for: [item], now: now, windowDays: 90, globalLeadTimeDays: 7, maxPending: 60)
        XCTAssertTrue(plans.contains { $0.kind == .due })
        XCTAssertTrue(plans.contains { $0.kind == .lead && $0.leadDays == 7 })
    }

    func testPlannerExcludesOverdueWithHistory() {
        let now = Date.now
        let item = makeItem(intervalMonths: 6, dueOffsetDays: -10, now: now)
        let plans = NotificationManager.plannedNotifications(
            for: [item], now: now, windowDays: 90, globalLeadTimeDays: 7, maxPending: 60)
        XCTAssertTrue(plans.isEmpty)
    }

    func testPlannerExcludesBeyondWindow() {
        let now = Date.now
        let item = makeItem(intervalMonths: 24, dueOffsetDays: 200, now: now)
        let plans = NotificationManager.plannedNotifications(
            for: [item], now: now, windowDays: 90, globalLeadTimeDays: 7, maxPending: 60)
        XCTAssertTrue(plans.isEmpty)
    }

    func testPlannerRespectsCap() {
        let now = Date.now
        let a = makeItem(name: "A", intervalMonths: 12, dueOffsetDays: 10, now: now)
        let b = makeItem(name: "B", intervalMonths: 12, dueOffsetDays: 20, now: now)
        let plans = NotificationManager.plannedNotifications(
            for: [a, b], now: now, windowDays: 90, globalLeadTimeDays: 7, maxPending: 1)
        XCTAssertEqual(plans.count, 1)
    }

    func testPlannerSortsSoonestFirst() {
        let now = Date.now
        let later = makeItem(name: "Later", intervalMonths: 12, dueOffsetDays: 40, now: now)
        let sooner = makeItem(name: "Sooner", intervalMonths: 12, dueOffsetDays: 10, now: now)
        let plans = NotificationManager.plannedNotifications(
            for: [later, sooner], now: now, windowDays: 90, globalLeadTimeDays: 0, maxPending: 60)
        XCTAssertEqual(plans.first?.itemUUID, sooner.uuid)
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
            for: [a, b], now: now, windowDays: 90, globalLeadTimeDays: 7, maxPending: 1)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.itemUUID, a.uuid)
        XCTAssertEqual(plans.first?.kind, .lead)
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
}
