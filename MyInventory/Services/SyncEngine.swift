//
//  SyncEngine.swift
//  MyInventory
//
//  The orchestrator for S3 Part C (Google Drive auto-sync). It owns the sync cycle,
//  the observable `SyncState` the UI renders, and (later) the trigger policy. It holds
//  NO Google code — everything remote goes through `SyncTransport`, and everything
//  cryptographic through `SyncCipher`. See docs/S3_PartC_DriveSync_Design.md §2/§4/§6.
//
//  The cycle reuses the already-shipped pieces verbatim:
//    • `DataExporter.makeExport`      — canonical SCBK1 wire (with tombstones + settings)
//    • `SyncCipher`                   — SCBK1 E2EE (Argon2id + XChaCha20) in production
//    • `DataImporter.merge`           — Phase-2 LWW + tombstone + settings merge
//  Part C is only the thin loop that stitches them to a versioned remote blob.
//

import Foundation
import SwiftData
import CryptoKit

// MARK: - Observable state (design §6)

/// What the sync UI renders. `conflict` is transient (auto-retried) so it is not a
/// resting state — if retries exhaust it collapses into `.error(.driveError)`.
enum SyncState: Equatable {
    case signedOut
    case idle
    case syncing
    case synced(Date)
    case error(SyncError)
}

/// The reason a sync failed, mapped from `SyncTransportError` / a decrypt failure.
/// The UI turns each into an inline row (design §6) — never a modal nag.
enum SyncError: Equatable {
    case offline
    case authExpired
    /// The remote blob wouldn't decrypt with the configured key ("wrong passphrase
    /// for this Drive file").
    case decryptFailed
    case driveError(String)
}

// MARK: - Cipher seam

/// Turns plaintext export JSON into the ciphertext blob that travels to the remote,
/// and back. Production is `SCBK1SyncCipher` (Argon2id + XChaCha20, design §8); tests
/// inject a fast reversible cipher so engine tests don't pay the KDF cost.
protocol SyncCipher {
    func encrypt(_ plaintext: Data) throws -> Data
    func decrypt(_ ciphertext: Data) throws -> Data
}

/// The production cipher: an SCBK1 envelope per push, unlocked by the sync passphrase.
///
/// Per design §8 (the P1 fix) we hold the PASSPHRASE, not a salt-bound derived key:
/// `decrypt` re-derives the KEK from *each envelope's own* salt (via
/// `BackupCrypto.decryptWithPassphrase`), so a peer's newly-salted file always unwraps.
/// The stable-salt / memoized-KEK optimization (so identical content skips the Argon2
/// run) is deferred — the engine's content-digest short-circuit already means the KDF
/// only runs when the inventory actually changed.
struct SCBK1SyncCipher: SyncCipher {
    let passphrase: String

    func encrypt(_ plaintext: Data) throws -> Data {
        let json = String(decoding: plaintext, as: UTF8.self)
        let (envelope, _) = try BackupCrypto.encryptBackup(plaintextUtf8: json, passphrase: passphrase)
        return try BackupCrypto.serializeEnvelope(envelope)
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        let envelope = try BackupCrypto.parseEnvelope(ciphertext)
        let json = try BackupCrypto.decryptWithPassphrase(envelope, passphrase: passphrase)
        return Data(json.utf8)
    }
}

/// Thrown internally when a pulled blob can't be decrypted — normalizes any cipher
/// error into `.error(.decryptFailed)` regardless of the underlying crypto reason.
private struct SyncDecryptFailure: Error {}

// MARK: - Engine

@MainActor
@Observable
final class SyncEngine {

    private(set) var state: SyncState

    /// When the last successful sync completed (survives a later error, so the
    /// foreground trigger can tell whether we're stale). `nil` until the first sync.
    private(set) var lastSyncedAt: Date?

