//
//  SoftDeleteMergeTests.swift
//  MyInventoryTests
//
//  Phase-2 (S3/A) merge engine: soft-delete tombstones + last-write-wins.
//  Covers the model-level `markDeleted` cascade + filtering, and the upgraded
//  `DataImporter.merge` (insert / LWW overwrite / tombstone propagation /
//  monotonic check tombstone), plus the export carrying tombstones on the wire.
//

import XCTest
import SwiftData
@testable import MyInventory

@MainActor
final class SoftDeleteMergeTests: XCTestCase {

    private var containers: [ModelContainer] = []
    override func tearDownWithError() throws { containers.removeAll() }

    private func makeStore() throws -> ModelContext {
        let container = try ModelContainer(
            for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return container.mainContext
    }

    // Fixed instants (oldest → newest) so LWW ordering is deterministic.
    private let created = Date(timeIntervalSince1970: 1_600_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_800_000_000)

    /// One live context → category → item (6-month interval), with explicit uuids
    /// and `modifiedAt`, optionally one check. Lets a hand-built export be matched
    /// against it by uuid for LWW.
    private func seedLiveItem(into ctx: ModelContext,
                              contextUUID: UUID, categoryUUID: UUID, itemUUID: UUID,
                              name: String, modified: Date,
                              check: (uuid: UUID, date: Date)? = nil) throws {
        let context = SupplyContext(name: "Ctx")
        context.uuid = contextUUID; context.modifiedAt = modified
        ctx.insert(context)

        let category = SupplyCategory(name: "Cat")
        category.uuid = categoryUUID; category.context = context; category.modifiedAt = modified
        ctx.insert(category)

        let item = SupplyItem(name: name, checkIntervalMonths: 6)
        item.uuid = itemUUID; item.category = category; item.modifiedAt = modified
        ctx.insert(item)

        if let check {
            let record = CheckRecord(date: check.date, result: .ok)
            record.uuid = check.uuid; record.item = item
            ctx.insert(record)
        }
        try ctx.save()
    }

    /// A backup payload with one context/category/item (+ optional check), with
    /// tunable `modifiedAt`/`deletedAt` so a test can model "what device B sent".
    private func singleItemExport(contextUUID: UUID, categoryUUID: UUID, itemUUID: UUID,
                                  itemName: String,
                                  itemModified: Date, itemDeletedAt: Date? = nil,
                                  contextDeletedAt: Date? = nil,
                                  check: (uuid: UUID, date: Date, deletedAt: Date?)? = nil
    ) -> DataExporter.Export {
        let checkDTOs: [DataExporter.CheckDTO] = check.map {
            [DataExporter.CheckDTO(uuid: $0.uuid.uuidString.lowercased(),
                                   date: DataExporter.wireDate($0.date),
                                   result: "ok", comment: nil, deletedAt: $0.deletedAt)]
        } ?? []
        let item = DataExporter.ItemDTO(
            uuid: itemUUID.uuidString.lowercased(), name: itemName,
            intervalValue: 6, intervalUnit: "months", leadTimeDaysOverride: nil,
            quantity: nil, storageLocation: nil, notes: nil,
            createdAt: created, modifiedAt: itemModified, deletedAt: itemDeletedAt,
            checks: checkDTOs, checkIntervalMonths: nil)
        let category = DataExporter.CategoryDTO(
            uuid: categoryUUID.uuidString.lowercased(), name: "Cat", sortOrder: 0,
            createdAt: created, modifiedAt: created, deletedAt: nil, items: [item])
        let context = DataExporter.ContextDTO(
            uuid: contextUUID.uuidString.lowercased(), name: "Ctx", sortOrder: 0,
            createdAt: created, modifiedAt: created, deletedAt: contextDeletedAt,
            categories: [category])
        return DataExporter.Export(exportedAt: created, contexts: [context])
    }

    private func liveItems(in ctx: ModelContext) throws -> [SupplyItem] {
        try ctx.fetch(FetchDescriptor<SupplyItem>(predicate: #Predicate { $0.deletedAt == nil }))
    }

    // MARK: model-level soft delete

    /// `markDeleted` tombstones the item + cascades to its checks, bumps modifiedAt,
    /// and the row drops out of every `unwrapped…`/`allItems` accessor.
    func testMarkDeletedHidesCascadesAndBumpsModified() throws {
        let store = try makeStore()
        let cu = UUID(), catu = UUID(), iu = UUID(), cku = UUID()
        try seedLiveItem(into: store, contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                         name: "Water", modified: t1, check: (cku, t1))

        let item = try XCTUnwrap(try store.fetch(FetchDescriptor<SupplyItem>()).first)
        item.markDeleted(now: t2)
        try store.save()

        XCTAssertEqual(item.deletedAt, t2)
        XCTAssertEqual(item.modifiedAt, t2)
        let check = try XCTUnwrap(try store.fetch(FetchDescriptor<CheckRecord>()).first)
        XCTAssertNotNil(check.deletedAt)                       // cascade

        let context = try XCTUnwrap(try store.fetch(FetchDescriptor<SupplyContext>()).first)
        XCTAssertTrue(context.allItems.isEmpty)               // hidden from accessors
        XCTAssertTrue(item.unwrappedChecks.isEmpty)
        XCTAssertNil(item.lastCheck)
    }

    /// `context.markDeleted` cascades a tombstone over the whole subtree, and the
    /// export carries every tombstone on the wire (raw relationships, not the
    /// filtered accessors).
    func testContextCascadeIsCarriedInExport() throws {
        let store = try makeStore()
        let cu = UUID(), catu = UUID(), iu = UUID(), cku = UUID()
        try seedLiveItem(into: store, contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                         name: "Water", modified: t1, check: (cku, t1))

        let context = try XCTUnwrap(try store.fetch(FetchDescriptor<SupplyContext>()).first)
        context.markDeleted(now: t2)
        try store.save()

        let export = try DataImporter.decode(try DataExporter.makeExport(from: store))
        let ctxDTO = try XCTUnwrap(export.contexts.first)
        XCTAssertNotNil(ctxDTO.deletedAt)
        let catDTO = try XCTUnwrap(ctxDTO.categories.first)
        XCTAssertNotNil(catDTO.deletedAt)
        let itemDTO = try XCTUnwrap(catDTO.items.first)
        XCTAssertNotNil(itemDTO.deletedAt)
        XCTAssertNotNil(itemDTO.checks.first?.deletedAt)
    }

    /// A live export omits `deletedAt` entirely (nil optionals are not encoded) —
    /// forward-compatible with Android / pre-Phase-2 readers.
    func testLiveExportOmitsDeletedAtKey() throws {
        let store = try makeStore()
        try seedLiveItem(into: store, contextUUID: UUID(), categoryUUID: UUID(),
                         itemUUID: UUID(), name: "Water", modified: t1)
        let json = String(decoding: try DataExporter.makeExport(from: store), as: UTF8.self)
        XCTAssertFalse(json.contains("deletedAt"))
    }

    // MARK: merge — last-write-wins + tombstones

    /// A newer incoming tombstone removes a local live item (the core sync case).
    func testNewerIncomingTombstoneRemovesLocalItem() throws {
        let store = try makeStore()
        let cu = UUID(), catu = UUID(), iu = UUID()
        try seedLiveItem(into: store, contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                         name: "Water", modified: t1)

        let export = singleItemExport(contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                                      itemName: "Water", itemModified: t2, itemDeletedAt: t2)
        let summary = try DataImporter.merge(export, into: store)

        XCTAssertEqual(summary.removed, 1)
        XCTAssertEqual(summary.itemsAdded, 0)
        XCTAssertTrue(try liveItems(in: store).isEmpty)
        XCTAssertEqual(try store.fetch(FetchDescriptor<SupplyItem>()).count, 1) // still stored
    }

    /// An OLDER incoming edit must not clobber a newer local edit.
    func testOlderIncomingEditIsIgnored() throws {
        let store = try makeStore()
        let cu = UUID(), catu = UUID(), iu = UUID()
        try seedLiveItem(into: store, contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                         name: "New name", modified: t2)

        let export = singleItemExport(contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                                      itemName: "Old name", itemModified: t1)
        let summary = try DataImporter.merge(export, into: store)

        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(try liveItems(in: store).first?.name, "New name")
    }

    /// A NEWER incoming edit overwrites the local fields (LWW).
    func testNewerIncomingEditOverwrites() throws {
        let store = try makeStore()
        let cu = UUID(), catu = UUID(), iu = UUID()
        try seedLiveItem(into: store, contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                         name: "Old name", modified: t1)

        let export = singleItemExport(contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                                      itemName: "Renamed", itemModified: t2)
        let summary = try DataImporter.merge(export, into: store)

        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(try liveItems(in: store).first?.name, "Renamed")
    }

    /// A locally-tombstoned item is NOT resurrected by an older live backup.
    func testLocalTombstoneSurvivesOlderLiveBackup() throws {
        let store = try makeStore()
        let cu = UUID(), catu = UUID(), iu = UUID()
        try seedLiveItem(into: store, contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                         name: "Water", modified: t1)
        let item = try XCTUnwrap(try store.fetch(FetchDescriptor<SupplyItem>()).first)
        item.markDeleted(now: t2)
        try store.save()

        let export = singleItemExport(contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                                      itemName: "Water", itemModified: t1)   // older, live
        let summary = try DataImporter.merge(export, into: store)

        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(summary.removed, 0)
        XCTAssertTrue(try liveItems(in: store).isEmpty)
    }

    /// Deleting a check propagates as a monotonic tombstone; the item's derived
    /// last-check recomputes.
    func testIncomingCheckTombstonePropagates() throws {
        let store = try makeStore()
        let cu = UUID(), catu = UUID(), iu = UUID(), cku = UUID()
        try seedLiveItem(into: store, contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                         name: "Water", modified: t1, check: (cku, t1))
        let item = try XCTUnwrap(try store.fetch(FetchDescriptor<SupplyItem>()).first)
        XCTAssertNotNil(item.lastCheck)

        let export = singleItemExport(contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                                      itemName: "Water", itemModified: t1,
                                      check: (cku, t1, t2))   // same check, now tombstoned
        let summary = try DataImporter.merge(export, into: store)

        XCTAssertEqual(summary.removed, 1)
        XCTAssertTrue(item.unwrappedChecks.isEmpty)
        XCTAssertNil(item.lastCheck)
    }

    /// Importing a tombstone-bearing backup is idempotent.
    func testTombstoneImportIsIdempotent() throws {
        let store = try makeStore()
        let cu = UUID(), catu = UUID(), iu = UUID()
        let export = singleItemExport(contextUUID: cu, categoryUUID: catu, itemUUID: iu,
                                      itemName: "Water", itemModified: t2, itemDeletedAt: t2)
        let first = try DataImporter.merge(export, into: store)
        XCTAssertFalse(first.isEmpty)
        let second = try DataImporter.merge(export, into: store)
        XCTAssertTrue(second.isEmpty)
        XCTAssertTrue(try liveItems(in: store).isEmpty)
    }
}
