//
//  SyncTransport.swift
//  MyInventory
//
//  The ONE seam that touches Google (S3 Part C). See
//  docs/S3_PartC_DriveSync_Design.md §3.
//
//  The remote is modelled as a DUMB versioned single-blob store: read the blob +
//  its opaque version tag, write it back only if the remote is still at the version
//  we last saw (optimistic concurrency). Nothing in this file is Google-specific —
//  `SyncEngine` drives it, `FakeSyncTransport` implements it for tests/local dev now,
//  and a `DriveTransport` (added at C-1, once the owner's OAuth project exists) is the
//  only new code the real backend needs. Auth lives INSIDE the transport (it holds the
//  token); the engine only ever sees the errors below, never OAuth details.
//

import Foundation

/// Opaque version tag for the single remote blob — Drive's `generation` / an `ETag`
/// for `DriveTransport`, a monotonic counter for `FakeSyncTransport`. The engine never
/// interprets it; it only round-trips it back as `expectedVersion` on the next push.
typealias SyncVersion = String

/// A located remote file + the version it is currently at (`nil` when just created
/// / still empty).
struct ResolvedRemoteFile: Equatable {
    let fileId: String
    let version: SyncVersion?
}

/// The result of a `pull`: the ciphertext blob (`nil` ⇒ remote is empty, i.e. the
/// first sync ever) and the version it was read at.
struct PulledBlob: Equatable {
    let bytes: Data?
    let version: SyncVersion?
}

/// The result of a successful `push`: the new version the remote is now at.
struct PushOutcome: Equatable {
    let version: SyncVersion
}

/// The only failures the transport surfaces to the engine. Nothing Google-specific
/// leaks past this boundary — `SyncEngine` maps each to a `SyncState`.
enum SyncTransportError: Error, Equatable {
    /// The remote moved past `expectedVersion` (another device pushed first). The
    /// engine re-pulls, re-merges (merge is idempotent + LWW), and retries.
    case conflict
    /// The auth token is missing/expired/revoked → the UI offers re-auth.
    case authExpired
    /// No network → data is left untouched; the next trigger retries.
    case offline
    /// Anything else the backend threw (Drive 5xx / quota / unexpected).
    case transport(String)
}

/// The remote-storage abstraction. One call to find-or-create the single app-managed
/// file, one to read it, one to conditionally write it. See design §3.
protocol SyncTransport {
    /// Locate (once) the single app-managed backup file; create it empty if absent.
    func resolveFile() async throws -> ResolvedRemoteFile

    /// Download ciphertext + the version it was at. `bytes == nil` ⇒ remote empty.
    func pull(fileId: String) async throws -> PulledBlob

    /// Upload ciphertext ONLY IF the remote is still at `expectedVersion`, else throw
    /// `SyncTransportError.conflict`. `expectedVersion == nil` means "write only if the
    /// remote is still empty" (the first-ever push). Returns the new version.
    func push(fileId: String, bytes: Data, expectedVersion: SyncVersion?) async throws -> PushOutcome
}
