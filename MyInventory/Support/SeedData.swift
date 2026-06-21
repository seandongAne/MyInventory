//
//  SeedData.swift
//  MyInventory
//
//  Seeds the three fixed top-level contexts on first launch (Dev Plan §M0).
//

import Foundation
import SwiftData
import SwiftUI

enum SeedData {

    /// The fixed v1 contexts, in display order.
    static let defaultContextNames = ["Vehicle", "Bag", "House"]

    /// Inserts the default contexts only if none exist yet (idempotent).
    /// Throws so the caller can surface a setup failure and offer a retry,
    /// instead of silently leaving the app with no contexts (P2-c).
    @MainActor
    static func seedDefaultContextsIfNeeded(in context: ModelContext) throws {
        let existingCount = try context.fetchCount(FetchDescriptor<SupplyContext>())
        guard existingCount == 0 else { return }

        for (index, name) in defaultContextNames.enumerated() {
            context.insert(SupplyContext(name: name, sortOrder: index))
        }
        try context.save()
    }

    /// Deterministic sample data for UI tests (guarded by the `-uiTesting` launch
    /// argument). Adds one item to two different contexts so the cross-context
    /// global search can be exercised end-to-end. Idempotent.
    @MainActor
    static func seedUITestSampleIfNeeded(in context: ModelContext) throws {
        guard try context.fetchCount(FetchDescriptor<SupplyItem>()) == 0 else { return }
        let contexts = try context.fetch(FetchDescriptor<SupplyContext>())
        func named(_ name: String) -> SupplyContext? { contexts.first { $0.name == name } }

        if let vehicle = named("Vehicle") {
            let cat = SupplyCategory(name: "Emergency Kit", sortOrder: 0)
            cat.context = vehicle
            context.insert(cat)
            let item = SupplyItem(name: "First Aid Kit", checkIntervalMonths: 6)
            item.category = cat
            context.insert(item)
        }
        if let house = named("House") {
            let cat = SupplyCategory(name: "Pantry", sortOrder: 0)
            cat.context = house
            context.insert(cat)
            let item = SupplyItem(name: "Canned Tuna", checkIntervalMonths: 12)
            item.category = cat
            context.insert(item)
        }
        try context.save()
    }

    /// Verification-only sample (gated behind `-seedBatch`, only ever combined with
    /// the in-memory `-uiTesting` store): several items in one category, same
    /// interval, all checked TODAY — so their next-due dates land on the SAME
    /// calendar day and the planner must BATCH them into one reminder. Lets the
    /// notification UI test drive the authorized batched-reschedule path.
    static func seedBatchSampleIfNeeded(in context: ModelContext) throws {
        let marker = "Verify Batch"
        let contexts = try context.fetch(FetchDescriptor<SupplyContext>())
        guard !contexts.contains(where: { $0.name == marker }) else { return }

        let ctx = SupplyContext(name: marker, sortOrder: 99)
        context.insert(ctx)
        let cat = SupplyCategory(name: "Batch Kit", sortOrder: 0)
        cat.context = ctx
        context.insert(cat)
        for i in 1...3 {
            let item = SupplyItem(name: "Batch Item \(i)", checkIntervalMonths: 6)
            item.category = cat
            context.insert(item)
            let check = CheckRecord(date: .now, result: .ok)
            check.item = item
            context.insert(check)
        }
        try context.save()
    }

    // Context icons live in Iconography.contextIconName(forContextNamed:) —
    // custom template assets, single source of truth for identity icons.

    /// Brand color per context — used for sidebar icons and other accents.
    static func color(forContextNamed name: String) -> Color {
        switch name {
        case "Vehicle": return .orange
        case "Bag": return .indigo
        case "House": return .teal
        default: return .purple
        }
    }
}
