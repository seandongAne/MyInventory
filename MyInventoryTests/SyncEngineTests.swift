//
//  SyncEngineTests.swift
//  MyInventoryTests
//
//  S3 Part C-0: the OAuth-free sync core. Drives `SyncEngine.syncOnce()` against the
//  in-memory `FakeSyncTransport` (which models Drive's versioned-blob + conditional-write
//  contract) to prove the full cycle — pull → decrypt → merge → export → digest →
//  encrypt → push — including idempotence, two-way convergence, conflict recovery, the
//  error/state mapping, and one real end-to-end pass through the SCBK1 cipher.
//

import XCTest
import SwiftData
@testable import MyInventory

@MainActor
final class SyncEngineTests: XCTestCase {

    private var containers: [ModelContainer] = []
    override func tearDownWithError() throws { containers.removeAll() }

    private func makeStore() throws -> ModelContext {
        let container = try ModelContainer(
            for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return container.mainContext
    }

    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_800_000_000)
    private let fixedNow = Date(timeIntervalSince1970: 1_850_000_000)

    /// Seed one live context → category → item (6-month interval) with explicit uuids
    /// and `modifiedAt`. Returns the item name so callers can assert on it.
    @discardableResult
    private func seedItem(into ctx: ModelContext, name: String,
                          itemUUID: UUID = UUID(),
                          contextUUID: UUID = UUID(),
                          categoryUUID: UUID = UUID(),
                          modified: Date) throws -> String {
        let context = SupplyContext(name: "Ctx-\(name)")
        context.uuid = contextUUID; context.modifiedAt = modified
        ctx.insert(context)
        let category = SupplyCategory(name: "Cat-\(name)")
        category.uuid = categoryUUID; category.context = context; category.modifiedAt = modified
        ctx.insert(category)
        let item = SupplyItem(name: name, checkIntervalMonths: 6)
        item.uuid = itemUUID; item.category = category; item.modifiedAt = modified
        ctx.insert(item)
        try ctx.save()
        return name
    }

    private func liveItemNames(in ctx: ModelContext) throws -> Set<String> {
        Set(try ctx.fetch(FetchDescriptor<SupplyItem>()).map(\.name))
    }

