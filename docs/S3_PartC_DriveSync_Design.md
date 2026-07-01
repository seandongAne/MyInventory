# S3 Part C — Google Drive Auto-Sync — Engineering Design

Status: **DESIGN for discussion** (extends `SuppliesCheck_CrossPlatformSync_Plan.md` §8/§9)
Scope: both repos — iOS `MyInventory`, Android `supplies-check`.

Part A (Phase-2 LWW + tombstone merge) and Part B (settings synced singleton) are **done and
merged on both platforms**. Part C is the last piece of S3: turn the manual `.scbk` shuttle
into **in-app automatic sync against one file in the teacher's Google Drive**. This doc is the
engineering blueprint the main plan (§8.2) promised "at S3".

---

## 1. What Part C adds, and the OAuth boundary

Everything below the network line already exists and is reused **verbatim**:

| Layer | Status | Reused API |
|---|---|---|
| Canonical wire (SCBK1 JSON, tombstones, settings singleton) | ✅ done | `DataExporter.Export` / `assembleExport` |
| E2EE envelope (Argon2id + XChaCha20) | ✅ done (S2) | iOS `BackupCrypto.encryptBackup/decrypt…`; Android `crypto.encryptBackup/parseEnvelope` |
| LWW + tombstone + settings merge | ✅ done (Part A/B) | iOS `DataImporter.merge(_:into:)`; Android `planMerge(incoming, existing)` |

Part C is a **thin orchestration + transport layer on top of these** — plus the sign-in and
sync UI. Crucially, only *one seam* touches Google:

> **The OAuth boundary is a single interface: `SyncTransport`** (§3). Everything else — the sync
> loop, conflict handling, state machine, UI, token/key storage design, and the full test suite —
> is **buildable and testable NOW** against a `FakeTransport`. When the owner finishes the OAuth
> project (§8.2 of the main plan), the only new code is one concrete `DriveTransport` implementing
> that interface. This is the whole reason Part C can proceed while OAuth is owner-blocked.

---

## 2. Architecture

```
        ┌──────────────── existing (done) ────────────────┐
  UI ──▶ SyncEngine ──▶ [ export → encrypt ]  push ──▶ ┐
  ▲          │                                          │
  │          │          [ merge ← decrypt ]  ◀── pull ──┤
  │          ▼                                          ▼
  └── SyncState        ┌─────────── SyncTransport (the ONLY Google seam) ──────────┐
     (observable)      │  FakeTransport (tests / now)   │   DriveTransport (OAuth)  │
                       └────────────────────────────────┴──────────────────────────┘
```

- **`SyncEngine`** — platform-native orchestrator (iOS `@MainActor @Observable` service like
  `NotificationManager`; Android a small module + a React context/store). Owns the sync cycle,
  the state machine, and the trigger policy. Holds **no** Google code.
- **`SyncTransport`** — the abstraction (§3). One method to read the remote blob + its version
  tag, one to write it with an expected-version guard (optimistic concurrency), one to
  find-or-create the file. Two impls: `FakeTransport` (in-memory / local-file, for tests and
  local dev) and `DriveTransport` (Drive REST, added at OAuth time).
- **`SyncState`** — the observable status the UI renders (§6).

The engine never sees plaintext on the wire and never sees the Google password — it hands
ciphertext to the transport and reads ciphertext back.

---

## 3. The transport abstraction (`SyncTransport`)

The remote is a **dumb versioned blob store** for exactly one file. Modelled on Drive's REST
semantics (each file has a monotonic `generation` / an `ETag`; conditional update on it gives
optimistic concurrency) but with nothing Google-specific in the signature.

```
interface SyncTransport {
  // Locate (once) the single app-managed backup file; create it empty if absent.
  // Returns a stable handle + the current version tag (null if just created / empty).
  resolveFile(): { fileId, version | null }

  // Download ciphertext + the version it was at. null bytes = remote is empty (first sync).
  pull(fileId): { bytes | null, version | null }

  // Upload ciphertext ONLY IF the remote is still at expectedVersion; else reject with
  // a Conflict so the engine re-pulls and re-merges. Returns the new version.
  push(fileId, bytes, expectedVersion | null): { version }   // throws Conflict
}
```

