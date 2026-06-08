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
    @MainActor
    static func seedDefaultContextsIfNeeded(in context: ModelContext) {
        let descriptor = FetchDescriptor<SupplyContext>()
        let existingCount = (try? context.fetchCount(descriptor)) ?? 0
        guard existingCount == 0 else { return }

        for (index, name) in defaultContextNames.enumerated() {
            context.insert(SupplyContext(name: name, sortOrder: index))
        }
        try? context.save()
    }

    /// SF Symbol for a context, matched by name (Dev Plan §6.3). Falls back to a
    /// generic symbol for any future user-created context.
    static func symbol(forContextNamed name: String) -> String {
        switch name {
        case "Vehicle": return "car.fill"
        case "Bag": return "backpack.fill"
        case "House": return "house.fill"
        default: return "shippingbox.fill"
        }
    }

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
