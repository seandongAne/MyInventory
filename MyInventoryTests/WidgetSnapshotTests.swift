//
//  WidgetSnapshotTests.swift
//  MyInventoryTests
//
//  Covers the pure staleness helpers on WidgetBridge.Snapshot (mirrored in the
//  widget's WidgetSnapshot — keep the two in sync): a due date that passes
//  AFTER the snapshot was written must count as attention at render time, and
//  the timeline must get an entry at each future due date so the flip happens
//  on time. Without these, a frozen snapshot renders "All good" forever.
//

import XCTest
import SwiftData
@testable import MyInventory

final class WidgetSnapshotTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func snapshot(overdue: Int = 0,
                          flagged: Int = 0,
                          neverChecked: Int = 0,
                          dueOffsets: [TimeInterval] = []) -> WidgetBridge.Snapshot {
        WidgetBridge.Snapshot(
            generatedAt: base,
            overdue: overdue,
            flagged: flagged,
            neverChecked: neverChecked,
            upcoming: dueOffsets.enumerated().map { index, offset in
                WidgetBridge.Snapshot.Upcoming(name: "Item \(index)", dueDate: base.addingTimeInterval(offset))
            }
        )
    }

    // MARK: newlyDueCount(asOf:)

    func testNoUpcomingPassedMeansNothingNewlyDue() {
        let snap = snapshot(dueOffsets: [3600, 86_400])
        XCTAssertEqual(snap.newlyDueCount(asOf: base), 0)
        XCTAssertEqual(snap.newlyDueCount(asOf: base.addingTimeInterval(1800)), 0)
    }

    func testPassedDuesCountAsNewlyDue() {
        let snap = snapshot(dueOffsets: [3600, 7200, 86_400])
        let render = base.addingTimeInterval(10_000) // first two passed, third still ahead
        XCTAssertEqual(snap.newlyDueCount(asOf: render), 2)
    }

    func testDueExactlyAtRenderInstantCountsAsDue() {
        // Boundary must partition with the "next up" filter (dueDate > entry.date):
        // at the exact due instant the item is due, not "coming up".
        let snap = snapshot(dueOffsets: [3600])
        let dueInstant = base.addingTimeInterval(3600)
        XCTAssertEqual(snap.newlyDueCount(asOf: dueInstant), 1)
        XCTAssertEqual(snap.upcoming.filter { $0.dueDate > dueInstant }.count, 0)
    }

    // MARK: attentionTotal(asOf:)

    func testAttentionTotalAddsNewlyDueToFrozenCounts() {
        let snap = snapshot(overdue: 1, flagged: 1, neverChecked: 1, dueOffsets: [3600, 7200])
        XCTAssertEqual(snap.attentionTotal, 3)
        XCTAssertEqual(snap.attentionTotal(asOf: base), 3)
        XCTAssertEqual(snap.attentionTotal(asOf: base.addingTimeInterval(5000)), 4)
        XCTAssertEqual(snap.attentionTotal(asOf: base.addingTimeInterval(90_000)), 5)
    }

    func testAllGoodSnapshotDegradesToAttentionOncePassed() {
        // The false-safety case: zero attention at write time, one item due later.
        let snap = snapshot(dueOffsets: [3600])
        XCTAssertEqual(snap.attentionTotal(asOf: base), 0)
        XCTAssertEqual(snap.attentionTotal(asOf: base.addingTimeInterval(3601)), 1)
    }

    // MARK: timelineEntryDates(now:)

    func testTimelineDatesStartNowAndCoverFutureDuesAscending() {
        // Unsorted on purpose — the helper must not rely on write-side ordering.
        let snap = snapshot(dueOffsets: [7200, 3600])
        let now = base.addingTimeInterval(60)
        XCTAssertEqual(snap.timelineEntryDates(now: now),
                       [now, base.addingTimeInterval(3600), base.addingTimeInterval(7200)])
    }

    func testTimelineDatesExcludePassedAndExactlyDueDates() {
        let snap = snapshot(dueOffsets: [3600, 7200])
        let now = base.addingTimeInterval(3600) // first due exactly now → already counted, no future entry
        XCTAssertEqual(snap.timelineEntryDates(now: now), [now, base.addingTimeInterval(7200)])
    }

    func testTimelineDatesWithNoUpcomingIsJustNow() {
        XCTAssertEqual(snapshot().timelineEntryDates(now: base), [base])
    }

    // MARK: makeSnapshot — attention/upcoming split (no double-count)

    @MainActor
    func testFlaggedItemWithFutureDueIsNotAlsoInUpcoming() throws {
        // A `.needsAttention` item whose next due date is still in the future
        // must be counted ONCE (in `flagged`) and NOT put in `upcoming` — else
        // the widget's newlyDueCount would add it a second time when due passes.
        let container = try ModelContainer(
            for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let cal = Calendar.current
        let now = base

        // Flagged item due SOON (interval 12mo, last check 11mo ago and flagged
        // → due ~1 month out, future) so its due passes BEFORE the OK item's —
        // letting us isolate that the flagged item never contributes a second
        // time to the count.
        let flaggedItem = SupplyItem(name: "Flagged Radio", checkIntervalMonths: 12)
        context.insert(flaggedItem)
        let flaggedCheck = CheckRecord(date: cal.date(byAdding: .month, value: -11, to: now)!,
                                       result: .needsAttention)
        flaggedCheck.item = flaggedItem
        context.insert(flaggedCheck)

        // A plain OK item due much later (interval 12mo, last check 1mo ago →
        // due ~11 months out) → the legitimate upcoming entry.
        let okItem = SupplyItem(name: "Water", checkIntervalMonths: 12)
        context.insert(okItem)
        let okCheck = CheckRecord(date: cal.date(byAdding: .month, value: -1, to: now)!, result: .ok)
        okCheck.item = okItem
        context.insert(okCheck)
        try context.save()

        XCTAssertEqual(flaggedItem.status(leadTimeDays: 7, now: now), .needsAttention)
        XCTAssertEqual(okItem.status(leadTimeDays: 7, now: now), .ok)

        let snap = WidgetBridge.makeSnapshot(for: [flaggedItem, okItem],
                                             globalLeadTimeDays: 7,
                                             now: now,
                                             calendar: cal)

        XCTAssertEqual(snap.flagged, 1)
        // Only the OK item is upcoming; the flagged item is excluded.
        XCTAssertEqual(snap.upcoming.map(\.name), ["Water"])

        let flaggedDue = flaggedItem.nextDueDate(calendar: cal)!
        let waterDue = okItem.nextDueDate(calendar: cal)!

        // Nothing due yet: just the frozen flag.
        XCTAssertEqual(snap.attentionTotal(asOf: now), 1)
        // Flagged item's due has passed but it was NOT in `upcoming`, so the
        // count stays 1 (pre-fix this double-counted to 2).
        XCTAssertEqual(snap.attentionTotal(asOf: flaggedDue.addingTimeInterval(1)), 1)
        // The OK item passing its due IS a legitimate new attention → 2.
        XCTAssertEqual(snap.attentionTotal(asOf: waterDue.addingTimeInterval(1)), 2)
    }
}