    /// Serialized export of a throwaway store holding one item — used as "what the other
    /// device already put on the remote" (bytes are plaintext JSON under `PassthroughCipher`).
    private func remoteBlob(itemName: String, modified: Date) throws -> Data {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: itemName, modified: modified)
        return try DataExporter.makeExport(from: ctx, settings: nil, now: modified)
    }

    private func engine(_ transport: SyncTransport, _ ctx: ModelContext,
                        cipher: SyncCipher = PassthroughCipher(),
                        signedIn: Bool = true) -> SyncEngine {
        SyncEngine(transport: transport, cipher: cipher, modelContext: ctx,
                   settings: nil, signedIn: signedIn, now: { self.fixedNow })
    }

    // MARK: First sync

    func testFirstSyncPushesLocalIntoEmptyRemote() async throws {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: "Water", modified: t1)
        let transport = FakeSyncTransport()

        let state = await engine(transport, ctx).syncOnce()

        XCTAssertEqual(state, .synced(fixedNow))
        XCTAssertEqual(transport.pushCount, 1)
        XCTAssertEqual(transport.currentVersion, "1")
        let uploaded = try DataImporter.decode(XCTUnwrap(transport.currentBytes))
        XCTAssertTrue(uploaded.contexts.flatMap(\.categories).flatMap(\.items).contains { $0.name == "Water" })
    }

    // MARK: Idempotence

    func testSecondSyncWithNoChangesUploadsNothing() async throws {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: "Water", modified: t1)
        let transport = FakeSyncTransport()
        let sut = engine(transport, ctx)

        _ = await sut.syncOnce()
        let versionAfterFirst = transport.currentVersion
        let pushesAfterFirst = transport.pushCount

        _ = await sut.syncOnce()

        XCTAssertEqual(transport.pushCount, pushesAfterFirst, "a no-op sync must not re-upload")
        XCTAssertEqual(transport.currentVersion, versionAfterFirst)
    }

    // MARK: Pull + merge

    func testPullMergesRemoteWhenLocalEmptyAndDoesNotReupload() async throws {
        let transport = FakeSyncTransport(initialBytes: try remoteBlob(itemName: "Radio", modified: t1))
        let local = try makeStore()

        let state = await engine(transport, local).syncOnce()

        XCTAssertEqual(state, .synced(fixedNow))
        XCTAssertTrue(try liveItemNames(in: local).contains("Radio"))
        // Local now equals the remote → converged, so nothing is pushed back.
        XCTAssertEqual(transport.pushCount, 0)
        XCTAssertEqual(transport.currentVersion, "1")
    }

    func testTwoWayMergePushesUnion() async throws {
        let transport = FakeSyncTransport(initialBytes: try remoteBlob(itemName: "Radio", modified: t1))
        let local = try makeStore()
        try seedItem(into: local, name: "Water", modified: t1)

        _ = await engine(transport, local).syncOnce()

        // Local gained the remote's item…
        XCTAssertEqual(try liveItemNames(in: local), ["Water", "Radio"])
        // …and the remote gained ours (union pushed, version bumped).
        XCTAssertEqual(transport.pushCount, 1)
        XCTAssertEqual(transport.currentVersion, "2")
        let remote = try DataImporter.decode(XCTUnwrap(transport.currentBytes))
        let remoteNames = Set(remote.contexts.flatMap(\.categories).flatMap(\.items).map(\.name))
        XCTAssertEqual(remoteNames, ["Water", "Radio"])
    }

    // MARK: Remote regression (a peer overwrote the blob with stale data)

    /// A peer that blindly overwrites the remote with OLDER data (e.g. a Phase-1
    /// Android importer) must be corrected on the next sync: even though nothing
    /// changed locally since our last push, the divergent remote gets a corrective
    /// re-push of the newer local state. (Short-circuiting on a remembered
    /// last-pushed digest instead of the remote's would skip the push and leave the
    /// regression standing — a fresh device's first pull would then adopt it.)
    func testStaleRemoteOverwriteGetsCorrectiveRepush() async throws {
        let itemUUID = UUID(), contextUUID = UUID(), categoryUUID = UUID()
        let local = try makeStore()
        try seedItem(into: local, name: "Water v2", itemUUID: itemUUID,
                     contextUUID: contextUUID, categoryUUID: categoryUUID, modified: t2)
        let transport = FakeSyncTransport()
        let sut = engine(transport, local)

        _ = await sut.syncOnce()
        XCTAssertEqual(transport.pushCount, 1)

        // The peer regresses the remote to an older snapshot of the SAME entities.
        let staleStore = try makeStore()
        try seedItem(into: staleStore, name: "Water v1", itemUUID: itemUUID,
                     contextUUID: contextUUID, categoryUUID: categoryUUID, modified: t1)
        transport.overwriteRemote(
            bytes: try DataExporter.makeExport(from: staleStore, settings: nil, now: t1))

        let state = await sut.syncOnce()

        XCTAssertEqual(state, .synced(fixedNow))
        XCTAssertEqual(try liveItemNames(in: local), ["Water v2"],
                       "the stale remote must not clobber newer local state (LWW)")
        XCTAssertEqual(transport.pushCount, 2, "the divergent remote gets a corrective re-push")
        let remote = try DataImporter.decode(XCTUnwrap(transport.currentBytes))
        let remoteNames = Set(remote.contexts.flatMap(\.categories).flatMap(\.items).map(\.name))
        XCTAssertEqual(remoteNames, ["Water v2"], "the remote is healed back to the newer state")
    }

    // MARK: Conflict recovery

    func testConflictOnPushIsResolvedByRepullAndRetry() async throws {
        let transport = FakeSyncTransport()
        // A competitor lands "Radio" between our pull and push, so our first push
        // conflicts; the engine re-pulls Radio, merges it, and retries.
        transport.conflictOnNextPushWith = try remoteBlob(itemName: "Radio", modified: t1)
        let local = try makeStore()
        try seedItem(into: local, name: "Water", modified: t1)

        let state = await engine(transport, local).syncOnce()

        XCTAssertEqual(state, .synced(fixedNow))
        XCTAssertEqual(transport.pushCount, 2, "one conflicting push + one successful retry")
        XCTAssertEqual(transport.currentVersion, "2")
        XCTAssertEqual(try liveItemNames(in: local), ["Water", "Radio"])
        let remote = try DataImporter.decode(XCTUnwrap(transport.currentBytes))
        let remoteNames = Set(remote.contexts.flatMap(\.categories).flatMap(\.items).map(\.name))
        XCTAssertEqual(remoteNames, ["Water", "Radio"])
    }

    // MARK: Error → state mapping

    func testOfflineOnPullSurfacesErrorAndLeavesStoreUntouched() async throws {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: "Water", modified: t1)
        let transport = FakeSyncTransport()
        transport.failNextPull = .offline

        let state = await engine(transport, ctx).syncOnce()

        XCTAssertEqual(state, .error(.offline))
        XCTAssertEqual(transport.pushCount, 0)
        XCTAssertTrue(try liveItemNames(in: ctx).contains("Water"))
    }

    func testAuthExpiredOnResolveMapsToError() async throws {
        let ctx = try makeStore()
        let transport = FakeSyncTransport()
        transport.failResolve = .authExpired

        let state = await engine(transport, ctx).syncOnce()

        XCTAssertEqual(state, .error(.authExpired))
        XCTAssertEqual(transport.pullCount, 0)
    }

    func testTransportErrorOnPushMapsToDriveError() async throws {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: "Water", modified: t1)
        let transport = FakeSyncTransport()
        transport.failNextPush = .transport("boom")

        let state = await engine(transport, ctx).syncOnce()

        XCTAssertEqual(state, .error(.driveError("boom")))
    }

    func testUndecryptableRemoteMapsToDecryptFailed() async throws {
        let transport = FakeSyncTransport(initialBytes: Data("not a cipher blob".utf8))
        let local = try makeStore()

        let state = await engine(transport, local, cipher: ThrowingDecryptCipher()).syncOnce()

        XCTAssertEqual(state, .error(.decryptFailed))
        XCTAssertEqual(transport.pushCount, 0)
    }

    // MARK: Signed-out guard

    func testSignedOutSyncIsANoOp() async throws {
        let ctx = try makeStore()
        let transport = FakeSyncTransport()

        let state = await engine(transport, ctx, signedIn: false).syncOnce()

        XCTAssertEqual(state, .signedOut)
        XCTAssertEqual(transport.resolveCount, 0)
    }

    // MARK: Re-entrancy

    func testConcurrentSyncsCoalesceToOneUpload() async throws {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: "Water", modified: t1)
        let fake = FakeSyncTransport()
        let gated = GatedTransport(fake)   // parks the first cycle mid-flight
        let sut = engine(gated, ctx)

        // Fire the first sync and wait until it is genuinely parked inside the transport
        // (state == .syncing), then fire a second trigger: it must coalesce, not run.
        async let first = sut.syncOnce()
        await gated.awaitParked()
        let second = await sut.syncOnce()
        XCTAssertEqual(second, .syncing, "an overlapping trigger returns the in-flight state, no new cycle")

        await gated.release()
        let firstResult = await first
        XCTAssertEqual(firstResult, .synced(fixedNow))
        XCTAssertEqual(fake.pushCount, 1, "one cycle, one upload — the guard blocked the second")
    }

    // MARK: Triggers

    func testSignInSignOutTransitions() async throws {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: "Water", modified: t1)
        let sut = engine(FakeSyncTransport(), ctx, signedIn: false)

        XCTAssertEqual(sut.state, .signedOut)
        sut.signIn()
        XCTAssertEqual(sut.state, .idle)

        _ = await sut.syncNow()
        XCTAssertNotNil(sut.lastSyncedAt)

        sut.signOut()
        XCTAssertEqual(sut.state, .signedOut)
        XCTAssertNil(sut.lastSyncedAt, "sign-out clears per-session bookkeeping")
    }

    func testSyncNowRunsACycle() async throws {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: "Water", modified: t1)
        let transport = FakeSyncTransport()

        _ = await engine(transport, ctx).syncNow()

        XCTAssertEqual(transport.pushCount, 1)
    }

    func testForegroundSyncSkipsWhenRecentlySynced() async throws {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: "Water", modified: t1)
        let transport = FakeSyncTransport()
        let sut = engine(transport, ctx)

        _ = await sut.syncNow()                              // lastSyncedAt = fixedNow
        let pushes = transport.pushCount
        await sut.syncOnForegroundIfStale(staleAfter: 120)   // now == last → not stale

        XCTAssertEqual(transport.pushCount, pushes, "a recent sync isn't repeated on foreground")
    }

    func testForegroundSyncRunsWhenStale() async throws {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: "Water", modified: t1)
        let transport = FakeSyncTransport()
        var clock = fixedNow
        let sut = SyncEngine(transport: transport, cipher: PassthroughCipher(),
                             modelContext: ctx, settings: nil, signedIn: true, now: { clock })

        _ = await sut.syncNow()                              // lastSyncedAt = fixedNow
        clock = fixedNow.addingTimeInterval(300)             // 5 min later
        await sut.syncOnForegroundIfStale(staleAfter: 120)   // stale → syncs

        XCTAssertEqual(sut.state, .synced(clock))
        XCTAssertEqual(sut.lastSyncedAt, clock)
    }

    func testForegroundSyncIsNoOpWhenSignedOut() async throws {
        let ctx = try makeStore()
        let transport = FakeSyncTransport()
        let sut = engine(transport, ctx, signedIn: false)

        await sut.syncOnForegroundIfStale()

        XCTAssertEqual(sut.state, .signedOut)
        XCTAssertEqual(transport.resolveCount, 0)
    }

    func testDebouncedDirtyChangesCoalesceToOneSync() async throws {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: "Water", modified: t1)
        let transport = FakeSyncTransport()
        let sut = engine(transport, ctx)

        // A burst of edits: only the last timer survives, so one sync fires.
        sut.noteLocalChange(debounce: .milliseconds(20))
        sut.noteLocalChange(debounce: .milliseconds(20))
        sut.noteLocalChange(debounce: .milliseconds(20))
        await sut.pendingChangeTask?.value

        XCTAssertEqual(transport.pushCount, 1)
    }

    func testNoteLocalChangeIsIgnoredWhenSignedOut() async throws {
        let ctx = try makeStore()
        let sut = engine(FakeSyncTransport(), ctx, signedIn: false)

        sut.noteLocalChange(debounce: .milliseconds(20))

        XCTAssertNil(sut.pendingChangeTask, "no dirty timer while signed out")
    }

    // MARK: Content digest

    func testContentDigestIgnoresExportedAtButTracksContent() async throws {
        let ctx = try makeStore()
        try seedItem(into: ctx, name: "Water", modified: t1)
        let j1 = try DataExporter.makeExport(from: ctx, settings: nil, now: t1)
        let j2 = try DataExporter.makeExport(from: ctx, settings: nil, now: t2)
        XCTAssertEqual(try SyncEngine.contentDigest(of: j1),
                       try SyncEngine.contentDigest(of: j2),
                       "digest must ignore the volatile exportedAt stamp")

        try seedItem(into: ctx, name: "Radio", modified: t2)
        let j3 = try DataExporter.makeExport(from: ctx, settings: nil, now: t1)
        XCTAssertNotEqual(try SyncEngine.contentDigest(of: j1),
                          try SyncEngine.contentDigest(of: j3),
                          "a real content change must flip the digest")
    }

    // MARK: Real SCBK1 crypto round-trip (Argon2id — one slow end-to-end pass)

    func testRealCipherRoundTripBetweenTwoDevices() async throws {
        let passphrase = "correct horse battery staple"
        let cipher = SCBK1SyncCipher(passphrase: passphrase)
        let transport = FakeSyncTransport()

        // Device A encrypts + pushes.
        let deviceA = try makeStore()
        try seedItem(into: deviceA, name: "Water", modified: t1)
        _ = await engine(transport, deviceA, cipher: cipher).syncOnce()

        let blob = try XCTUnwrap(transport.currentBytes)
        XCTAssertEqual(try BackupCrypto.parseEnvelope(blob).format, "SCBK1", "the wire blob is a real SCBK1 envelope")

        // Device B (fresh, same passphrase) pulls + decrypts + merges.
        let deviceB = try makeStore()
        let stateB = await engine(transport, deviceB, cipher: cipher).syncOnce()
        XCTAssertEqual(stateB, .synced(fixedNow))
        XCTAssertTrue(try liveItemNames(in: deviceB).contains("Water"))

        // A device with the wrong passphrase can't unwrap the file.
        let deviceC = try makeStore()
        let stateC = await engine(transport, deviceC, cipher: SCBK1SyncCipher(passphrase: "wrong")).syncOnce()
        XCTAssertEqual(stateC, .error(.decryptFailed))
    }
}

