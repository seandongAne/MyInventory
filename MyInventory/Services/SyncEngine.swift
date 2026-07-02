//
//  SyncEngine.swift
//  MyInventory
//
//  The orchestrator for S3 Part C (Google Drive auto-sync). It owns the sync cycle,
//  the observable `SyncState` the UI renders, and the trigger policy (§7): manual,
//  foreground-if-stale, and the debounced after-local-edits trigger, which is armed
//  automatically from the main context's `didSave` (see init). It holds NO Google
//  code — everything remote goes through `SyncTransport`, and everything
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

    /// Set when a trigger fires while a cycle is already in flight. That cycle's export
    /// may have been taken BEFORE the edit that fired us, so dropping the trigger would
    /// strand the edit until the next foreground/manual sync — instead the completing
    /// pass runs exactly one follow-up `syncOnce()`.
    private var followUpRequested = false

    /// The in-flight sync pass. `signOut()` cancels it so a mid-flight cycle can never
    /// write a signed-in `.synced`/`.error` state after the user signed out.
    private var inFlightSync: Task<Void, Never>?

    /// True only while `runCycle` synchronously applies the remote merge — that
    /// `modelContext.save()` posts `didSave` like any user edit, but it is the cycle's
    /// own write, so the change observer must not re-arm a sync for it.
    private var isApplyingRemoteMerge = false

    /// Debounce used when the `didSave` observer arms `noteLocalChange` (design §7's
    /// "10–30 s idle"). Injectable so tests don't sleep 15 real seconds.
    private let changeDebounce: Duration

    /// `ModelContext.didSave` observation token. `nonisolated(unsafe)`: written once at
    /// the end of init, read only by the nonisolated deinit for removal.
    nonisolated(unsafe) private var saveObserver: (any NSObjectProtocol)?

    init(transport: SyncTransport,
         cipher: SyncCipher,
         modelContext: ModelContext,
         settings: SettingsStore?,
         signedIn: Bool = true,
         maxConflictRetries: Int = 5,
         changeDebounce: Duration = .seconds(15),
         now: @escaping () -> Date = { .now }) {
        self.transport = transport
        self.cipher = cipher
        self.modelContext = modelContext
        self.settings = settings
        self.maxConflictRetries = maxConflictRetries
        self.changeDebounce = changeDebounce
        self.now = now
        self.state = signedIn ? .idle : .signedOut

        // Trigger choke point (design §7 "after local edits": any mutation that bumps
        // `modifiedAt` marks the store dirty). Every user-facing mutation path saves
        // THIS main context — views, the notification "Mark as Checked" action, App
        // Intents, template apply, and backup restore — so its `didSave` is exactly
        // that dirty signal, with no per-call-site wiring to forget. Delivery is
        // synchronous on the posting (main) thread, so `assumeIsolated` is sound and
        // the `isApplyingRemoteMerge` window cannot race. A future save path that uses
        // its OWN ModelContext must call `noteLocalChange()` itself.
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: modelContext, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isApplyingRemoteMerge else { return }
                self.noteLocalChange()
            }
        }
    }

    /// Nonisolated for the same runtime reason as `FakeSyncTransport`/`SettingsStore`
    /// (the iOS 26.2 simulator isolated-deinit double-free); it only removes the
    /// thread-safe NotificationCenter token.
    nonisolated deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
    }

    /// Run one full sync pass. Idempotent, offline-safe: a transport failure leaves the
    /// store untouched and moves to `.error(_)`; the next trigger retries. Never throws
    /// — the outcome is reflected in `state` (and returned for callers/tests).
    @discardableResult
    func syncOnce() async -> SyncState {
        guard state != .signedOut else { return state }
        // Re-entrancy guard: the trigger policy (manual + foreground + debounced-dirty)
        // can fire overlapping syncs, and the cycle suspends at every transport await.
        // Coalesce so we never run two cycles against one store concurrently (which would
        // double-push). Checked synchronously before the first await, so it is a reliable
        // gate on the MainActor's serial executor. A coalesced trigger is queued, not
        // dropped: the in-flight cycle's export may predate the edit that fired us, so
        // the completing pass runs one follow-up (below).
        guard state != .syncing else {
            followUpRequested = true
            return state
        }
        state = .syncing
        // The pass runs in a tracked child task so `signOut()` can cancel it mid-flight.
        let pass = Task { await runSyncPass() }
        inFlightSync = pass
        await pass.value
        if inFlightSync == pass { inFlightSync = nil }
        if followUpRequested {
            followUpRequested = false
            if state != .signedOut { return await syncOnce() }
        }
        return state
    }

    /// One tracked pass: runs the cycle and writes the outcome through `finishPass`,
    /// which fences against a mid-flight `signOut()`.
    private func runSyncPass() async {
        do {
            let resolved = try await transport.resolveFile()
            try Task.checkCancellation()
            try await runCycle(fileId: resolved.fileId, attempt: 0)
            finishPass(.synced(now()))
        } catch is CancellationError {
            // `signOut()` cancelled the pass; it already put state/bookkeeping where
            // they belong — write nothing so the UI stays signed-out.
        } catch let error as SyncTransportError {
            finishPass(.error(Self.map(error)))
        } catch is SyncDecryptFailure {
            finishPass(.error(.decryptFailed))
        } catch {
            // A local export/merge/encode failure — surface it rather than swallow.
            finishPass(.error(.driveError(error.localizedDescription)))
        }
    }

    /// Write a pass's completion state — unless the pass was cancelled or the state
    /// moved on (sign-out mid-flight), in which case the outcome is stale and dropped.
    private func finishPass(_ outcome: SyncState) {
        guard !Task.isCancelled, state == .syncing else { return }
        if case .synced(let at) = outcome { lastSyncedAt = at }
        state = outcome
    }

    // MARK: Sign-in gate

    /// Enter the signed-in resting state — from a cold `signedOut` OR from
    /// `.error(.authExpired)`, where the UI renders a "Sign in again" button that must
    /// actually work. Every other state keeps its meaning. C-0 just flips the state so
    /// the wired transport becomes usable; C-1 replaces this with the real Google
    /// sign-in that obtains a token before flipping.
    func signIn() {
        switch state {
        case .signedOut, .error(.authExpired):
            state = .idle
        default:
            break
        }
    }

    /// Return to the signed-out state and forget per-session sync bookkeeping so a
    /// later re-sign-in starts clean (the next sync re-pulls and re-merges). Cancels
    /// the in-flight pass (and any queued follow-up) so a completing cycle can't snap
    /// the UI back to a signed-in state.
    func signOut() {
        inFlightSync?.cancel()
        inFlightSync = nil
        followUpRequested = false
        pendingChangeTask?.cancel()
        pendingChangeTask = nil
        lastSyncedAt = nil
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

    /// Debounced "after local edits" trigger — armed automatically by the main
    /// context's `didSave` observer (see init), so any mutation that bumps `modifiedAt`
    /// lands here; a coalescing timer fires one sync once edits settle, so a burst of
    /// changes (or keystrokes) produces a single push, not one per change. Same debounce
    /// idiom as the search `task(id:)` guard: a bare `try?` would fall through on
    /// cancellation and defeat the coalescing. `debounce: nil` uses `changeDebounce`.
    func noteLocalChange(debounce: Duration? = nil) {
        guard state != .signedOut else { return }
        let delay = debounce ?? changeDebounce
        pendingChangeTask?.cancel()
        pendingChangeTask = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
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
        // Fence (sign-out mid-flight): never merge into — or below, push from — a
        // store the user just signed out of.
        try Task.checkCancellation()
        var remoteDigest: Data?
        if let remoteBytes = pulled.bytes {
            let plaintext: Data
            do { plaintext = try cipher.decrypt(remoteBytes) }
            catch { throw SyncDecryptFailure() }
            remoteDigest = try Self.contentDigest(of: plaintext)
            let incoming = try DataImporter.decode(plaintext)
            // The merge's save posts `didSave` like any user edit; flag it so the
            // change observer doesn't re-arm a sync for the cycle's own write. The
            // window is purely synchronous (no awaits), so no user edit can land inside.
            isApplyingRemoteMerge = true
            defer { isApplyingRemoteMerge = false }
            _ = try DataImporter.merge(incoming, into: modelContext, settings: settings)
        }

        // 4: export the (possibly merged) local store and take a stable content digest.
        let localJSON = try DataExporter.makeExport(from: modelContext, settings: settings, now: now())
        let localDigest = try Self.contentDigest(of: localJSON)

        // Short-circuit: nothing to upload if local already matches what's on the
        // remote (converged this pass). This must compare against the REMOTE digest —
        // never a remembered "what we last pushed" — so a remote that regressed
        // out-of-band (e.g. a Phase-1 peer blindly overwriting the blob with stale
        // data) always gets a corrective re-push. Skipping because local "hasn't
        // changed since our last push" would leave the stale blob standing until the
        // next local edit, and a fresh device's first pull would adopt it.
        if localDigest == remoteDigest { return }

        // 5–6: encrypt and conditionally push. A conflict means someone else pushed
        // between our pull and push — re-pull and re-merge, then retry.
        let cipherBytes = try cipher.encrypt(localJSON)
        do {
            _ = try await transport.push(fileId: fileId,
                                         bytes: cipherBytes,
                                         expectedVersion: pulled.version)
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