- `version` is opaque to the engine (Drive `generation` for `DriveTransport`; a counter for
  `FakeTransport`).
- **`push` is conditional** — the `expectedVersion` guard is what makes two racing devices safe
  without locks: the loser gets `Conflict`, re-pulls, re-merges (merge is idempotent + LWW), and
  retries. No server-side logic needed — Drive's `If-Match`/generation precondition does it.
- Auth is *inside* the transport (it holds the token). The engine only ever gets `Conflict`,
  `AuthExpired`, `Offline`, or transport errors — never OAuth details.

---

## 4. The sync cycle

One `syncOnce()` pass, driven by the engine, reusing the done crypto + merge:

```
1. resolveFile()                      → fileId, remoteVersion
2. pull(fileId)                       → remoteCipher, remoteVersion
3. if remoteCipher == null:           // remote empty (first push ever)
      merged = localExport            // nothing to merge in
   else:
      remoteJson = decrypt(remoteCipher, syncKey)     // reuse S2 crypto
      merge(remoteJson → local store)                 // reuse Part A/B LWW+tombstone+settings
      merged     = export(local store)                // reuse assembleExport
4. digest = contentDigest(merged)                     // STABLE — excludes exportedAt (§4.1)
   localChanged = (digest != lastPushedDigest) || remoteCipher == null
   if !localChanged: DONE (already converged — pull-only, no upload)
5. cipher = encrypt(merged, syncKey)                  // reuse S2 crypto
6. push(fileId, cipher, expectedVersion = remoteVersion)
      on Conflict → goto 2 (bounded retries, e.g. 5)
7. record lastPushedDigest + lastSyncedAt; DONE
```

### 4.1 Change detection must ignore volatile metadata

`DataExporter.makeExport` stamps every export with `exportedAt: now` (Android's `assembleExport`
likewise), so a **byte-for-byte** compare of `merged` against the last snapshot would *always*
differ — every manual/foreground sync would re-encrypt and re-upload a new ciphertext even with
zero inventory edits, breaking the idempotence guarantee above and any conflict test built on it.
So step 4 compares a **stable content digest**, not the raw serialized export:

- `contentDigest(export)` = a hash (e.g. SHA-256) over the export **with `exportedAt` normalized
  out** (drop the field, or zero it, before hashing). Everything else — entities, `modifiedAt`,
  `deletedAt`, checks, the settings singleton — stays in, so any *real* change flips the digest.
- We never diff **ciphertext**: SCBK1 uses a fresh random nonce per encryption, so two encryptions
  of identical plaintext differ anyway. Change detection is always on the *plaintext* digest.
- `lastPushedDigest` is persisted per-device (alongside `lastSyncedAt`); on a cold start with an
  unknown digest we simply treat local as possibly-changed and let the `expectedVersion` guard +
  LWW merge keep the upload safe and idempotent.

Properties this gives us **for free** from the already-shipped pieces:
- **Idempotent** — re-running with no changes on either side uploads nothing (step 4 short-circuit)
  and never mutates data (LWW with equal `modifiedAt` is a no-op).
- **Order-independent / commutative-ish** — LWW by `modifiedAt` + append-only checks + monotonic
  tombstones mean A-then-B and B-then-A converge (subject to clock caveat §7).
- **Offline-safe** — a failed `pull`/`push` leaves local data untouched; the next trigger retries.
- **No plaintext leaves the device** — steps 5/6 upload ciphertext; step 2 downloads ciphertext.

"Merge into local store" is the platform's existing import path (iOS `DataImporter.merge` into the
`ModelContext`; Android `planMerge` → storage UPSERTs) — Part C calls it, doesn't reinvent it.

---

## 5. First sync / bootstrap

The one genuinely new UX flow (sign-in aside):

