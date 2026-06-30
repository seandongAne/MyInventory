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
        var schemaVersion = 2
        let exportedAt: Date
        let contexts: [ContextDTO]
    }

    // uuid fields are Strings (not UUID) so they serialize as LOWERCASE per the
    // canonical wire format — Foundation's UUID encodes uppercase, and Android
    // emits lowercase; both sides compare case-insensitively. See
    // docs/SCBK1_Format.md §5.
    struct ContextDTO: Codable {
        let uuid: String
        let name: String
        let sortOrder: Int
        let createdAt: Date
        let modifiedAt: Date?
        // Phase-2 soft-delete tombstone (omitted when nil = live). See SCBK1_Format §5.
        let deletedAt: Date?
        let categories: [CategoryDTO]
    }

    struct CategoryDTO: Codable {
        let uuid: String
        let name: String
        let sortOrder: Int
        let createdAt: Date
        let modifiedAt: Date?
        let deletedAt: Date?
        let items: [ItemDTO]
    }

    struct ItemDTO: Codable {
        let uuid: String
        let name: String
        let intervalValue: Int?
        let intervalUnit: String?
        let leadTimeDaysOverride: Int?
        let quantity: Int?
        let storageLocation: String?
        let notes: String?
        let createdAt: Date
        let modifiedAt: Date?
        let deletedAt: Date?
        let checks: [CheckDTO]

        // Legacy schemaVersion-1 field (months only). Decode-only: the importer
        // falls back to it when intervalValue/intervalUnit are absent.
        let checkIntervalMonths: Int?
    }

    struct CheckDTO: Codable {
        let uuid: String
        let date: String   // calendar date "YYYY-MM-DD" (not an instant)
        let result: String // canonical lowercase: ok | replaced | needsAttention
        let comment: String?
        // Phase-2 tombstone. Checks are append-only, so a delete is the only edit
        // that propagates — monotonic (once set on either side, it stays).
        let deletedAt: Date?
    }

    /// Encodes everything reachable from the store into pretty-printed JSON.
    @MainActor
    static func makeExport(from modelContext: ModelContext, now: Date = .now) throws -> Data {
        let contexts = try modelContext.fetch(
            FetchDescriptor<SupplyContext>(sortBy: [SortDescriptor(\.sortOrder)])
        )
        // Export walks the RAW relationships (not the `unwrapped…` accessors, which
        // now hide tombstones) so soft-deleted rows are carried in the backup and
        // their deletion propagates on merge instead of being silently re-added.
        let export = Export(
            exportedAt: now,
            contexts: contexts.map { context in
                ContextDTO(
                    uuid: context.uuid.uuidString.lowercased(),
                    name: context.name,
                    sortOrder: context.sortOrder,
                    createdAt: context.createdAt,
                    modifiedAt: context.modifiedAt,
                    deletedAt: context.deletedAt,
                    categories: (context.categories ?? [])
                        .sorted { $0.sortOrder < $1.sortOrder }
                        .map { category in
                        CategoryDTO(
                            uuid: category.uuid.uuidString.lowercased(),
                            name: category.name,
                            sortOrder: category.sortOrder,
                            createdAt: category.createdAt,
                            modifiedAt: category.modifiedAt,
                            deletedAt: category.deletedAt,
                            items: (category.items ?? [])
                                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                                .map { item in
                                    ItemDTO(
                                        uuid: item.uuid.uuidString.lowercased(),
                                        name: item.name,
                                        intervalValue: item.intervalValue,
                                        intervalUnit: item.intervalUnit,
                                        leadTimeDaysOverride: item.leadTimeDaysOverride,
                                        quantity: item.quantity,
                                        storageLocation: item.storageLocation,
                                        notes: item.notes,
                                        createdAt: item.createdAt,
                                        modifiedAt: item.modifiedAt,
                                        deletedAt: item.deletedAt,
                                        checks: (item.checks ?? [])
                                            .sorted { $0.date > $1.date }
                                            .map { check in
                                            CheckDTO(uuid: check.uuid.uuidString.lowercased(),
                                                     date: Self.wireDate(check.date),
                                                     result: check.result.wireValue,
                                                     comment: check.comment,
                                                     deletedAt: check.deletedAt)
                                        },
                                        checkIntervalMonths: nil
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

    // MARK: Wire date format (calendar YYYY-MM-DD, UTC) — shared with DataImporter

    /// A check's calendar date in the canonical wire form `YYYY-MM-DD` (UTC).
    static func wireDate(_ date: Date) -> String {
        calendarDateFormatter.string(from: date)
    }

    /// Parse a wire check date: the canonical `YYYY-MM-DD`, or (back-compat) a
    /// full ISO-8601 instant from pre-S2 `.json` backups. nil if neither parses.
    static func parseWireDate(_ string: String) -> Date? {
        if let date = calendarDateFormatter.date(from: string) { return date }
        return iso8601Formatter.date(from: string)
    }

    private static let calendarDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let iso8601Formatter = ISO8601DateFormatter()

    static func defaultFilename(now: Date = .now) -> String {
        let day = now.formatted(.iso8601.year().month().day())
        return "MyInventory-\(day)"
    }
}