    private let transport: SyncTransport
    private let cipher: SyncCipher
    private let modelContext: ModelContext
    private let settings: SettingsStore?
    private let maxConflictRetries: Int
    private let now: () -> Date

    /// SHA-256 of the last content we pushed (with `exportedAt` normalized out — see
    /// `contentDigest`). Lets a no-op sync skip re-encrypting/uploading. `nil` until the
    /// first push this run: on a cold start we treat local as possibly-changed and let
    /// the `expectedVersion` guard + idempotent LWW merge keep that first upload safe.
    private var lastPushedDigest: Data?

    init(transport: SyncTransport,
         cipher: SyncCipher,
         modelContext: ModelContext,
         settings: SettingsStore?,
         signedIn: Bool = true,
         maxConflictRetries: Int = 5,
         now: @escaping () -> Date = { .now }) {
        self.transport = transport
        self.cipher = cipher
        self.modelContext = modelContext
        self.settings = settings
        self.maxConflictRetries = maxConflictRetries
        self.now = now
        self.state = signedIn ? .idle : .signedOut
    }

    /// Run one full sync pass. Idempotent, offline-safe: a transport failure leaves the
    /// store untouched and moves to `.error(_)`; the next trigger retries. Never throws
    /// — the outcome is reflected in `state` (and returned for callers/tests).
    @discardableResult
    func syncOnce() async -> SyncState {
        guard state != .signedOut else { return state }
        // Re-entrancy guard: the trigger policy (manual + foreground + debounced-dirty)
        // can fire overlapping syncs, and `syncOnce` suspends at every transport await.
        // Coalesce — a sync already in flight will pick up any just-made edits on its
        // next pass — so we never run two cycles against one store concurrently (which
        // would double-push and race `lastPushedDigest`). Checked synchronously before
        // the first await, so it is a reliable gate on the MainActor's serial executor.
        guard state != .syncing else { return state }
        state = .syncing
        do {
            let resolved = try await transport.resolveFile()
            try await runCycle(fileId: resolved.fileId, attempt: 0)
            let syncedAt = now()
            lastSyncedAt = syncedAt
            state = .synced(syncedAt)
        } catch let error as SyncTransportError {
            state = .error(Self.map(error))
        } catch is SyncDecryptFailure {
            state = .error(.decryptFailed)
        } catch {
            // A local export/merge/encode failure — surface it rather than swallow.
            state = .error(.driveError(error.localizedDescription))
        }
        return state
    }

    // MARK: Sign-in gate

    /// Enter the signed-in resting state. C-0 flips `signedOut → idle` so the wired
    /// transport becomes usable; C-1 replaces this with the real Google sign-in that
    /// obtains a token before flipping state.
    func signIn() {
        guard state == .signedOut else { return }
        state = .idle
    }

    /// Return to the signed-out state and forget per-session sync bookkeeping so a
    /// later re-sign-in starts clean (the next sync re-pulls and re-merges).
    func signOut() {
        pendingChangeTask?.cancel()
        pendingChangeTask = nil
        lastSyncedAt = nil
        lastPushedDigest = nil
        state = .signedOut
    }

    // MARK: Triggers (design §7)

    /// Manual trigger — the Settings "Sync now" button.
    @discardableResult
    func syncNow() async -> SyncState { await syncOnce() }

    /// Foreground trigger — sync when the app becomes active, but only if signed-in
    /// and we haven't synced within `staleAfter` (so re-opening a pad pulls the other's
    /// changes without hammering Drive on every quick switch). A no-op while syncing.
    func syncOnForegroundIfStale(staleAfter: TimeInterval = 120) async {
        guard state != .signedOut, state != .syncing else { return }
        if let last = lastSyncedAt, now().timeIntervalSince(last) < staleAfter { return }
        await syncOnce()
    }

