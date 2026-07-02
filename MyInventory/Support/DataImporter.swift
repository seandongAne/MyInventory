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
        // Entities skipped because their `uuid` couldn't be parsed (a corrupt or
        // foreign-producer backup). Skipping keeps re-import a no-op — minting a fresh
        // UUID would re-insert them as NEW rows on every open, duplicating the hierarchy.
        var skipped = 0
        // The synced settings singleton was replaced by a newer incoming version.
        var settingsUpdated = false

        var isEmpty: Bool {
            contextsAdded == 0 && categoriesAdded == 0 && itemsAdded == 0
                && checksAdded == 0 && updated == 0 && removed == 0 && !settingsUpdated
        }

        /// Human-readable restore summary shown after a backup merge. Shared by the
        /// Settings → Restore flow and the "Open in MyInventory" file-open path so the
        /// wording never drifts. Built in steps (no nested ternaries in one
        /// interpolation) to keep type-checking fast.
        var restoreDescription: String {
            func phrase(_ count: Int, _ noun: String) -> String {
                "\(count) \(noun)\(count == 1 ? "" : "s")"
            }
            // A skip warning is appended to whatever the merge did — including the
            // "nothing to add" case, so the user learns why unreadable entries didn't
            // import (and why re-opening won't help).
            func withSkipWarning(_ base: String) -> String {
                guard skipped > 0 else { return base }
                let entries = skipped == 1 ? "1 unreadable entry" : "\(skipped) unreadable entries"
                return base + " Skipped \(entries) that couldn't be read."
            }
            guard !isEmpty else {
                return withSkipWarning("Everything in this backup is already here — nothing to add.")
            }
            var message = "Added \(phrase(contextsAdded, "place")), "
                + "\(phrase(itemsAdded, "item")), and "
                + "\(phrase(checksAdded, "check"))."
            if updated > 0 { message += " Updated \(phrase(updated, "record"))." }
            if removed > 0 { message += " Removed \(phrase(removed, "record"))." }
            if settingsUpdated { message += " Updated your settings." }
            return withSkipWarning(message)
        }
    }

    enum ImportError: LocalizedError {
        case malformed
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .malformed:
                return "This file isn’t a MyInventory backup, or it’s damaged."
            case .tooLarge:
                return "This file is too large to be a Supplies Check backup."
            }
        }
    }

    /// A generous ceiling on a backup file we're willing to read into memory. A real
    /// `.scbk`/JSON export of a personal inventory is well under a megabyte; anything
    /// past this is a renamed or padded junk file, so we reject it up front rather than
    /// letting `Data(contentsOf:)` block the main actor (or get the app jetsammed) on it.
    static let maxBackupFileBytes = 32 * 1024 * 1024   // 32 MB

    /// Reads a picked/incoming backup file safely: size-caps it via `resourceValues`
    /// before reading a single byte, then reads off the main actor (a large file must
    /// never block the UI). Holds the security scope across the read. `.tooLarge` is
    /// thrown for anything over `maxBackupFileBytes`.
    ///
    /// Not `@MainActor` — call it from a `Task` so the read happens off the main thread.
    static func readBackupData(at url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Check declared size first — cheap, and avoids reading a huge file at all.
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > maxBackupFileBytes {
                throw ImportError.tooLarge
            }
            let data = try Data(contentsOf: url)
            // Belt-and-suspenders: `fileSizeKey` can be missing (some providers), so
            // guard the actually-read length too.
            if data.count > maxBackupFileBytes { throw ImportError.tooLarge }
            return data
        }.value
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

    // MARK: LWW comparison at wire precision (+ deterministic tiebreaker)

    /// The wire (`docs/SCBK1_Format.md` §5) carries `modifiedAt` at WHOLE-SECOND
    /// ISO-8601 precision — Foundation's `.iso8601` strategy both emits and parses
    /// without fractional seconds. But a live model's `modifiedAt` is a full-precision
    /// `Date` (its sub-second fraction comes from `.now` at edit time). Comparing a
    /// full-precision local Date against the truncated wire value with a naive strict
    /// `>` diverges permanently: if two devices edit the same row in the same wall-clock
    /// second, each sees the incoming (truncated) value as strictly OLDER than its own
    /// (sub-second-heavier) local value, so BOTH keep their own edit forever — no error,
    /// just a silent split-brain. The fix is to compare at ONE precision: truncate BOTH
    /// sides to whole seconds before ordering. One-sided (local-only) truncation would
    /// still be asymmetric, so we truncate both.
    private static func wireSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    /// The outcome of an LWW comparison for one entity, at wire precision.
    enum LWWDecision { case keepLocal, adoptIncoming }

    /// Decide whether an incoming version should overwrite the local row, comparing at
    /// wire (whole-second) precision. When the two truncated timestamps are EQUAL —
    /// the same-second collision above — a strict `>`/`<` can't order them, so we fall
    /// back to a deterministic content tiebreaker: adopt incoming iff its canonical
    /// content string sorts strictly greater than the local one. This is:
    ///   • symmetric — both peers compute the same `>` on the same two strings, so they
    ///     pick the SAME winner and converge (instead of each keeping local → split-brain);
    ///   • idempotent — identical content compares equal → `keepLocal`, so re-importing
    ///     the same blob is still a no-op (the §6 "equal keeps local" guarantee holds for
    ///     genuinely-equal rows);
    ///   • wire-compatible — nothing new is emitted; the tiebreaker is a pure read-side
    ///     rule over fields already on the wire, so a Phase-1 additive Android peer is
    ///     unaffected (it never overwrites on equality either, and once one side wins the
    ///     content converges).
    /// The tiebreaker only runs on a true tie, so it never overrides a real newer edit.
    static func decideLWW(incomingModified: Date, localModified: Date,
                          incomingContent: @autoclosure () -> String,
                          localContent: @autoclosure () -> String) -> LWWDecision {
        let incoming = wireSeconds(incomingModified)
        let local = wireSeconds(localModified)
        if incoming > local { return .adoptIncoming }
        if incoming < local { return .keepLocal }
        // Same wire-second: break the tie on canonical content so peers converge.
        return incomingContent() > localContent() ? .adoptIncoming : .keepLocal
    }

    /// Merges the backup into the store, matching existing rows by `uuid`. Saves
    /// once at the end (rollback + rethrow on failure, per the store invariant).
    @MainActor
    @discardableResult
    static func merge(_ export: DataExporter.Export,
                      into modelContext: ModelContext,
                      settings: SettingsStore? = nil) throws -> Summary {
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
            // so case differences across platforms collapse here. A malformed id can't
            // be matched by value, so minting a fresh one would re-insert the whole
            // subtree as NEW rows on EVERY open (re-import stops being a no-op). Skip
            // it — and its children — with a counted warning instead, mirroring how a
            // check with a bad id already `continue`s below.
            guard let contextUUID = UUID(uuidString: contextDTO.uuid) else {
                summary.skipped += 1
                continue
            }
            let incomingModified = contextDTO.modifiedAt ?? contextDTO.createdAt
            let context: SupplyContext
            if let existing = contextByUUID[contextUUID] {
                context = existing
                let decision = decideLWW(
                    incomingModified: incomingModified, localModified: existing.modifiedAt,
                    incomingContent: Self.contextContent(contextDTO),
                    localContent: Self.contextContent(existing))
                if decision == .adoptIncoming {
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
                guard let categoryUUID = UUID(uuidString: categoryDTO.uuid) else {
                    summary.skipped += 1
                    continue
                }
                let incomingCatModified = categoryDTO.modifiedAt ?? categoryDTO.createdAt
                let category: SupplyCategory
                if let existing = categoryByUUID[categoryUUID] {
                    category = existing
                    let decision = decideLWW(
                        incomingModified: incomingCatModified, localModified: existing.modifiedAt,
                        incomingContent: Self.categoryContent(categoryDTO),
                        localContent: Self.categoryContent(existing))
                    if decision == .adoptIncoming {
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
                    guard let itemUUID = UUID(uuidString: itemDTO.uuid) else {
                        summary.skipped += 1
                        continue
                    }
                    let incomingItemModified = itemDTO.modifiedAt ?? itemDTO.createdAt
                    let item: SupplyItem
                    if let existing = itemByUUID[itemUUID] {
                        item = existing
                        let decision = decideLWW(
                            incomingModified: incomingItemModified, localModified: existing.modifiedAt,
                            incomingContent: Self.itemContent(itemDTO),
                            localContent: Self.itemContent(existing))
                        if decision == .adoptIncoming {
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

        // Settings live in UserDefaults (SettingsStore), not the model context, so
        // they merge separately — whole-object LWW on the singleton's modifiedAt,
        // compared at wire (whole-second) precision with the same content tiebreaker as
        // the entities (so two devices editing settings in the same second converge on
        // one value instead of each keeping its own). Applied after the entity save so a
        // failed import changes nothing.
        if let store = settings, let dto = export.settings,
           decideLWW(incomingModified: dto.modifiedAt, localModified: store.settingsModifiedAt,
                     incomingContent: Self.settingsContent(dto),
                     localContent: Self.settingsContent(store)) == .adoptIncoming {
            store.applyMergedSettings(
                globalLeadTimeDays: dto.globalLeadTimeDays,
                defaultIntervalValue: dto.defaultIntervalValue ?? 0,
                defaultIntervalUnit: dto.defaultIntervalUnit,
                notificationFireHour: dto.notificationFireHour,
                modifiedAt: dto.modifiedAt
            )
            summary.settingsUpdated = true
        }

        return summary
    }

    // MARK: Canonical content strings (same-second tiebreaker input)
    //
    // Each builds a stable, delimiter-joined string of the MERGEABLE fields of a row —
    // exactly the fields the merge would overwrite (never `createdAt`/`uuid`, which are
    // stable, nor child collections, which merge independently). The delimiter is a
    // control char that can't appear in user text, so distinct field tuples never
    // collide. Both the incoming DTO and the local model must map to the SAME string for
    // equal content, so the two forms are kept field-for-field in sync here. The
    // tiebreaker only compares these on a same-wire-second collision.

    private static let sep = "\u{1F}"   // ASCII Unit Separator

    private static func contextContent(_ dto: DataExporter.ContextDTO) -> String {
        [dto.name, String(dto.sortOrder), isoOrEmpty(dto.deletedAt)].joined(separator: sep)
    }
    private static func contextContent(_ model: SupplyContext) -> String {
        [model.name, String(model.sortOrder), isoOrEmpty(model.deletedAt)].joined(separator: sep)
    }

    private static func categoryContent(_ dto: DataExporter.CategoryDTO) -> String {
        [dto.name, String(dto.sortOrder), isoOrEmpty(dto.deletedAt)].joined(separator: sep)
    }
    private static func categoryContent(_ model: SupplyCategory) -> String {
        [model.name, String(model.sortOrder), isoOrEmpty(model.deletedAt)].joined(separator: sep)
    }

    private static func itemContent(_ dto: DataExporter.ItemDTO) -> String {
        [dto.name,
         intString(dto.intervalValue ?? dto.checkIntervalMonths),
         dto.intervalUnit ?? IntervalUnit.months.rawValue,
         intString(dto.leadTimeDaysOverride),
         intString(dto.quantity),
         dto.storageLocation ?? "",
         dto.notes ?? "",
         isoOrEmpty(dto.deletedAt)].joined(separator: sep)
    }
    private static func itemContent(_ model: SupplyItem) -> String {
        [model.name,
         intString(model.intervalValue),
         model.intervalUnit,
         intString(model.leadTimeDaysOverride),
         intString(model.quantity),
         model.storageLocation ?? "",
         model.notes ?? "",
         isoOrEmpty(model.deletedAt)].joined(separator: sep)
    }

    private static func settingsContent(_ dto: DataExporter.SettingsDTO) -> String {
        [String(dto.globalLeadTimeDays),
         intString(dto.defaultIntervalValue),
         dto.defaultIntervalUnit,
         String(dto.notificationFireHour)].joined(separator: sep)
    }
    private static func settingsContent(_ store: SettingsStore) -> String {
        [String(store.globalLeadTimeDays),
         intString(store.defaultIntervalValueOrNil),
         store.defaultIntervalUnit,
         String(store.notificationFireHour)].joined(separator: sep)
    }

    /// An optional-int rendered so `nil` never collides with a real value (e.g. `nil`
    /// vs `0` must differ — an item with no interval vs a 0-interval item).
    private static func intString(_ value: Int?) -> String {
        value.map(String.init) ?? "∅"
    }

    /// A tombstone instant at the same whole-second precision the tiebreaker orders on,
    /// so a live-vs-tombstoned same-second collision is decided consistently on both
    /// peers. Empty for a live row.
    private static func isoOrEmpty(_ date: Date?) -> String {
        guard let date else { return "" }
        return String(Int64(date.timeIntervalSince1970.rounded(.down)))
    }
}
