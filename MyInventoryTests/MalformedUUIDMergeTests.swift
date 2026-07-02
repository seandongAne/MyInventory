//
//  MalformedUUIDMergeTests.swift
//  MyInventoryTests
//
//  A corrupt or foreign-producer `.scbk` can carry non-UUID `uuid` strings. The old
//  merge minted a fresh `UUID()` for those, so the same file re-imported as NEW rows
//  on EVERY open — re-opening the same backup duplicated the whole hierarchy, breaking
//  the "re-import = no-op" invariant (a real hazard for a file repeatedly shuttled
//  between a phone and a cloud drive). The importer now SKIPS an entity whose uuid
//  can't be parsed (and its children), counts it in `Summary.skipped`, and surfaces the
//  count in the restore summary — mirroring how a check with a bad id already `continue`s.
//

import XCTest
import SwiftData
@testable import MyInventory

@MainActor
final class MalformedUUIDMergeTests: XCTestCase {

    private var containers: [ModelContainer] = []
    override func tearDownWithError() throws { containers.removeAll() }

    private func makeStore() throws -> ModelContext {
        let container = try ModelContainer(
            for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return container.mainContext
    }

    private let created = Date(timeIntervalSince1970: 1_600_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)

    private func liveContexts(in ctx: ModelContext) throws -> [SupplyContext] {
        try ctx.fetch(FetchDescriptor<SupplyContext>(predicate: #Predicate { $0.deletedAt == nil }))
    }
    private func liveItems(in ctx: ModelContext) throws -> [SupplyItem] {
        try ctx.fetch(FetchDescriptor<SupplyItem>(predicate: #Predicate { $0.deletedAt == nil }))
    }
    private func allContexts(in ctx: ModelContext) throws -> [SupplyContext] {
        try ctx.fetch(FetchDescriptor<SupplyContext>())
    }
    private func allItems(in ctx: ModelContext) throws -> [SupplyItem] {
        try ctx.fetch(FetchDescriptor<SupplyItem>())
    }

    /// A one-item hierarchy where each uuid can be set independently (valid or garbage).
    private func export(contextUUID: String, categoryUUID: String, itemUUID: String,
                        itemName: String = "Water") -> DataExporter.Export {
        let item = DataExporter.ItemDTO(
            uuid: itemUUID, name: itemName,
            intervalValue: 6, intervalUnit: "months", leadTimeDaysOverride: nil,
            quantity: nil, storageLocation: nil, notes: nil,
            createdAt: created, modifiedAt: t1, deletedAt: nil,
            checks: [], checkIntervalMonths: nil)
        let category = DataExporter.CategoryDTO(
            uuid: categoryUUID, name: "Cat", sortOrder: 0,
            createdAt: created, modifiedAt: t1, deletedAt: nil, items: [item])
        let context = DataExporter.ContextDTO(
            uuid: contextUUID, name: "Ctx", sortOrder: 0,
            createdAt: created, modifiedAt: t1, deletedAt: nil, categories: [category])
        return DataExporter.Export(exportedAt: created, contexts: [context])
    }

    // MARK: skip behaviour

    /// A malformed CONTEXT uuid skips the context AND everything under it (nothing is
    /// inserted), and is counted once in `skipped`.
    func testMalformedContextUUIDSkipsWholeSubtree() throws {
        let store = try makeStore()
        let e = export(contextUUID: "not-a-uuid",
                       categoryUUID: UUID().uuidString.lowercased(),
                       itemUUID: UUID().uuidString.lowercased())
        let summary = try DataImporter.merge(e, into: store)

        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.contextsAdded, 0)
        XCTAssertEqual(summary.categoriesAdded, 0)
        XCTAssertEqual(summary.itemsAdded, 0)
        XCTAssertTrue(try allContexts(in: store).isEmpty)
        XCTAssertTrue(try allItems(in: store).isEmpty)
    }

    /// A malformed ITEM uuid under a valid context/category skips only that item; the
    /// context and category still import.
    func testMalformedItemUUIDSkipsOnlyTheItem() throws {
        let store = try makeStore()
        let e = export(contextUUID: UUID().uuidString.lowercased(),
                       categoryUUID: UUID().uuidString.lowercased(),
                       itemUUID: "###garbage###")
        let summary = try DataImporter.merge(e, into: store)

        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.contextsAdded, 1)
        XCTAssertEqual(summary.categoriesAdded, 1)
        XCTAssertEqual(summary.itemsAdded, 0)
        XCTAssertTrue(try liveItems(in: store).isEmpty)
    }

    /// THE core regression: re-importing a backup that carries malformed ids is a
    /// no-op the second time (nothing new inserted) — it does NOT duplicate rows on
    /// every open. Valid siblings imported the first time stay unique.
    func testMalformedUUIDsDoNotDuplicateOnReimport() throws {
        let store = try makeStore()
        // One valid item + one malformed-id item share a valid context/category.
        let ctx = UUID().uuidString.lowercased()
        let cat = UUID().uuidString.lowercased()
        let goodItem = DataExporter.ItemDTO(
            uuid: UUID().uuidString.lowercased(), name: "Good",
            intervalValue: 6, intervalUnit: "months", leadTimeDaysOverride: nil,
            quantity: nil, storageLocation: nil, notes: nil,
            createdAt: created, modifiedAt: t1, deletedAt: nil,
            checks: [], checkIntervalMonths: nil)
        let badItem = DataExporter.ItemDTO(
            uuid: "not-a-uuid", name: "Bad",
            intervalValue: 6, intervalUnit: "months", leadTimeDaysOverride: nil,
            quantity: nil, storageLocation: nil, notes: nil,
            createdAt: created, modifiedAt: t1, deletedAt: nil,
            checks: [], checkIntervalMonths: nil)
        let category = DataExporter.CategoryDTO(
            uuid: cat, name: "Cat", sortOrder: 0,
            createdAt: created, modifiedAt: t1, deletedAt: nil, items: [goodItem, badItem])
        let context = DataExporter.ContextDTO(
            uuid: ctx, name: "Ctx", sortOrder: 0,
            createdAt: created, modifiedAt: t1, deletedAt: nil, categories: [category])
        let e = DataExporter.Export(exportedAt: created, contexts: [context])

        let first = try DataImporter.merge(e, into: store)
        XCTAssertEqual(first.itemsAdded, 1)          // only the good item
        XCTAssertEqual(first.skipped, 1)             // the bad item

        let second = try DataImporter.merge(e, into: store)
        XCTAssertEqual(second.itemsAdded, 0, "re-import must not re-insert the good item")
        XCTAssertEqual(second.skipped, 1, "the bad item is skipped again, not duplicated")

        // Exactly one live item across both imports — never a growing pile of "Bad" copies.
        XCTAssertEqual(try allItems(in: store).count, 1)
        XCTAssertEqual(try liveItems(in: store).map(\.name), ["Good"])
    }

    /// The skipped count is surfaced to the user in the restore summary — including
    /// when nothing else changed, so they learn why an entry didn't import.
    func testSkipCountSurfacesInRestoreDescription() {
        var summary = DataImporter.Summary()
        summary.skipped = 2
        XCTAssertTrue(summary.restoreDescription.contains("2 unreadable entries"),
                      "restore summary must mention skipped entries; got: \(summary.restoreDescription)")

        var one = DataImporter.Summary()
        one.itemsAdded = 3
        one.skipped = 1
        let desc = one.restoreDescription
        XCTAssertTrue(desc.contains("3 items"))
        XCTAssertTrue(desc.contains("1 unreadable entry"))
        XCTAssertFalse(desc.contains("entries"), "singular skip must not pluralize")
    }

    /// Case-insensitive matching still works: an UPPERCASE valid uuid is a valid UUID
    /// (Foundation parses either case), so it is NOT treated as malformed — the skip
    /// guard must only fire on truly unparseable ids.
    func testUppercaseValidUUIDIsNotSkipped() throws {
        let store = try makeStore()
        let e = export(contextUUID: UUID().uuidString,               // uppercase
                       categoryUUID: UUID().uuidString,
                       itemUUID: UUID().uuidString)
        let summary = try DataImporter.merge(e, into: store)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertEqual(summary.itemsAdded, 1)
    }
}