1. **Sign in** (§8.1 of the main plan) → token in secure storage.
2. **Establish the sync key** (§8) — first time, prompt once for the SCBK1 passphrase (or generate
   a fresh backup key + show the recovery key, exactly like S2's `EncryptedBackupSheet`); cache the
   derived key in the Keychain / EncryptedSharedPreferences so later syncs are silent.
3. **`resolveFile()`** — search Drive for the app's `inventory.scbk` (by `drive.file` visibility);
   if none, create it empty.
4. **First `syncOnce()`** — empty remote → local is pushed as-is; non-empty remote (the *other*
   device synced first) → two-way merge, then push the union. Either way both devices converge to
   the same file.

Edge: the two devices may have **independently created** two files before they ever met (both saw
an empty Drive). Mitigation: `resolveFile()` picks the **oldest** app-created `inventory.scbk` and,
if it finds more than one, merges the extras into it once then tombstones the duplicates from the
Drive listing (log it). Single-user, two-device: rare, but cheap to handle deterministically.

---

## 6. State machine + sync UI

Replace the hard-coded `LabeledContent("iCloud sync", value: "Local only")` in `SettingsView`
(and the Android Settings modal) with a real sync section driven by `SyncState`:

```
signedOut ──sign in──▶ idle ──trigger──▶ syncing ──ok──▶ synced(lastSyncedAt)
                          ▲                   │                    │
                          │              conflict(retry n)         │
                          │                   │                    ▼
                          └────────────◀── error(reason) ◀───── trigger…
```

| State | Settings UI |
|---|---|
| `signedOut` | "Sign in to Google Drive to sync" + button |
| `idle` / `synced(at)` | "Synced · <relative time>" + **Sync now** + account row + Sign out |
| `syncing` | spinner + "Syncing…" (Sync-now disabled) |
| `conflict(n)` | transient, usually invisible (auto-retried); only shown if retries exhaust |
| `error(reason)` | inline red row: offline / auth-expired (→ re-auth button) / decrypt-failed (→ "wrong passphrase for this Drive file", re-enter) / drive-error |

Rules (mirror the app's notification-error conventions): **never a modal nag**; surface failures
inline in Settings + optionally a one-shot local notification on a *background* sync failure
(like the "Mark as Checked" save-failure path). Success is silent (the data appearing IS the
confirmation, per the app's haptics/confirmation convention).

---

## 7. Trigger policy

When `syncOnce()` runs. Conservative, battery-friendly, no server push:

- **Manual** — the **Sync now** button (always available signed-in). Ships first.
- **On foreground** — sync on app-active if signed-in and `lastSyncedAt` is older than a short
  floor (e.g. > 2 min), so opening either pad pulls the other's changes.
- **After local edits** — a **debounced dirty flag**: any mutation that bumps `modifiedAt` marks
  the store dirty; a coalescing timer (e.g. 10–30 s idle, same debounce idiom as the search
  `task(id:)` guard) triggers a push-oriented sync. Avoids a sync per keystroke.
- **Background** — opportunistic only (iOS `BGAppRefreshTask`, Android WorkManager via Expo
  background-fetch), best-effort, not relied upon. Foreground + manual cover the real need for a
  two-device single user.

**Clock caveat (LWW):** `modifiedAt` LWW assumes roughly monotonic wall clocks across the two pads.
Acceptable for one owner's two devices; if a device's clock is badly wrong, a stale edit could win.
Not worth a vector clock here — but note it, and prefer the *device's own* `now` (not the remote's)
when stamping local edits, so a skewed remote can't poison future local writes.

---

## 8. Sync key & token storage

Two secrets, both kept **only** in platform secure storage — never in the synced file, never in
plain UserDefaults/AsyncStorage:

- **OAuth refresh/access token** (`drive.file` scope) → Keychain (iOS) / EncryptedSharedPreferences
  (Android). Managed by the `GoogleSignIn` SDK's own secure store where possible.
- **Sync key** (the SCBK1 data key / passphrase-derived key) → Keychain / EncryptedSharedPreferences,
  set once at first sync (§5.2). This is what lets background/foreground sync **decrypt without
  re-prompting**. It is the E2EE root: it stays on-device, Google never sees it, and losing it (with
  no recovery key) = unrecoverable — the same guarantee/warning as S2's manual backup.

**Decided: auto-sync reuses the S2 passphrase flow.** First sync prompts once for the SCBK1
passphrase (or generates a fresh key + shows the recovery key, exactly like `EncryptedBackupSheet`);
the derived key is then cached in the Keychain / EncryptedSharedPreferences so later
foreground/background syncs decrypt silently. Rationale: one mental model — the manual `.scbk` and
the auto-synced Drive file are the **same format and interchangeable**, so a user who already made a
manual backup can point sync at it. Both devices are unlocked once with the same passphrase/recovery
key. (Rejected: a device-independent auto-generated sync key surfaced only as a recovery key — it
decouples from the manual backup passphrase but forces the user to track a second secret.)

---

## 9. Error & edge cases (all handled in the engine, testable via `FakeTransport`)

| Case | Handling |
|---|---|
| Offline / transient network | `syncOnce` fails cleanly → `error(offline)`; data untouched; next trigger retries |
| Token expired | transport throws `AuthExpired` → `error(authExpired)` → re-auth button; refresh-token silent-renew first |
| Token revoked by user in Google | same path; sign-out state, re-sign-in |
| Concurrent write (two devices) | `push` `Conflict` → re-pull + re-merge + retry (bounded); LWW converges |
| Remote empty (first ever) | step 3 branch — push local as-is |
| Remote undecryptable (wrong key) | `error(decryptFailed)` → prompt to re-enter passphrase for this file; **never** overwrite the remote blindly |
| Corrupt/partial remote JSON | fail the pass, keep local, surface `error(driveError)`; do not push over it automatically |
| Duplicate `inventory.scbk` files | §5 — merge into oldest, tombstone extras, log |
| Drive quota / 5xx | bounded backoff retry, then `error(driveError)` |

---

## 10. Platform mapping

| Concern | iOS | Android |
|---|---|---|
| Sign-in | `GoogleSignIn` SDK → `ASWebAuthenticationSession` | `GoogleSignIn`/AppAuth → Custom Tabs |
| Drive REST | `URLSession` (files.list / create / get?alt=media / update with `If-Match`) | `fetch` |
| Secure store | Keychain | EncryptedSharedPreferences |
| Engine | `@MainActor @Observable SyncEngine` (peer of `NotificationManager`) | TS module + React context |
| Merge call | `DataImporter.merge(_:into: ModelContext)` | `planMerge` + storage UPSERTs |
| Crypto call | `BackupCrypto.encryptBackup / decryptWith…` | `crypto.encryptBackup / parseEnvelope` |
| Background | `BGAppRefreshTask` | Expo background-fetch / WorkManager |

---

## 11. Build order (non-blocked first)

**Phase C-0 — buildable NOW, no OAuth** (the bulk of the work + all the risk):
1. `SyncTransport` interface + `FakeTransport` (in-memory versioned blob, injectable Conflict).
2. `SyncEngine.syncOnce()` — the §4 cycle wired to the existing merge + crypto.
3. `SyncState` + the Settings sync section (§6) driven by the engine, using `FakeTransport`.
4. Trigger policy (§7): Sync-now button + foreground + debounced dirty flag.
5. Tests against `FakeTransport`: empty-remote, two-way merge, conflict-retry convergence, tombstone
   propagation, settings LWW over sync, decrypt-failed, offline, idempotent re-sync. Both platforms.

**Phase C-1 — OAuth-gated** (small, once the owner finishes §8.2):
6. `DriveTransport` implementing `SyncTransport` over Drive REST.
7. `GoogleSignIn` SDK wiring + token storage; replace `FakeTransport` with `DriveTransport` behind
   the same interface. No engine/UI changes.
8. Two-device on-device verification (the real end-to-end proof).

C-0 is ~80% of the effort and carries all the correctness risk; it lands and is fully tested before
a single Google credential exists. C-1 is a driver swap.

---

## 12. Relationship to task #17 (manual handoff verification)

Part C's C-1 on-device step **subsumes** the still-open two-device `.scbk` handoff verification: once
`DriveTransport` works, the two pads exchange the same encrypted file through Drive — which is the
manual handoff, automated. The manual-file interop can still be smoke-tested independently earlier
(it needs no OAuth), but C-1 is the durable proof.
