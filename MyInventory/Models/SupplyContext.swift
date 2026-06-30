//
//  SupplyContext.swift
//  MyInventory
//
//  Top-level grouping ("Vehicle" | "Bag" | "House"). Modeled as DATA (not a
//  hardcoded enum) per PRD P2-2 insurance — cheap now, avoids a migration later.
//
//  CloudKit-safe rules baked in (Dev Plan §2):
//   • No @Attribute(.unique)
//   • Every stored property is optional OR has a default value
//   • Every relationship is optional and has an explicit inverse
//   • No .deny delete rules
//

import Foundation
import SwiftData

@Model
final class SupplyContext {
    var name: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    // Last-modified timestamp for cross-platform last-write-wins sync (Phase 2).
    var modifiedAt: Date = Date.now

    // Phase-2 soft-delete tombstone (nil = live). See CheckRecord.deletedAt.
    var deletedAt: Date? = nil

    // Stable, non-DB-enforced identifier (CloudKit forbids .unique).
    var uuid: UUID = UUID()

    // Deleting a context removes its categories (which in turn nullify their items).
    @Relationship(deleteRule: .cascade, inverse: \SupplyCategory.context)
    var categories: [SupplyCategory]? = []

    init(name: String = "", sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.uuid = UUID()
    }

    /// Live categories (tombstones excluded), sorted by display order.
    var unwrappedCategories: [SupplyCategory] {
        (categories ?? []).filter { $0.deletedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// All live items reachable through this context's categories.
    var allItems: [SupplyItem] {
        unwrappedCategories.flatMap { $0.unwrappedItems }
    }

    /// Bump the sync timestamp after a local edit (LWW ordering, Phase 2).
    func touch(now: Date = .now) { modifiedAt = now }

    /// Soft-delete this context and cascade tombstones to every category, item,
    /// and check beneath it (Phase-2). Replaces the old hard-delete-items-first
    /// dance — nothing is removed from the store, so the whole subtree's deletion
    /// propagates on merge.
    func markDeleted(now: Date = .now) {
        for category in categories ?? [] {
            for item in category.items ?? [] { item.markDeleted(now: now) }
            category.markDeleted(now: now)
        }
        deletedAt = now
        modifiedAt = now
    }
}
