//
//  DataExporter.swift
//  MyInventory
//
//  JSON export of the full Context → Category → Item → CheckRecord hierarchy.
//  The data is local-only until CloudKit lands (M6), so losing the device means
//  losing everything — this gives the user a backup/escape hatch today.
//  Photos are deliberately excluded (they would bloat the JSON by orders of
//  magnitude); the file is for restoring the *inventory*, not the gallery.
//

import Foundation
import SwiftData

enum DataExporter {

    struct Export: Codable {
        var schemaVersion = 1
        let exportedAt: Date
        let contexts: [ContextDTO]
    }

    struct ContextDTO: Codable {
        let uuid: UUID
        let name: String
        let sortOrder: Int
        let createdAt: Date
        let categories: [CategoryDTO]
    }

    struct CategoryDTO: Codable {
        let uuid: UUID
        let name: String
        let sortOrder: Int
        let createdAt: Date
        let items: [ItemDTO]
    }

    struct ItemDTO: Codable {
        let uuid: UUID
        let name: String
        let checkIntervalMonths: Int?
        let leadTimeDaysOverride: Int?
        let quantity: Int?
        let storageLocation: String?
        let createdAt: Date
        let checks: [CheckDTO]
    }

    struct CheckDTO: Codable {
        let uuid: UUID
        let date: Date
        let result: String
        let comment: String?
    }

    /// Encodes everything reachable from the store into pretty-printed JSON.
    @MainActor
    static func makeExport(from modelContext: ModelContext, now: Date = .now) throws -> Data {
        let contexts = try modelContext.fetch(
            FetchDescriptor<SupplyContext>(sortBy: [SortDescriptor(\.sortOrder)])
        )
        let export = Export(
            exportedAt: now,
            contexts: contexts.map { context in
                ContextDTO(
                    uuid: context.uuid,
                    name: context.name,
                    sortOrder: context.sortOrder,
                    createdAt: context.createdAt,
                    categories: context.unwrappedCategories.map { category in
                        CategoryDTO(
                            uuid: category.uuid,
                            name: category.name,
                            sortOrder: category.sortOrder,
                            createdAt: category.createdAt,
                            items: category.unwrappedItems
                                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                                .map { item in
                                    ItemDTO(
                                        uuid: item.uuid,
                                        name: item.name,
                                        checkIntervalMonths: item.checkIntervalMonths,
                                        leadTimeDaysOverride: item.leadTimeDaysOverride,
                                        quantity: item.quantity,
                                        storageLocation: item.storageLocation,
                                        createdAt: item.createdAt,
                                        checks: item.unwrappedChecks.map { check in
                                            CheckDTO(uuid: check.uuid,
                                                     date: check.date,
                                                     result: check.resultRaw,
                                                     comment: check.comment)
                                        }
                                    )
                                }
                        )
                    }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    static func defaultFilename(now: Date = .now) -> String {
        let day = now.formatted(.iso8601.year().month().day())
        return "MyInventory-\(day)"
    }
}