// MARK: - Test ciphers

/// Identity cipher — keeps engine tests fast (no Argon2) and makes the fake remote's
/// "ciphertext" just the export JSON, so tests can build/read it directly.
private struct PassthroughCipher: SyncCipher {
    func encrypt(_ plaintext: Data) throws -> Data { plaintext }
    func decrypt(_ ciphertext: Data) throws -> Data { ciphertext }
}

/// Always fails to decrypt — exercises the `.error(.decryptFailed)` mapping.
private struct ThrowingDecryptCipher: SyncCipher {
    struct Boom: Error {}
    func encrypt(_ plaintext: Data) throws -> Data { plaintext }
    func decrypt(_ ciphertext: Data) throws -> Data { throw Boom() }
}

/// Wraps a `FakeSyncTransport` and PARKS the first `resolveFile` at a gate until
/// `release()` — lets a test hold one sync genuinely in-flight (the in-memory fake
/// otherwise never suspends) and fire a second concurrent trigger to prove the
/// engine's re-entrancy guard. `awaitParked()` is order-independent (returns
/// immediately if the gate was already reached).
private actor GatedTransport: SyncTransport {
    private let inner: FakeSyncTransport
    private var gate: CheckedContinuation<Void, Never>?
    private var reached: CheckedContinuation<Void, Never>?
    private var didReach = false

    init(_ inner: FakeSyncTransport) { self.inner = inner }

    func awaitParked() async {
        if didReach { return }
        await withCheckedContinuation { reached = $0 }
    }

    func release() { gate?.resume(); gate = nil }

    func resolveFile() async throws -> ResolvedRemoteFile {
        if !didReach {
            didReach = true
            reached?.resume(); reached = nil
            await withCheckedContinuation { gate = $0 }
        }
        return try await inner.resolveFile()
    }

    func pull(fileId: String) async throws -> PulledBlob {
        try await inner.pull(fileId: fileId)
    }

    func push(fileId: String, bytes: Data, expectedVersion: SyncVersion?) async throws -> PushOutcome {
        try await inner.push(fileId: fileId, bytes: bytes, expectedVersion: expectedVersion)
    }
}
