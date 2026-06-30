//
//  DataImporter.swift
//  MyInventory
//
//  Restores a JSON backup produced by `DataExporter` back into the store — the
//  missing other half of the "backup" promise until CloudKit sync lands (M6).
//
//  The merge is keyed on each entity's stable `uuid`. It is IDEMPOTENT (re-importing
//  the same file is a no-op) and uses Phase-2 last-write-wins semantics:
//    • a uuid not present locally → inserted (including a tombstone, so deletions
//      from a peer propagate rather than reappearing);
//    • a uuid already present → the side with the newer `modifiedAt` wins. A newer
//      incoming edit overwrites the local fields; a newer incoming tombstone
//      (`deletedAt`) soft-deletes the local row; an older incoming version is
//      ignored (local stays). Equal timestamps keep local (so re-import = no-op).
//    • checks are append-only: union by uuid, with a monotonic tombstone (once a
//      check is deleted on either side it stays deleted).
//  So a fresh re-install restores everything; merging another device's backup
//  converges both ways including edits and deletes. NOTE: unlike the old additive
//  importer, a NEWER backup CAN now overwrite or remove local rows (that is the
//  point of sync); an OLDER backup never clobbers newer local data. Photos are not
//  in the export, so they are not restored.
//

import Foundation
import SwiftData

enum DataImporter {

    /// What a merge changed, for a user-facing summary.
    struct Summary: Equatable {
        var contextsAdded = 0
        var categoriesAdded = 0
        var itemsAdded = 0
        var checksAdded = 0
        // Existing rows overwritten by a newer incoming version (LWW), and existing
        // live rows tombstoned by a newer incoming delete.
        var updated = 0
        var removed = 0

        var isEmpty: Bool {
            contextsAdded == 0 && categoriesAdded == 0 && itemsAdded == 0
                && checksAdded == 0 && updated == 0 && removed == 0
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
        var checkByUUID = Dictionary(
            try modelContext.fetch(FetchDescriptor<CheckRecord>()).map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first })

