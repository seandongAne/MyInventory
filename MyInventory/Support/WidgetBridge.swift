//
//  WidgetBridge.swift
//  MyInventory
//
//  The widget extension can't open the app's SwiftData store (it lives outside
//  the app group, and sharing model code across targets would couple the widget
//  to the schema). Instead the app writes a small JSON snapshot to the shared
//  app-group container on every notification reschedule — which already runs
//  after every data mutation and on every foreground — and the widget just
//  renders the snapshot.
//
//  If the app group container is unavailable (entitlement missing / device not
//  provisioned), this is a silent no-op: widgets simply show their placeholder.
//

import Foundation
import WidgetKit

enum WidgetBridge {

    static let appGroupID = "group.CharlieW.MyInventory"
    static let snapshotFilename = "widget-snapshot.json"

    /// Mirror of the struct decoded in MyInventoryWidgets — keep the two in sync.
    struct Snapshot: Codable {
        struct Upcoming: Codable {
            let name: String
            let dueDate: Date
        }
        let generatedAt: Date
        let overdue: Int
        let flagged: Int
        let neverChecked: Int
        let upcoming: [Upcoming]

        var attentionTotal: Int { overdue + flagged + neverChecked }

        /// How many `upcoming` due dates have passed since the snapshot was
        /// written. The widget can't re-derive status without the store, but it
        /// CAN see a frozen future due date slip past the current timeline
        /// entry — counting those lets a stale snapshot degrade toward "needs
        /// attention" instead of asserting "All good" forever.
        func newlyDueCount(asOf date: Date) -> Int {
            upcoming.filter { $0.dueDate <= date }.count
        }

        /// Attention count to display at `date`: the counts frozen at
        /// `generatedAt` plus everything that has come due since.
        func attentionTotal(asOf date: Date) -> Int {
            attentionTotal + newlyDueCount(asOf: date)
        }

        /// Timeline-entry instants: `now`, plus one entry at each still-future
        /// due date, ascending — so the widget flips to "needs attention" at
        /// the moment an item comes due even if WidgetKit grants no timeline
        /// reload until then.
        func timelineEntryDates(now: Date) -> [Date] {
            [now] + upcoming.map(\.dueDate).filter { $0 > now }.sorted()
        }
    }

    static var snapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(snapshotFilename)
    }

    /// Pure snapshot builder (no I/O) so the attention/upcoming split is unit-testable.
    @MainActor
    static func makeSnapshot(for items: [SupplyItem],
                             globalLeadTimeDays: Int,
                             now: Date = .now,
                             calendar: Calendar = .current) -> Snapshot {
        var overdue = 0, flagged = 0, neverChecked = 0
        var upcomingItems: [Snapshot.Upcoming] = []
        for item in items {
            let status = item.status(leadTimeDays: globalLeadTimeDays, now: now, calendar: calendar)
            switch status {
            case .overdue: overdue += 1
            case .needsAttention: flagged += 1
            case .neverChecked: neverChecked += 1
            default: break
            }
            // Only items NOT already in the frozen attention totals may enter
            // `upcoming`. A `.needsAttention` item can still have a FUTURE due
            // date (the flag is from its last check, it isn't overdue yet), so
            // including it would let the widget's `newlyDueCount` add it a
            // SECOND time once that due date passes — double-counting one item.
            guard !status.isAttention,
                  let due = item.nextDueDate(calendar: calendar), due > now else { continue }
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            upcomingItems.append(Snapshot.Upcoming(name: name.isEmpty ? "Untitled item" : name, dueDate: due))
        }

        let upcoming = upcomingItems
            .sorted { $0.dueDate < $1.dueDate }
            // Also bounds how far the widget's local "newly due since
            // generatedAt" count can climb between app opens — keep it
            // comfortably above what one row of "next due" display needs.
            .prefix(10)

        return Snapshot(generatedAt: now,
                        overdue: overdue,
                        flagged: flagged,
                        neverChecked: neverChecked,
                        upcoming: Array(upcoming))
    }

    /// Builds and writes the snapshot, then asks WidgetKit to refresh timelines.
    @MainActor
    static func writeSnapshot(for items: [SupplyItem],
                              globalLeadTimeDays: Int,
                              now: Date = .now,
                              calendar: Calendar = .current) {
        guard let url = snapshotURL else { return }

        let snapshot = makeSnapshot(for: items,
                                    globalLeadTimeDays: globalLeadTimeDays,
                                    now: now,
                                    calendar: calendar)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        // Atomic write so the widget never reads a half-written file.
        try? data.write(to: url, options: .atomic)

        WidgetCenter.shared.reloadAllTimelines()
    }
}
