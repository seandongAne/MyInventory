//
//  BackupRoundTripTests.swift
//  MyInventoryTests
//
//  End-to-end coverage of the encrypted-backup *flow* that SettingsView wires up:
//  DataExporter → BackupCrypto.encryptBackup → serializeEnvelope → parseEnvelope →
//  decryptWithPassphrase/RecoveryKey → DataImporter.decode → merge. BackupCryptoTests
//  pins the crypto against the cross-platform golden vectors; this proves the iOS
//  app's own export/import glue survives a full encrypt-then-restore round trip.
//

import XCTest
import SwiftData
@testable import MyInventory

@MainActor
final class BackupRoundTripTests: XCTestCase {

    /// In-memory containers built during a test, retained so they outlive the
    /// `ModelContext`s handed back (a context alone won't keep its container alive,
    /// and a deallocated container crashes the next `save`).
    private var containers: [ModelContainer] = []

    override func tearDownWithError() throws {
        containers.removeAll()
    }

    private func makeStore() throws -> ModelContext {
        let container = try ModelContainer(
            for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return container.mainContext
    }

    /// Seeds one context → category → item (6-month interval) → check, saves, and
    /// returns the stable uuids so a restore can be matched against them.
    @discardableResult
    private func seed(into context: ModelContext) throws
        -> (context: UUID, category: UUID, item: UUID, check: UUID) {
        let supplyContext = SupplyContext(name: "Vehicle", sortOrder: 0)
        context.insert(supplyContext)

        let category = SupplyCategory(name: "First Aid", sortOrder: 0)
        category.context = supplyContext
        context.insert(category)

        let item = SupplyItem(name: "Trauma Kit", checkIntervalMonths: 6,
                              storageLocation: "Trunk", notes: "Restock gauze")
        item.quantity = 2
        item.category = category
        context.insert(item)

        let check = CheckRecord(date: Date(timeIntervalSince1970: 1_700_000_000),
                                result: .ok, comment: "All sealed")
        check.item = item
        context.insert(check)

        try context.save()
        return (supplyContext.uuid, category.uuid, item.uuid, check.uuid)
    }

    /// The full chain the export sheet runs, then the unlock sheet + merge.
    func testEncryptedExportRestoresIntoFreshStore() throws {
        let source = try makeStore()
        let ids = try seed(into: source)

        // Export sheet: makePlaintext == DataExporter.makeExport as a UTF-8 string.
        let plaintext = String(decoding: try DataExporter.makeExport(from: source), as: UTF8.self)
        let (envelope, recoveryKey) = try BackupCrypto.encryptBackup(
            plaintextUtf8: plaintext, passphrase: "trunk-medkit-2026")

        // The recovery key is the grouped base32 form shown once to the user.
        XCTAssertTrue(recoveryKey.contains("-"))

        // Serialize → file bytes → parse back (what picking the .scbk does).
        let fileBytes = try BackupCrypto.serializeEnvelope(envelope)
        let parsed = try BackupCrypto.parseEnvelope(fileBytes)

        // Unlock sheet (passphrase) → SettingsView.mergeDecrypted into a fresh store.
        let decrypted = try BackupCrypto.decryptWithPassphrase(parsed, passphrase: "trunk-medkit-2026")
        let restored = try makeStore()
        let summary = try DataImporter.merge(DataImporter.decode(Data(decrypted.utf8)), into: restored)

        XCTAssertEqual(summary.contextsAdded, 1)
        XCTAssertEqual(summary.categoriesAdded, 1)
        XCTAssertEqual(summary.itemsAdded, 1)
        XCTAssertEqual(summary.checksAdded, 1)

        let items = try restored.fetch(FetchDescriptor<SupplyItem>())
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.uuid, ids.item)
        XCTAssertEqual(item.name, "Trauma Kit")
        XCTAssertEqual(item.intervalValue, 6)
        XCTAssertEqual(item.quantity, 2)
        XCTAssertEqual(item.storageLocation, "Trunk")
        XCTAssertEqual(item.category?.uuid, ids.category)
        XCTAssertEqual(item.category?.context?.uuid, ids.context)
        XCTAssertEqual(item.unwrappedChecks.first?.uuid, ids.check)
        XCTAssertEqual(item.unwrappedChecks.first?.result, .ok)
    }

    /// The recovery-key unlock path yields the identical plaintext.
    func testRecoveryKeyUnlocksTheSameBackup() throws {
        let source = try makeStore()
        try seed(into: source)
        let plaintext = String(decoding: try DataExporter.makeExport(from: source), as: UTF8.self)
        let (envelope, recoveryKey) = try BackupCrypto.encryptBackup(
            plaintextUtf8: plaintext, passphrase: "passphrase-A")

        let viaRecovery = try BackupCrypto.decryptWithRecoveryKey(envelope, recoveryKey: recoveryKey)
        XCTAssertEqual(viaRecovery, plaintext)
    }

    /// Re-importing the same decrypted backup is a no-op (idempotent merge).
    func testRestoreIsIdempotent() throws {
        let source = try makeStore()
        try seed(into: source)
        let plaintext = String(decoding: try DataExporter.makeExport(from: source), as: UTF8.self)
        let (envelope, _) = try BackupCrypto.encryptBackup(
            plaintextUtf8: plaintext, passphrase: "again-and-again")
        let decrypted = try BackupCrypto.decryptWithPassphrase(envelope, passphrase: "again-and-again")
        let export = try DataImporter.decode(Data(decrypted.utf8))

        let restored = try makeStore()
        let first = try DataImporter.merge(export, into: restored)
        XCTAssertFalse(first.isEmpty)
        let second = try DataImporter.merge(export, into: restored)
        XCTAssertTrue(second.isEmpty)
    }

    /// A wrong passphrase surfaces the friendly `.wrongPassphrase` error the unlock
    /// sheet shows — not a generic corruption error.
    func testWrongPassphraseSurfacesWrongPassphrase() throws {
        let source = try makeStore()
        try seed(into: source)
        let plaintext = String(decoding: try DataExporter.makeExport(from: source), as: UTF8.self)
        let (envelope, _) = try BackupCrypto.encryptBackup(
            plaintextUtf8: plaintext, passphrase: "the-right-one")

        XCTAssertThrowsError(try BackupCrypto.decryptWithPassphrase(envelope, passphrase: "the-wrong-one")) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .wrongPassphrase)
        }
    }
}
