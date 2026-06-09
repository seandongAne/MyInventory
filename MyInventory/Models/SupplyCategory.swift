//
//  SupplyCategory.swift
//  MyInventory
//
//  A user-created category within a context (e.g. "Survival Essentials").
//

import Foundation
import SwiftData

@Model
final class SupplyCategory {
    var name: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date.now
    var uuid: UUID = UUID()

    // Inverse of SupplyContext.categories.
    var context: SupplyContext?

    // .nullify (NOT .deny / .cascade): deleting a category must never silently
    // destroy items. App logic moves items to an "Uncategorized" category in the
    // same context before deleting (PRD Q3 / Dev Plan §M1).
    @Relationship(deleteRule: .nullify, inverse: \SupplyItem.category)
    var items: [SupplyItem]? = []

    init(name: String = "", sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.uuid = UUID()
    }

    var unwrappedItems: [SupplyItem] { items ?? [] }

    /// Name reserved for the orphaned-items fallback bucket.
    static let uncategorizedName = "Uncategorized"

    var isUncategorized: Bool { name == SupplyCategory.uncategorizedName }

    /// Finds the context's Uncategorized bucket, creating (and inserting) it if
    /// needed. The insert participates in the caller's save/rollback. Used both
    /// by the delete-category flow and by saving an item without a category.
    @MainActor
    static func uncategorizedBucket(in context: SupplyContext,
                                    modelContext: ModelContext) -> SupplyCategory {
        if let existing = context.unwrappedCategories.first(where: { $0.isUncategorized }) {
            return existing
        }
        let nextOrder = (context.unwrappedCategories.map(\.sortOrder).max() ?? -1) + 1
        let bucket = SupplyCategory(name: uncategorizedName, sortOrder: nextOrder)
        bucket.context = context
        modelContext.insert(bucket)
        return bucket
    }
}
