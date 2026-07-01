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

    // Phase-2 soft-delete tombstone (nil = live). Hidden from all queries/UI via
    // the `deletedAt == nil` predicates + `unwrappedChecks`/`unwrapped…` accessors,
    // but retained + exported so the deletion propagates on merge.
    var deletedAt: Date? = nil

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

    /// Live checks (tombstones excluded), newest-first. All status/UI go through
    /// this — a soft-deleted check stops counting toward the next due date.
    var unwrappedChecks: [CheckRecord] {
        (checks ?? []).filter { $0.deletedAt == nil }.sorted { $0.date > $1.date }
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

    /// True when a category or context ANCESTOR is tombstoned while this item is not.
    /// A cross-platform merge can leave such an orphan — one peer soft-deleted the
    /// parent while another added/edited the item, and the strict per-uuid LWW merge
    /// keeps the live child under the dead parent. It must never surface in any
    /// cross-context surface (attention dashboard, app-wide search, badge counts);
    /// per-context views are already unreachable because their parent is filtered out.
    var hasTombstonedAncestor: Bool {
        if let category, category.deletedAt != nil { return true }
        if let context = category?.context, context.deletedAt != nil { return true }
        return false
    }

    /// Bump the sync timestamp after a local edit so the change wins
    /// last-write-wins on the next merge (Phase 2).
    func touch(now: Date = .now) { modifiedAt = now }

    /// Reparent to a new category, bumping `modifiedAt` so the move wins LWW on the
    /// next cross-device merge. A bare `category =` assignment silently loses the
    /// merge race (the incoming move only applies when its `modifiedAt` is strictly
    /// newer) — every move MUST go through here. The sibling delete-category flow
    /// (`CategoryManagerView.confirmDelete`) touches each moved item for the same reason.
    func move(to newCategory: SupplyCategory, now: Date = .now) {
        category = newCategory
        touch(now: now)
    }

    /// Soft-delete this item and cascade to its checks (Phase-2 tombstone).
    func markDeleted(now: Date = .now) {
        for check in checks ?? [] { check.markDeleted(now: now) }
        deletedAt = now
        modifiedAt = now
    }
}
