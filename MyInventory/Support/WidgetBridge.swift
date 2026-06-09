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
    }

    static var snapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(snapshotFilename)
    }

    /// Builds and writes the snapshot, then asks WidgetKit to refresh timelines.
    @MainActor
    static func writeSnapshot(for items: [SupplyItem],
                              globalLeadTimeDays: Int,
                              now: Date = .now,
                              calendar: Calendar = .current) {
        guard let url = snapshotURL else { return }

        var overdue = 0, flagged = 0, neverChecked = 0
        for item in items {
            switch item.status(leadTimeDays: globalLeadTimeDays, now: now, calendar: calendar) {
            case .overdue: overdue += 1
            case .needsAttention: flagged += 1
            case .neverChecked: neverChecked += 1
            default: break
            }
        }

        let upcoming = items
            .compactMap { item -> Snapshot.Upcoming? in
                guard let due = item.nextDueDate(calendar: calendar), due > now else { return nil }
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return Snapshot.Upcoming(name: name.isEmpty ? "Untitled item" : name, dueDate: due)
            }
            .sorted { $0.dueDate < $1.dueDate }
            .prefix(5)

        let snapshot = Snapshot(generatedAt: now,
                                overdue: overdue,
                                flagged: flagged,
                                neverChecked: neverChecked,
                                upcoming: Array(upcoming))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        // Atomic write so the widget never reads a half-written file.
        try? data.write(to: url, options: .atomic)

        WidgetCenter.shared.reloadAllTimelines()
    }
}
