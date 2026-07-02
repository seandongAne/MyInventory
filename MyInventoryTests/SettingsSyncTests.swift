//
//  SettingsSyncTests.swift
//  MyInventoryTests
//
//  The synced settings singleton in the SCBK1 wire format: export (with the
//  0↔null default-interval mapping) and whole-object last-write-wins merge on
//  `settingsModifiedAt` (sync plan §4/§9).
//

import XCTest
import SwiftData
@testable import MyInventory

@MainActor
final class SettingsSyncTests: XCTestCase {

    private var containers: [ModelContainer] = []
    override func tearDownWithError() throws { containers.removeAll() }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return container.mainContext
    }

    private func freshSettings(_ name: String = #function) -> SettingsStore {
        // In-memory defaults, not a real CFPreferences suite: creating/removing
        // transient suites intermittently crashed the CI test host (see
        // `InMemoryDefaults`).
        SettingsStore(defaults: InMemoryDefaults())
    }

    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_800_000_000)

    private func settingsExport(lead: Int, value: Int?, unit: String, hour: Int,
                                modified: Date) -> DataExporter.Export {
        DataExporter.Export(
            exportedAt: t2,
            contexts: [],
            settings: DataExporter.SettingsDTO(
                globalLeadTimeDays: lead,
                defaultIntervalValue: value,
                defaultIntervalUnit: unit,
                notificationFireHour: hour,
                modifiedAt: modified))
    }

    // MARK: Export

    func testExportMapsZeroDefaultIntervalToNull() throws {
        let ctx = try makeContext()
        let store = freshSettings()
        store.defaultIntervalValue = 0   // "no default"

        let data = try DataExporter.makeExport(from: ctx, settings: store, now: t1)
        let export = try DataImporter.decode(data)
        XCTAssertNil(export.settings?.defaultIntervalValue)
    }

    func testExportCarriesSettingsValues() throws {
        let ctx = try makeContext()
        let store = freshSettings()
        store.applyMergedSettings(globalLeadTimeDays: 14, defaultIntervalValue: 3,
                                  defaultIntervalUnit: "years", notificationFireHour: 6,
                                  modifiedAt: t1)

        let export = try DataImporter.decode(try DataExporter.makeExport(from: ctx, settings: store, now: t2))
        let dto = try XCTUnwrap(export.settings)
        XCTAssertEqual(dto.globalLeadTimeDays, 14)
        XCTAssertEqual(dto.defaultIntervalValue, 3)
        XCTAssertEqual(dto.defaultIntervalUnit, "years")
        XCTAssertEqual(dto.notificationFireHour, 6)
        XCTAssertEqual(dto.modifiedAt, t1)
    }

    func testNoSettingsOnExportWhenNotProvided() throws {
        let ctx = try makeContext()
        let export = try DataImporter.decode(try DataExporter.makeExport(from: ctx, now: t1))
        XCTAssertNil(export.settings)
    }

    // MARK: Merge — whole-object LWW

    func testNewerIncomingSettingsWin() throws {
        let ctx = try makeContext()
        let store = freshSettings()
        store.applyMergedSettings(globalLeadTimeDays: 7, defaultIntervalValue: 1,
                                  defaultIntervalUnit: "months", notificationFireHour: 9,
                                  modifiedAt: t1)

        let export = settingsExport(lead: 30, value: 2, unit: "years", hour: 8, modified: t2)
        let summary = try DataImporter.merge(export, into: ctx, settings: store)

        XCTAssertTrue(summary.settingsUpdated)
        XCTAssertEqual(store.globalLeadTimeDays, 30)
        XCTAssertEqual(store.defaultIntervalValue, 2)
        XCTAssertEqual(store.defaultIntervalUnit, "years")
        XCTAssertEqual(store.notificationFireHour, 8)
        // Local timestamp adopts the incoming instant (not "now"), so re-export wins.
        XCTAssertEqual(store.settingsModifiedAt, t2)
    }

    func testOlderIncomingSettingsIgnored() throws {
        let ctx = try makeContext()
        let store = freshSettings()
        store.applyMergedSettings(globalLeadTimeDays: 7, defaultIntervalValue: 1,
                                  defaultIntervalUnit: "months", notificationFireHour: 9,
                                  modifiedAt: t2)

        let export = settingsExport(lead: 30, value: 2, unit: "years", hour: 8, modified: t1)
        let summary = try DataImporter.merge(export, into: ctx, settings: store)

        XCTAssertFalse(summary.settingsUpdated)
        XCTAssertEqual(store.globalLeadTimeDays, 7)
        XCTAssertEqual(store.settingsModifiedAt, t2)
    }

    func testEqualModifiedIsNoOp() throws {
        let ctx = try makeContext()
        let store = freshSettings()
        store.applyMergedSettings(globalLeadTimeDays: 7, defaultIntervalValue: 1,
                                  defaultIntervalUnit: "months", notificationFireHour: 9,
                                  modifiedAt: t1)

        let export = settingsExport(lead: 30, value: 2, unit: "years", hour: 8, modified: t1)
        let summary = try DataImporter.merge(export, into: ctx, settings: store)

        XCTAssertFalse(summary.settingsUpdated)
        XCTAssertEqual(store.globalLeadTimeDays, 7)
    }

    func testNullDefaultIntervalMapsToZeroOnImport() throws {
        let ctx = try makeContext()
        let store = freshSettings()   // starts at epoch, so incoming wins

        let export = settingsExport(lead: 10, value: nil, unit: "months", hour: 9, modified: t1)
        try DataImporter.merge(export, into: ctx, settings: store)

        XCTAssertEqual(store.defaultIntervalValue, 0)
        XCTAssertNil(store.defaultIntervalValueOrNil)
    }

    func testUneditedDefaultsNeverWinOverAnEdit() throws {
        // A fresh device (settingsModifiedAt == epoch) exports; an edited peer must
        // keep its edit rather than adopting the fresh device's defaults.
        let ctx = try makeContext()
        let fresh = freshSettings("fresh")
        let edited = freshSettings("edited")
        edited.globalLeadTimeDays = 21   // a real edit bumps modifiedAt to ~now

        let export = try DataImporter.decode(try DataExporter.makeExport(from: ctx, settings: fresh, now: t1))
        let summary = try DataImporter.merge(export, into: ctx, settings: edited)

        XCTAssertFalse(summary.settingsUpdated)
        XCTAssertEqual(edited.globalLeadTimeDays, 21)
    }

    // MARK: Clock-skew hardening

    /// A peer with a fast clock ships a FUTURE-dated settings blob. After adopting
    /// it, a later LOCAL edit must survive re-importing the same blob: the edit's
    /// timestamp bumps monotonically past the adopted instant. (A plain `.now`
    /// stamp would be older than the adopted future instant, so every subsequent
    /// merge would silently revert the edit until the wall clock caught up.)
    func testLocalEditSurvivesReimportOfFutureDatedSettings() throws {
        let ctx = try makeContext()
        let store = freshSettings()
        let future = Date.now.addingTimeInterval(60 * 60 * 24 * 365)
        let export = settingsExport(lead: 30, value: 2, unit: "years", hour: 8, modified: future)
        try DataImporter.merge(export, into: ctx, settings: store)
        XCTAssertEqual(store.globalLeadTimeDays, 30)

        store.globalLeadTimeDays = 10   // local edit while the wall clock is still "behind"

        let summary = try DataImporter.merge(export, into: ctx, settings: store)
        XCTAssertFalse(summary.settingsUpdated)
        XCTAssertEqual(store.globalLeadTimeDays, 10,
                       "re-importing the same future-dated blob must not revert the local edit")
    }

    // MARK: Range validation on import

    /// Imported settings are untrusted wire data — out-of-range values are clamped
    /// on adoption. Unclamped, a negative fireHour flows into
    /// `NotificationManager.resolvedFireDate` and arms past-dated non-repeating
    /// triggers (every reminder silently never fires), and a negative lead window
    /// disables due-soon status and lead reminders.
    func testOutOfRangeImportedSettingsAreClamped() throws {
        let ctx = try makeContext()
        let store = freshSettings()

        let export = settingsExport(lead: -30, value: -5, unit: "months", hour: -999, modified: t1)
        let summary = try DataImporter.merge(export, into: ctx, settings: store)

        XCTAssertTrue(summary.settingsUpdated)
        XCTAssertEqual(store.globalLeadTimeDays, 0)
        XCTAssertEqual(store.defaultIntervalValue, 0)
        XCTAssertEqual(store.notificationFireHour, 0)
    }

    func testOverRangeImportedFireHourClampsTo23() throws {
        let ctx = try makeContext()
        let store = freshSettings()

        try DataImporter.merge(settingsExport(lead: 7, value: 1, unit: "months",
                                              hour: 999, modified: t1),
                               into: ctx, settings: store)

        XCTAssertEqual(store.notificationFireHour, 23)
    }

    // MARK: Round-trip

    func testRoundTripAppliesToAFreshPeer() throws {
        let ctx = try makeContext()
        let source = freshSettings("source")
        source.applyMergedSettings(globalLeadTimeDays: 3, defaultIntervalValue: 6,
                                   defaultIntervalUnit: "months", notificationFireHour: 20,
                                   modifiedAt: t2)

        let data = try DataExporter.makeExport(from: ctx, settings: source, now: t2)
        let export = try DataImporter.decode(data)

        let peer = freshSettings("peer")   // epoch baseline → adopts source
        let peerCtx = try makeContext()
        try DataImporter.merge(export, into: peerCtx, settings: peer)

        XCTAssertEqual(peer.globalLeadTimeDays, 3)
        XCTAssertEqual(peer.defaultIntervalValue, 6)
        XCTAssertEqual(peer.defaultIntervalUnit, "months")
        XCTAssertEqual(peer.notificationFireHour, 20)
        XCTAssertEqual(peer.settingsModifiedAt, t2)
    }

    // MARK: Shared cross-platform fixture (same bytes as the Android test)

    func testReadsSharedSettingsSampleFixture() throws {
        // <repo>/MyInventoryTests/SettingsSyncTests.swift -> <repo>
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appending(path: "docs/fixtures/settings-sample.json")
        struct Wrapper: Decodable { let settings: DataExporter.SettingsDTO }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sample = try decoder.decode(Wrapper.self, from: Data(contentsOf: url))

        let export = DataExporter.Export(exportedAt: t2, contexts: [], settings: sample.settings)
        let ctx = try makeContext()
        let store = freshSettings()   // epoch baseline → adopts the sample
        let summary = try DataImporter.merge(export, into: ctx, settings: store)

        XCTAssertTrue(summary.settingsUpdated)
        XCTAssertEqual(store.globalLeadTimeDays, 14)
        XCTAssertEqual(store.defaultIntervalValue, 3)
        XCTAssertEqual(store.defaultIntervalUnit, "years")
        XCTAssertEqual(store.notificationFireHour, 8)
    }
}
