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
}
