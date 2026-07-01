//
//  FakeSyncTransport.swift
//  MyInventory
//
//  The in-memory `SyncTransport` used by tests and local dev while the real
//  `DriveTransport` is OAuth-blocked (S3 Part C, design §3/§11). It models Drive's
//  contract exactly — one versioned blob, conditional writes — so the same
//  `SyncEngine` code path that runs here runs unchanged against Drive at C-1.
//
//  It also carries small fault-injection knobs so the engine's error/retry paths
//  (offline, auth-expired, conflict-then-recover) are exercised deterministically.
//

import Foundation

final class FakeSyncTransport: SyncTransport {

    private struct Stored: Equatable {
        var bytes: Data
        var version: SyncVersion
    }

    let fileId: String
    private var stored: Stored?
    private var counter = 0

    // MARK: Fault injection (tests). Each `failNext…` fires once then clears.
    var failResolve: SyncTransportError?
    var failNextPull: SyncTransportError?
    var failNextPush: SyncTransportError?
    /// When set, the NEXT `push` first simulates a competing device landing
    /// `concurrentBytes` (bumping the version) and throws `.conflict`, so the engine
    /// re-pulls that content, re-merges, and retries — the real two-device race.
    var conflictOnNextPushWith: Data?

    // MARK: Observability (tests)
    private(set) var resolveCount = 0
    private(set) var pullCount = 0
    private(set) var pushCount = 0

    init(fileId: String = "inventory.scbk", initialBytes: Data? = nil) {
        self.fileId = fileId
        if let initialBytes {
            counter += 1
            stored = Stored(bytes: initialBytes, version: String(counter))
        }
    }

    /// The current remote ciphertext (`nil` when empty) — for test assertions.
    var currentBytes: Data? { stored?.bytes }
    var currentVersion: SyncVersion? { stored?.version }

    func resolveFile() async throws -> ResolvedRemoteFile {
        resolveCount += 1
        if let failure = failResolve { failResolve = nil; throw failure }
        return ResolvedRemoteFile(fileId: fileId, version: stored?.version)
    }

    func pull(fileId: String) async throws -> PulledBlob {
        pullCount += 1
        if let failure = failNextPull { failNextPull = nil; throw failure }
        return PulledBlob(bytes: stored?.bytes, version: stored?.version)
    }

    func push(fileId: String, bytes: Data, expectedVersion: SyncVersion?) async throws -> PushOutcome {
        pushCount += 1
        if let failure = failNextPush { failNextPush = nil; throw failure }

        if let concurrent = conflictOnNextPushWith {
            conflictOnNextPushWith = nil
            counter += 1
            stored = Stored(bytes: concurrent, version: String(counter))
            throw SyncTransportError.conflict
        }

        // Optimistic-concurrency guard: accept only if the remote is still where the
        // caller last saw it (both nil ⇒ first push into an empty remote).
        guard expectedVersion == stored?.version else { throw SyncTransportError.conflict }

        counter += 1
        let version = String(counter)
        stored = Stored(bytes: bytes, version: version)
        return PushOutcome(version: version)
    }
}
