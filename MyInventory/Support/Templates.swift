//
//  Templates.swift
//  MyInventory
//
//  Starter checklists ("Car Emergency Kit", "Home Emergency", …) so a new or
//  empty context can be populated in one tap instead of typing 15 items by hand.
//  Applying a template is idempotent-ish: existing categories are reused by name
//  and items that already exist (same name, same category) are skipped.
//

import Foundation
import SwiftData

struct SupplyTemplate: Identifiable {
    struct Category {
        let name: String
        let items: [Item]
    }
    struct Item {
        let name: String
        let intervalMonths: Int?
        var quantity: Int? = nil
    }

    let name: String
    let symbol: String
    let summary: String
    let categories: [Category]

    var id: String { name }
    var itemCount: Int { categories.reduce(0) { $0 + $1.items.count } }
}

enum Templates {

    static let all: [SupplyTemplate] = [vehicleKit, homeEmergency, goBag, camping]

    /// Creates the template's categories and items inside `context` and saves.
    /// Categories are matched by (case-insensitive) name and reused; items already
    /// present in a matching category are skipped. Returns how many items were added.
    @MainActor
    @discardableResult
    static func apply(_ template: SupplyTemplate,
                      to context: SupplyContext,
                      in modelContext: ModelContext) throws -> Int {
        var added = 0
        var nextOrder = (context.unwrappedCategories.map(\.sortOrder).max() ?? -1) + 1

        for templateCategory in template.categories {
            let category: SupplyCategory
            if let existing = context.unwrappedCategories.first(where: {
                $0.name.compare(templateCategory.name, options: .caseInsensitive) == .orderedSame
            }) {
                category = existing
            } else {
                category = SupplyCategory(name: templateCategory.name, sortOrder: nextOrder)
                nextOrder += 1
                category.context = context
                modelContext.insert(category)
            }

            let existingNames = Set(category.unwrappedItems.map { $0.name.lowercased() })
            for templateItem in templateCategory.items {
                guard !existingNames.contains(templateItem.name.lowercased()) else { continue }
                let item = SupplyItem(name: templateItem.name,
                                      checkIntervalMonths: templateItem.intervalMonths)
                item.quantity = templateItem.quantity
                item.category = category
                modelContext.insert(item)
                added += 1
            }
        }

        try modelContext.save()
        return added
    }

    // MARK: - Template definitions

    static let vehicleKit = SupplyTemplate(
        name: "Car Emergency Kit",
        symbol: "car.fill",
        summary: "Roadside and breakdown essentials kept in the trunk.",
        categories: [
            .init(name: "Emergency Kit", items: [
                .init(name: "First Aid Kit", intervalMonths: 6),
                .init(name: "Flashlight", intervalMonths: 6),
                .init(name: "Emergency Blanket", intervalMonths: 12),
                .init(name: "Water Bottles", intervalMonths: 6, quantity: 4),
                .init(name: "Energy Bars", intervalMonths: 6, quantity: 6),
                .init(name: "Reflective Warning Triangle", intervalMonths: nil)
            ]),
            .init(name: "Tools", items: [
                .init(name: "Jumper Cables", intervalMonths: nil),
                .init(name: "Tire Inflator / Sealant", intervalMonths: 12),
                .init(name: "Multi-tool", intervalMonths: nil),
                .init(name: "Work Gloves", intervalMonths: nil),
                .init(name: "Phone Charging Cable", intervalMonths: 12)
            ])
        ]
    )

    static let homeEmergency = SupplyTemplate(
        name: "Home Emergency",
        symbol: "house.fill",
        summary: "Shelter-in-place supplies for power cuts and storms.",
        categories: [
            .init(name: "Water & Food", items: [
                .init(name: "Water Storage", intervalMonths: 6, quantity: 12),
                .init(name: "Canned Food", intervalMonths: 12, quantity: 12),
                .init(name: "Manual Can Opener", intervalMonths: nil)
            ]),
            .init(name: "Power & Light", items: [
                .init(name: "Flashlights", intervalMonths: 6, quantity: 2),
                .init(name: "Spare Batteries", intervalMonths: 12, quantity: 8),
                .init(name: "Power Bank", intervalMonths: 3),
                .init(name: "Candles & Matches", intervalMonths: 12)
            ]),
            .init(name: "Safety", items: [
                .init(name: "First Aid Kit", intervalMonths: 6),
                .init(name: "Fire Extinguisher", intervalMonths: 12),
                .init(name: "Battery Radio", intervalMonths: 12),
                .init(name: "Spare Medications", intervalMonths: 3)
            ])
        ]
    )

    static let goBag = SupplyTemplate(
        name: "72-Hour Go Bag",
        symbol: "backpack.fill",
        summary: "Grab-and-go bag covering three days away from home.",
        categories: [
            .init(name: "Essentials", items: [
                .init(name: "Water Pouches", intervalMonths: 6, quantity: 6),
                .init(name: "Energy Bars", intervalMonths: 6, quantity: 9),
                .init(name: "First Aid Kit", intervalMonths: 6),
                .init(name: "Emergency Cash", intervalMonths: 12),
                .init(name: "Copies of Documents", intervalMonths: 12)
            ]),
            .init(name: "Gear", items: [
                .init(name: "Headlamp", intervalMonths: 6),
                .init(name: "Multi-tool", intervalMonths: nil),
                .init(name: "Whistle", intervalMonths: nil),
                .init(name: "Change of Clothes", intervalMonths: 12),
                .init(name: "Hygiene Kit", intervalMonths: 12),
                .init(name: "Emergency Blanket", intervalMonths: 12)
            ])
        ]
    )

    static let camping = SupplyTemplate(
        name: "Camping Box",
        symbol: "tent.fill",
        summary: "Shared camping gear checked before each season.",
        categories: [
            .init(name: "Shelter & Sleep", items: [
                .init(name: "Tent", intervalMonths: 12),
                .init(name: "Sleeping Bags", intervalMonths: 12, quantity: 2),
                .init(name: "Sleeping Pads", intervalMonths: 12, quantity: 2)
            ]),
            .init(name: "Cooking", items: [
                .init(name: "Camp Stove", intervalMonths: 6),
                .init(name: "Fuel Canisters", intervalMonths: 6, quantity: 2),
                .init(name: "Lighter & Matches", intervalMonths: 6),
                .init(name: "Water Filter", intervalMonths: 12)
            ]),
            .init(name: "Safety & Light", items: [
                .init(name: "Headlamps", intervalMonths: 6, quantity: 2),
                .init(name: "First Aid Kit", intervalMonths: 6),
                .init(name: "Insect Repellent", intervalMonths: 12),
                .init(name: "Sunscreen", intervalMonths: 12)
            ])
        ]
    )
}
