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

    // Re-check cadence in months. nil => "never expires": never flagged, never notified.
    var checkIntervalMonths: Int? = nil

    // Optional advance-warning override in days. nil => use the global default.
    var leadTimeDaysOverride: Int? = nil

    var storageLocation: String? = nil

    // Single optional photo (v1). External storage keeps the DB light.
    @Attribute(.externalStorage) var photo: Data? = nil

    var createdAt: Date = Date.now

    // Stable identifier used for notification request IDs (CloudKit forbids .unique).
    var uuid: UUID = UUID()

    // Inverse of SupplyCategory.items.
    var category: SupplyCategory?

    @Relationship(deleteRule: .cascade, inverse: \CheckRecord.item)
    var checks: [CheckRecord]? = []

    init(name: String = "",
         checkIntervalMonths: Int? = nil,
         storageLocation: String? = nil) {
        self.name = name
        self.checkIntervalMonths = checkIntervalMonths
        self.storageLocation = storageLocation
        self.createdAt = .now
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

    /// The context this item lives in (reached through its category).
    var context: SupplyContext? { category?.context }
}