    /// Debounced "after local edits" trigger — any mutation that bumps `modifiedAt`
    /// calls this; a coalescing timer fires one sync once edits settle, so a burst of
    /// changes (or keystrokes) produces a single push, not one per change. Same debounce
    /// idiom as the search `task(id:)` guard: a bare `try?` would fall through on
    /// cancellation and defeat the coalescing.
    func noteLocalChange(debounce: Duration = .seconds(15)) {
        guard state != .signedOut else { return }
        pendingChangeTask?.cancel()
        pendingChangeTask = Task { [weak self] in
            guard (try? await Task.sleep(for: debounce)) != nil else { return }
            await self?.syncOnce()
        }
    }

    /// The in-flight debounced-change timer, if any — exposed so tests can await the
    /// coalesced sync without a fixed sleep.
    private(set) var pendingChangeTask: Task<Void, Never>?

    /// One `resolveFile → pull → (decrypt+merge) → export → digest → encrypt → push`
    /// pass. On a push `Conflict` it re-pulls and recurses (bounded) — the merge is LWW
    /// + idempotent, so re-running converges.
    private func runCycle(fileId: String, attempt: Int) async throws {
        // 1–3: pull, then (if the remote isn't empty) decrypt + merge it into the store.
        let pulled = try await transport.pull(fileId: fileId)
        var remoteDigest: Data?
        if let remoteBytes = pulled.bytes {
            let plaintext: Data
            do { plaintext = try cipher.decrypt(remoteBytes) }
            catch { throw SyncDecryptFailure() }
            remoteDigest = try Self.contentDigest(of: plaintext)
            let incoming = try DataImporter.decode(plaintext)
            _ = try DataImporter.merge(incoming, into: modelContext, settings: settings)
        }

        // 4: export the (possibly merged) local store and take a stable content digest.
        let localJSON = try DataExporter.makeExport(from: modelContext, settings: settings, now: now())
        let localDigest = try Self.contentDigest(of: localJSON)

        // Short-circuit: nothing to upload if we already match what's on the remote
        // (converged this pass) or what we last pushed (no local change since).
        if localDigest == remoteDigest || localDigest == lastPushedDigest {
            lastPushedDigest = localDigest
            return
        }

        // 5–6: encrypt and conditionally push. A conflict means someone else pushed
        // between our pull and push — re-pull and re-merge, then retry.
        let cipherBytes = try cipher.encrypt(localJSON)
        do {
            _ = try await transport.push(fileId: fileId,
                                         bytes: cipherBytes,
                                         expectedVersion: pulled.version)
            lastPushedDigest = localDigest
        } catch SyncTransportError.conflict {
            guard attempt < maxConflictRetries else {
                throw SyncTransportError.transport("Sync kept colliding with another device — try again.")
            }
            try await runCycle(fileId: fileId, attempt: attempt + 1)
        }
    }

    // MARK: Helpers

    private static func map(_ error: SyncTransportError) -> SyncError {
        switch error {
        case .conflict:            return .driveError("Sync conflict could not be resolved.")
        case .authExpired:         return .authExpired
        case .offline:             return .offline
        case .transport(let msg):  return .driveError(msg)
        }
    }

    /// A stable SHA-256 over an export JSON with the volatile `exportedAt` normalized
    /// out (design §4.1). `DataExporter.makeExport` stamps `exportedAt = now`, so
    /// hashing the raw bytes would flip every call and defeat the no-op short-circuit.
    /// Decoding + re-encoding through our own canonical encoder also makes the digest
    /// comparable regardless of who produced the JSON (iOS vs Android formatting).
    static func contentDigest(of exportJSON: Data) throws -> Data {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DataExporter.Export.self, from: exportJSON)
        let normalized = DataExporter.Export(
            schemaVersion: decoded.schemaVersion,
            exportedAt: Date(timeIntervalSince1970: 0),
            contexts: decoded.contexts,
            settings: decoded.settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let canonical = try encoder.encode(normalized)
        return Data(SHA256.hash(data: canonical))
    }
}
