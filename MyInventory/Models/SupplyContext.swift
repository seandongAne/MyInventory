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

    /// Categories sorted by their display order.
    var unwrappedCategories: [SupplyCategory] {
        (categories ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// All items reachable through this context's categories.
    var allItems: [SupplyItem] {
        unwrappedCategories.flatMap { $0.unwrappedItems }
    }
}
