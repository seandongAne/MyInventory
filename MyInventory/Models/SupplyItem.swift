//
//  SupplyItem.swift
//  MyInventory
//
//  A single tracked supply. Status (OK / due / overdue / …) is NEVER stored —
//  it is always derived from the most-recent check + interval vs. "now"
//  (Dev Plan §2.1). Storing it would go stale across synced devices.
//

import Foundation
import SwiftData

@Model
final class SupplyItem {
    var name: String = ""

    // Re-check cadence as a value + unit (days/months/years). A nil value means
    // "never expires": never flagged, never notified. `intervalUnit` raw values
    // mirror the cross-platform canonical schema. Renamed from the old months-only
    // `checkIntervalMonths` — `originalName` lets SwiftData lightweight-migrate the
    // existing column in place (no data loss, no custom MigrationPlan needed).
    @Attribute(originalName: "checkIntervalMonths") var intervalValue: Int? = nil
    var intervalUnit: String = IntervalUnit.months.rawValue

    // Optional free-text note (synced; shared with the Android app).
    var notes: String? = nil

    // Optional advance-warning override in days. nil => use the global default.
    var leadTimeDaysOverride: Int? = nil

    // Optional on-hand quantity (e.g. 4 batteries, 2 water bottles). nil = not tracked.
    var quantity: Int? = nil

    var storageLocation: String? = nil

    // Single optional photo (v1). External storage keeps the DB light.
    @Attribute(.externalStorage) var photo: Data? = nil

    var createdAt: Date = Date.now

    // Last-modified timestamp for cross-platform last-write-wins sync (Phase 2).
    // Present from S1 so the field doesn't need a second migration; the bumping
    // logic on each mutation is wired up in Phase 2.
    var modifiedAt: Date = Date.now

    // Stable identifier used for notification request IDs (CloudKit forbids .unique).
    var uuid: UUID = UUID()

    // Inverse of SupplyCategory.items.
    var category: SupplyCategory?

    @Relationship(deleteRule: .cascade, inverse: \CheckRecord.item)
    var checks: [CheckRecord]? = []

    /// Convenience initializer. `checkIntervalMonths` keeps the common months-based
    /// call sites (seed data, templates, previews, tests) terse by mapping onto
    /// `intervalValue` with `intervalUnit == .months`. Set `intervalValue` /
    /// `intervalUnit` directly for day- or year-based cadences.
    init(name: String = "",
         checkIntervalMonths: Int? = nil,
         storageLocation: String? = nil,
         notes: String? = nil) {
        self.name = name
        self.intervalValue = checkIntervalMonths
        self.intervalUnit = IntervalUnit.months.rawValue
        self.storageLocation = storageLocation
        self.notes = notes
        self.createdAt = .now
        self.modifiedAt = .now
        self.uuid = UUID()
    }

    /// Checks newest-first.
    var unwrappedChecks: [CheckRecord] {
        (checks ?? []).sorted { $0.date > $1.date }
    }

    var lastCheck: CheckRecord? { unwrappedChecks.first }

    var hasPhoto: Bool { photo != nil }

    var hasLocation: Bool {
        guard let storageLocation else { return false }
        return !storageLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasNotes: Bool {
        guard let notes else { return false }
        return !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Strongly-typed interval unit (falls back to months on any bad raw value).
    var intervalUnitValue: IntervalUnit {
        IntervalUnit(rawValue: intervalUnit) ?? .months
    }

    /// True when no interval is set — the item never expires / is never flagged.
    var neverExpires: Bool { intervalValue == nil }

    /// The context this item lives in (reached through its category).
    var context: SupplyContext? { category?.context }
}