        for contextDTO in export.contexts {
            // Wire uuids are strings (lowercase); `UUID` matching is value-based,
            // so case differences across platforms collapse here. A malformed id
            // gets a fresh UUID so it imports as new rather than aborting.
            let contextUUID = UUID(uuidString: contextDTO.uuid) ?? UUID()
            let incomingModified = contextDTO.modifiedAt ?? contextDTO.createdAt
            let context: SupplyContext
            if let existing = contextByUUID[contextUUID] {
                context = existing
                if incomingModified > existing.modifiedAt {
                    let wasLive = existing.deletedAt == nil
                    existing.name = contextDTO.name
                    existing.sortOrder = contextDTO.sortOrder
                    existing.deletedAt = contextDTO.deletedAt
                    existing.modifiedAt = incomingModified
                    if contextDTO.deletedAt != nil && wasLive { summary.removed += 1 }
                    else { summary.updated += 1 }
                }
            } else {
                let new = SupplyContext(name: contextDTO.name, sortOrder: contextDTO.sortOrder)
                new.uuid = contextUUID
                new.createdAt = contextDTO.createdAt
                new.modifiedAt = incomingModified
                new.deletedAt = contextDTO.deletedAt
                modelContext.insert(new)
                contextByUUID[contextUUID] = new
                summary.contextsAdded += 1
                context = new
            }

            for categoryDTO in contextDTO.categories {
                let categoryUUID = UUID(uuidString: categoryDTO.uuid) ?? UUID()
                let incomingCatModified = categoryDTO.modifiedAt ?? categoryDTO.createdAt
                let category: SupplyCategory
                if let existing = categoryByUUID[categoryUUID] {
                    category = existing
                    if incomingCatModified > existing.modifiedAt {
                        let wasLive = existing.deletedAt == nil
                        existing.name = categoryDTO.name
                        existing.sortOrder = categoryDTO.sortOrder
                        existing.context = context
                        existing.deletedAt = categoryDTO.deletedAt
                        existing.modifiedAt = incomingCatModified
                        if categoryDTO.deletedAt != nil && wasLive { summary.removed += 1 }
                        else { summary.updated += 1 }
                    }
                } else {
                    let new = SupplyCategory(name: categoryDTO.name, sortOrder: categoryDTO.sortOrder)
                    new.uuid = categoryUUID
                    new.createdAt = categoryDTO.createdAt
                    new.modifiedAt = incomingCatModified
                    new.deletedAt = categoryDTO.deletedAt
                    new.context = context
                    modelContext.insert(new)
                    categoryByUUID[categoryUUID] = new
                    summary.categoriesAdded += 1
                    category = new
                }

                for itemDTO in categoryDTO.items {
                    let itemUUID = UUID(uuidString: itemDTO.uuid) ?? UUID()
                    let incomingItemModified = itemDTO.modifiedAt ?? itemDTO.createdAt
                    let item: SupplyItem
                    if let existing = itemByUUID[itemUUID] {
                        item = existing
                        if incomingItemModified > existing.modifiedAt {
                            let wasLive = existing.deletedAt == nil
                            existing.name = itemDTO.name
                            existing.intervalValue = itemDTO.intervalValue ?? itemDTO.checkIntervalMonths
                            existing.intervalUnit = itemDTO.intervalUnit ?? IntervalUnit.months.rawValue
                            existing.leadTimeDaysOverride = itemDTO.leadTimeDaysOverride
                            existing.quantity = itemDTO.quantity
                            existing.storageLocation = itemDTO.storageLocation
                            existing.notes = itemDTO.notes
                            existing.category = category
                            existing.deletedAt = itemDTO.deletedAt
                            existing.modifiedAt = incomingItemModified
                            if itemDTO.deletedAt != nil && wasLive { summary.removed += 1 }
                            else { summary.updated += 1 }
                        }
                    } else {
                        let new = SupplyItem(name: itemDTO.name,
                                             storageLocation: itemDTO.storageLocation,
                                             notes: itemDTO.notes)
                        new.uuid = itemUUID
                        new.createdAt = itemDTO.createdAt
                        new.modifiedAt = incomingItemModified
                        new.deletedAt = itemDTO.deletedAt
                        // Prefer the v2 value+unit; fall back to the legacy months field.
                        new.intervalValue = itemDTO.intervalValue ?? itemDTO.checkIntervalMonths
                        new.intervalUnit = itemDTO.intervalUnit ?? IntervalUnit.months.rawValue
                        new.leadTimeDaysOverride = itemDTO.leadTimeDaysOverride
                        new.quantity = itemDTO.quantity
                        new.category = category
                        modelContext.insert(new)
                        itemByUUID[itemUUID] = new
                        summary.itemsAdded += 1
                        item = new
                    }

                    // Checks are append-only: insert new ones; for an existing check
                    // honor a tombstone monotonically (once deleted on either side it
                    // stays deleted). Skip a check with a malformed id or unparseable
                    // date rather than corrupting history.
                    for checkDTO in itemDTO.checks {
                        guard let checkUUID = UUID(uuidString: checkDTO.uuid),
                              let checkDate = DataExporter.parseWireDate(checkDTO.date)
                        else { continue }
                        if let existing = checkByUUID[checkUUID] {
                            if existing.deletedAt == nil, let incomingDeletedAt = checkDTO.deletedAt {
                                existing.deletedAt = incomingDeletedAt
                                existing.modifiedAt = incomingDeletedAt
                                summary.removed += 1
                            }
                        } else {
                            let check = CheckRecord(date: checkDate,
                                                    result: CheckResult(wireValue: checkDTO.result),
                                                    comment: checkDTO.comment)
                            check.uuid = checkUUID
                            check.deletedAt = checkDTO.deletedAt
                            check.item = item
                            modelContext.insert(check)
                            checkByUUID[checkUUID] = check
                            summary.checksAdded += 1
                        }
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
