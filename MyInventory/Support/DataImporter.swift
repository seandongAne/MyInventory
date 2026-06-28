//
//  DataImporter.swift
//  MyInventory
//
//  Restores a JSON backup produced by `DataExporter` back into the store — the
//  missing other half of the "backup" promise until CloudKit sync lands (M6).
//
//  The merge is keyed on each entity's stable `uuid`, which makes it both
//  IDEMPOTENT (re-importing the same file is a no-op) and NON-DESTRUCTIVE
//  (it only ever ADDS what's missing — it never overwrites a field or deletes
//  anything already in the store). So:
//    • restore onto a fresh re-install (empty store) → the full inventory comes
//      back, check history included;
//    • restore onto a device that still has the data → nothing changes;
//    • merge a backup from another device → everything imports (uuids are unique).
//  Photos are not in the export, so they are not restored.
//

import Foundation
import SwiftData

enum DataImporter {

    /// What a merge added, for a user-facing summary.
    struct Summary: Equatable {
        var contextsAdded = 0
        var categoriesAdded = 0
        var itemsAdded = 0
        var checksAdded = 0

        var isEmpty: Bool {
            contextsAdded == 0 && categoriesAdded == 0 && itemsAdded == 0 && checksAdded == 0
        }
    }

    enum ImportError: LocalizedError {
        case malformed

        var errorDescription: String? {
            switch self {
            case .malformed:
                return "This file isn’t a MyInventory backup, or it’s damaged."
            }
        }
    }

    /// Parses backup JSON into the shared `DataExporter.Export` shape, mapping any
    /// decode failure to a friendly error (the picked file may be the wrong one).
    static func decode(_ data: Data) throws -> DataExporter.Export {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(DataExporter.Export.self, from: data)
        } catch {
            throw ImportError.malformed
        }
    }

    /// Merges the backup into the store, matching existing rows by `uuid`. Saves
    /// once at the end (rollback + rethrow on failure, per the store invariant).
    @MainActor
    @discardableResult
    static func merge(_ export: DataExporter.Export, into modelContext: ModelContext) throws -> Summary {
        var summary = Summary()

        // Index everything already present once, so matching is O(1) and we never
        // re-insert an entity we already hold.
        var contextByUUID = Dictionary(
            try modelContext.fetch(FetchDescriptor<SupplyContext>()).map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first })
        var categoryByUUID = Dictionary(
            try modelContext.fetch(FetchDescriptor<SupplyCategory>()).map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first })
        var itemByUUID = Dictionary(
            try modelContext.fetch(FetchDescriptor<SupplyItem>()).map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first })
        var checkUUIDs = Set(try modelContext.fetch(FetchDescriptor<CheckRecord>()).map(\.uuid))

        for contextDTO in export.contexts {
            // Wire uuids are strings (lowercase); `UUID` matching is value-based,
            // so case differences across platforms collapse here. A malformed id
            // gets a fresh UUID so it imports as new rather than aborting.
            let contextUUID = UUID(uuidString: contextDTO.uuid) ?? UUID()
            let context = contextByUUID[contextUUID] ?? {
                let new = SupplyContext(name: contextDTO.name, sortOrder: contextDTO.sortOrder)
                new.uuid = contextUUID
                new.createdAt = contextDTO.createdAt
                new.modifiedAt = contextDTO.modifiedAt ?? contextDTO.createdAt
                modelContext.insert(new)
                contextByUUID[contextUUID] = new
                summary.contextsAdded += 1
                return new
            }()

            for categoryDTO in contextDTO.categories {
                let categoryUUID = UUID(uuidString: categoryDTO.uuid) ?? UUID()
                let category = categoryByUUID[categoryUUID] ?? {
                    let new = SupplyCategory(name: categoryDTO.name, sortOrder: categoryDTO.sortOrder)
                    new.uuid = categoryUUID
                    new.createdAt = categoryDTO.createdAt
                    new.modifiedAt = categoryDTO.modifiedAt ?? categoryDTO.createdAt
                    new.context = context
                    modelContext.insert(new)
                    categoryByUUID[categoryUUID] = new
                    summary.categoriesAdded += 1
                    return new
                }()

                for itemDTO in categoryDTO.items {
                    let itemUUID = UUID(uuidString: itemDTO.uuid) ?? UUID()
                    let item = itemByUUID[itemUUID] ?? {
                        let new = SupplyItem(name: itemDTO.name,
                                             storageLocation: itemDTO.storageLocation,
                                             notes: itemDTO.notes)
                        new.uuid = itemUUID
                        new.createdAt = itemDTO.createdAt
                        new.modifiedAt = itemDTO.modifiedAt ?? itemDTO.createdAt
                        // Prefer the v2 value+unit; fall back to the legacy months field.
                        new.intervalValue = itemDTO.intervalValue ?? itemDTO.checkIntervalMonths
                        new.intervalUnit = itemDTO.intervalUnit ?? IntervalUnit.months.rawValue
                        new.leadTimeDaysOverride = itemDTO.leadTimeDaysOverride
                        new.quantity = itemDTO.quantity
                        new.category = category
                        modelContext.insert(new)
                        itemByUUID[itemUUID] = new
                        summary.itemsAdded += 1
                        return new
                    }()

                    // Add only checks we don't already have — so a backup with
                    // newer history fills in the gaps without duplicating. Skip a
                    // check with a malformed id or an unparseable date rather than
                    // corrupting history.
                    for checkDTO in itemDTO.checks {
                        guard let checkUUID = UUID(uuidString: checkDTO.uuid),
                              !checkUUIDs.contains(checkUUID),
                              let checkDate = DataExporter.parseWireDate(checkDTO.date)
                        else { continue }
                        let check = CheckRecord(date: checkDate,
                                                result: CheckResult(wireValue: checkDTO.result),
                                                comment: checkDTO.comment)
                        check.uuid = checkUUID
                        check.item = item
                        modelContext.insert(check)
                        checkUUIDs.insert(checkUUID)
                        summary.checksAdded += 1
                    }
                }
            }
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        return summary
    }
}
