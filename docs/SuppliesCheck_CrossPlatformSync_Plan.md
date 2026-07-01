# Cross-Platform Encrypted Sync — Design Plan

Status: **DRAFT for discussion** (no code yet)
Scope: spans two repositories
- iOS — `MyInventory` (SwiftUI + SwiftData), bundle `CharlieW.MyInventory`
- Android — `supplies-check` (React Native / Expo + SQLite, TypeScript)

---

## 1. Goal & constraints

One inventory, shared across an **iPad (iOS)** and an **Android pad**, stored in the
**teacher's own Google Drive**, with **end-to-end encryption** so the cloud (and anyone
who obtains the file) sees only ciphertext — never what supplies the teacher owns.

Hard requirements:
- **E2EE**: encrypt on-device, upload only ciphertext, decrypt on-device. The storage
  provider must be a "dumb box."
- **Cross-platform**: both apps read/write the *same* data.
- **Privacy is the point**: a stolen backup must reveal nothing.

Owner preferences (already decided):
- Both repos are private and modifiable. The Swift codebase is the more solid/complete
  one, so **Android changes toward the iOS norm** (with one exception — see §4).
- Rollout: **manual first, automatic later.**
- Storage: **the teacher's own Google Drive.**

Dropped option: **CloudKit** (the old iOS M6 plan) — Apple-only, so it cannot serve the
Android side. We will not split the source of truth between CloudKit and Drive.

---

## 2. Current state — two divergent models

The two apps disagree on *what an inventory is*. This — not encryption or transport — is
the real risk. Naively importing one into the other silently drops data.

| Dimension | iOS (SwiftData) | Android (RN/SQLite) |
|---|---|---|
| Hierarchy | **4 levels**: Context → Category → Item → CheckRecord | **2 levels**: Checklist → Item |
| Check history | full `CheckRecord` history (date + result + comment) | one `lastCheckedDate` string, **no history** |
| Interval | `checkIntervalMonths: Int?` (**months only**; nil = never) | `intervalValue` + `intervalUnit` (days/months/years) + `neverExpires` |
| Extra fields | `quantity`, `photo`, `storageLocation`, `leadTimeDaysOverride` | `notes` only |
| Stable id | `uuid` | `id` (string) — ✅ both have one |
| Notifications | batched by day + attention digest + inactivity nudge | per-item dueSoon/due, tagged by `itemId` |

Default contexts already line up (`Vehicle / Bag / House`), which helps.

---

## 3. Strategy — converge the models, don't bridge them

Two ways to make heterogeneous clients share data:

- **Bridge**: keep both native models, define a neutral interchange format, write two
  mappers, and have each app *pass through* fields it doesn't understand. Less change
  now, but permanent complexity and an ongoing data-loss risk on every schema change.
- **Converge** (chosen): make the two native models the **same shape**. Then the sync
  format *is* the model — no mappers, no pass-through, the smallest possible sync.

Because Android is the user's private repo and the less complete app, convergence is the
right call. The "norm" we converge to is **≈ the iOS model, plus `intervalUnit` borrowed
from Android, plus `notes` promoted to both**.

Key principle that lets us stage the work: **data parity ≠ UI parity.** Android will
*store* the full schema (categories, check history, quantity, …) so sync is lossless,
even while its **UI keeps showing a simpler subset** at first. UI can catch up later.

---

## 4. The shared canonical schema — v1

This is the contract. Both native models converge to it; the encrypted file is exactly
this JSON. Versioned so it can evolve.

```jsonc
{
  "schemaVersion": 1,
  "exportedAt": "2026-06-28T12:00:00Z",   // ISO-8601 UTC
  "contexts": [
    {
      "uuid": "…",
      "name": "Vehicle",
      "sortOrder": 0,
      "createdAt": "…",
      "modifiedAt": "…",                   // for Phase-2 LWW; populated from now on
      "categories": [
        {
          "uuid": "…",
          "name": "Uncategorized",
          "sortOrder": 0,
          "createdAt": "…",
          "modifiedAt": "…",
          "items": [
            {
              "uuid": "…",
              "name": "4L water",
              "intervalValue": 1,          // null = never expires (iOS convention)
              "intervalUnit": "months",    // "days" | "months" | "years"
              "leadTimeDaysOverride": null,
              "quantity": null,
              "storageLocation": null,
              "notes": "Rotate monthly",
              "createdAt": "…",
              "modifiedAt": "…",
              "checks": [
                {
                  "uuid": "…",
                  "date": "2026-06-28",     // calendar date
                  "result": "ok",          // "ok" | "replaced" | "needsAttention"
                  "comment": null,
                  "createdAt": "…"
                }
              ]
            }
          ]
        }
      ]
    }
  ],
  "settings": {                          // synced singleton, whole-object LWW by modifiedAt
    "globalLeadTimeDays": 7,
    "defaultIntervalValue": 12,
    "defaultIntervalUnit": "months",
    "notificationFireHour": 9,
    "modifiedAt": "…"
  }
}
```

Reconciliation decisions baked in:
- **Interval** = `{intervalValue, intervalUnit}`. `intervalValue: null` means *never
  expires* (single source of truth; replaces Android's separate `neverExpires` bool and
  iOS's `nil` months). `intervalUnit` is retained even when null, for round-trip
  stability.
- **`notes`** is promoted to a first-class per-item field on **both** platforms (iOS
  gains it; `storageLocation` stays separate — different meaning).
- **Check history** is canonical. Android's single `lastCheckedDate` becomes a *derived*
  value = the latest non-deleted check.
- **`result`** keeps iOS's three values. Android only ever writes `"ok"` but must
  preserve/display the others.
- **Sync metadata**: every entity carries `modifiedAt` from v1 (cheap, forward-looking).
  Soft-delete `deletedAt` is added in **Phase 2** only (Phase-1 merge is additive and
  doesn't need it).
- **Settings** sync as a singleton object (`globalLeadTimeDays`,
  `defaultIntervalValue/Unit`, `notificationFireHour`) with its own `modifiedAt`
  (whole-object LWW). iOS already has these; **Android must add storing + applying them**
  (today its lead window and reminder hour are hard-coded constants).

**Not in the schema** (intentionally local-only, never synced): notifications &
`notificationIds`, **photos** (too large), and per-device settings/reminder scheduling.
Each platform keeps its own notification engine, fed from the synced data.

---

## 5. iOS model changes + migration

Model (`Models/`):
- `SupplyItem`: replace `checkIntervalMonths: Int?` with `intervalValue: Int?` +
  `intervalUnit: String` (default `"months"`); add `notes: String?`; add
  `modifiedAt: Date`.
- `SupplyContext`, `SupplyCategory`, `CheckRecord`: add `modifiedAt: Date`.
- (Phase 2) add `deletedAt: Date?` to all four — see §9.

Logic:
- `SupplyStatus.swift`: `nextDueDate` must compute for **days/months/years**, not just
  months. Port the calendar math from Android `src/domain.ts` (`addInterval`, with
  end-of-month day clamping) so both platforms compute identical due dates.
- `ItemEditView` / `PresetValuePicker`: interval gains a unit selector.
- `DataExporter` / `DataImporter` DTOs: swap `checkIntervalMonths` →
  `intervalValue`+`intervalUnit`, add `notes`, add `modifiedAt`. (The importer is
  **already** an additive uuid-keyed merge — that is exactly the Phase-1 merge.)
- `SettingsStore`: `defaultIntervalMonths` → `defaultIntervalValue` + `defaultIntervalUnit`;
  these plus `globalLeadTimeDays` and `notificationFireHour` become the synced settings
  singleton.
- `ItemEditView`: add the per-item **notes** editing field (decision #4).

Migration (SwiftData):
- Introduce a versioned schema (V1 → V2) with a `MigrationPlan` custom stage:
  - `intervalValue = checkIntervalMonths`, `intervalUnit = "months"`.
  - `modifiedAt = createdAt` (or migration timestamp).
  - `notes = nil`.
- Keep models CloudKit-safe regardless (all optional/defaulted, explicit inverses) — the
  existing invariants still apply.

---

## 6. Android model changes + migration

This is the larger lift (Android levels up to data parity). SQLite schema migration:

- **`contexts`** (rename from `checklists`): `id, name, sort_order, created_at,
  modified_at`. Migrate existing checklist rows 1:1.
- **`categories`** (new): `id, context_id, name, sort_order, created_at, modified_at`.
  Migration creates one `"Uncategorized"` category per context and assigns that context's
  items to it.
- **`items`** (extend): add `category_id` (FK), `quantity`, `storage_location`,
  `lead_time_days_override`, `created_at`, `modified_at`. Switch never-expires to the
  canonical convention (`interval_value IS NULL`); drop the `never_expires` column and
  update `domain.ts` (`neverExpires = intervalValue == null`). Keep `interval_value`,
  `interval_unit`, `notes`, `notification_ids_json` (the last stays local-only).
- **`check_records`** (new): `id, item_id, date, result, comment, created_at`. Migration
  converts each item's `last_checked_date` into one `{result:"ok"}` check row, then drops
  `last_checked_date`. `lastChecked` becomes derived = `MAX(date)` over an item's checks.

Logic:
- `storage.ts`: `loadSnapshot` joins checks; `upsertItem`/`deleteItem` updated; add
  category CRUD + check insertion. All writes stamp `modified_at`.
- `domain.ts`: `getItemStatus` reads the derived last-checked date; `neverExpires`
  derives from null interval.
- `App.tsx`: **`markChecked` inserts a new `check_record`** (today, `"ok"`) instead of
  overwriting `last_checked_date`. UI can stay flat (one implicit category per program)
  for now — store-only parity is enough for sync.
- **Settings** (decision #5): add a stored settings singleton and *apply* it — the
  hard-coded `DUE_SOON_DAYS` and reminder hour become the synced `globalLeadTimeDays` /
  `notificationFireHour`; the add-item form uses the synced default interval. A settings
  *editing* UI on Android can follow later (data parity first).

---

## 7. Encryption (E2EE) — Phase 1

Encrypt the canonical JSON into a small, versioned, cross-platform container.

**Envelope encryption** (so the passphrase isn't the only key):
1. Generate a random 256-bit **data key (DK)**; encrypt the JSON with DK (AEAD).
2. Derive a **key-encryption-key (KEK)** from the passphrase via a slow KDF; wrap DK with KEK.
3. Generate a printable **recovery key**; wrap DK with it too.
4. Either the passphrase *or* the recovery key can unwrap DK → decrypt.

Container `SCBK1` layout (conceptual):
`magic | version | kdf-params(salt, cost) | passphrase-wrapped-DK | recovery-wrapped-DK | nonce | ciphertext+tag`

**Decided (#1): libsodium** — `crypto_pwhash` (Argon2id) + XChaCha20-Poly1305, via
`swift-sodium` (iOS) and `react-native-libsodium` (Android): one audited implementation on
both sides. (Rejected: platform AES-256-GCM + PBKDF2 — lighter deps but a weaker KDF.)

⚠️ E2EE means **a lost passphrase = unrecoverable data**. The recovery key is mandatory
UX: show it once, tell the teacher to write it down / store in a password manager.

**Golden test vectors** (checked into both repos): fixed plaintext + passphrase + salt +
nonce → identical ciphertext, and each app must decrypt the other's output. Turns
"hopefully interoperable" into a tested guarantee.

---

## 8. Transport — the teacher's Google Drive

- **Phase 1 (manual)**: write the `.scbk` file and hand it to the OS share sheet — iOS
  `ShareLink` (already used by `DataExporter`), Android share intent / Storage Access
  Framework. Save into Drive on one pad; open it on the other via the file picker. This
  already works cross-platform today, fully E2EE.
- **Phase 2 (automatic)**: in-app Google Drive REST managing a single app-created file
  `inventory.scbk` in the teacher's Drive (`drive.file` scope — see §8.1). Sync cycle:
  `download → decrypt → merge → encrypt → upload`, using Drive's ETag/version for
  optimistic concurrency (re-pull-and-merge on conflict). Google sees only ciphertext.
  (The file is a normal, user-visible Drive file rather than a hidden `appDataFolder`
  blob — a deliberate trade for the `drive.file` scope's zero-verification path below.)

### 8.1 Google account auth — system auth session, never an embedded webview

The teacher signs in with their Google account to reach Drive. **The account password is
never entered in our own UI**, and we must not try to: since 2016 Google **blocks OAuth
from embedded webviews** (`WKWebView` / Android `WebView`) — such requests fail with the
`disallowed_useragent` error. Rationale: training users to type Google credentials into an
arbitrary app's text fields is exactly the phishing vector Google closes; embedded entry
also breaks 2FA, passkeys, already-signed-in SSO, and password-manager autofill, which
only work in a real browser context.

The supported mechanism is a **system-managed in-app auth session** — a secure browser
sheet hosted *over* the app, NOT a jump out to the external browser app:
- **iOS**: `ASWebAuthenticationSession` (what the official `GoogleSignIn` SDK uses). A
  sheet slides up; because it shares Safari's cookies the teacher is usually already
  signed in → one tap "Continue as …" returns to the app.
- **Android**: Chrome **Custom Tabs** via `GoogleSignIn` / AppAuth — the same in-app
  overlay tab.

We use the official **`GoogleSignIn` SDK on both platforms**; it wraps the auth session,
the token exchange, and refresh-token storage. We request only the **`drive.file`** scope
and receive a scoped OAuth access/refresh token — **never the password**. `drive.file` is
**non-sensitive**, so the OAuth app can publish to **Production with no Google
verification**, and refresh tokens don't expire on the 7-day "Testing"-status clock — the
right fit for a single-user personal app. (It grants access only to files this app creates
or the user opens with it — exactly our one `inventory.scbk`; the trade vs the hidden
`drive.appdata` folder is that the file is visible in the teacher's Drive, which for an
E2EE backup is acceptable, even convenient.)

> Two distinct secrets — do not conflate (this is *why* in-app credential entry is wrong
> for one but right for the other):
> - **Google account auth** (to reach Drive) → OAuth via the system sheet above; we never
>   see the password. In-app/embedded entry is rejected.
> - **SCBK1 backup passphrase** (to decrypt the `.scbk`, §7) → this IS typed into our own
>   app UI, by design: it is the E2EE key, never leaves the device, and Google never sees
>   it. (Already implemented in S2.)

Operational prerequisite for Phase 2: a Google Cloud project with OAuth consent screen and
per-platform OAuth client IDs (iOS + Android), set up under the **teacher's own Google
account** — the owner's task (§13 #6). Concrete steps in §8.2.

### 8.2 OAuth project setup checklist (owner task)

Done once at [console.cloud.google.com](https://console.cloud.google.com) under the
teacher's **own Google account** (the account whose Drive holds the `.scbk`). Identifiers:
iOS bundle `CharlieW.MyInventory`, Android package `com.suppliescheck`.

1. **Project + Drive API** — New Project (e.g. `MyInventory Sync`) → APIs & Services →
   Library → enable **Google Drive API**.
2. **OAuth consent screen** — User Type **External**; fill app name + user-support email +
   developer-contact email (logo / URLs optional); add **only** the `.../auth/drive.file`
   scope; then **PUBLISH APP → Production**.
   - Publishing to Production is **mandatory**: `drive.file` is non-sensitive, so this needs
     **no Google review** and takes effect immediately, AND it is what stops refresh tokens
     expiring on the 7-day *Testing*-status clock (§8.1). Confirmed against Google docs
     (2026-06).
   - Do **NOT** add `drive` / `drive.appdata` — those are sensitive/restricted and trigger
     verification (CASA). Showing the app's name+logo on the consent screen needs a separate
     lightweight *brand verification*; skipping it still works (plainer consent screen) and
     is fine for single-user use.
3. **OAuth client IDs** (APIs & Services → Credentials → Create OAuth client ID):
   - **iOS** — type iOS, Bundle ID `CharlieW.MyInventory`. Record the **Client ID** and the
     **reversed client ID** (`com.googleusercontent.apps.…`, used as the app's URL scheme).
   - **Android** — type Android, package `com.suppliescheck`, plus the **SHA-1** of the
     keystore that signs the *installed* apk (mismatch → `DEVELOPER_ERROR`). Debug builds:
     `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass
     android -keypass android | grep SHA1`; EAS builds: `eas credentials`.
   - No **Web application** client is needed — the apps call Drive REST with on-device access
     tokens.
4. **Hand back** (all public, embeddable — no secrets): iOS Client ID + reversed client ID,
   Android Client ID, and confirmation the Drive API is enabled and the consent screen is in
   Production.

---

## 9. Merge semantics

- **Phase 1 — additive.** Keyed by `uuid`, union only: adds what's missing, never
  overwrites or deletes. iOS `DataImporter` already behaves this way; Android implements
  the same. Safe to run without a destructive warning. (Limitation: edits and deletes do
  **not** propagate yet.)
- **Phase 2 — last-write-wins + tombstones.**
  - Per-entity LWW by `modifiedAt` (newest wins).
  - Deletes become **tombstones** via `deletedAt`; the tombstone propagates and is
    filtered from all queries/UI.
  - `checks` are append-only — merge by uuid union (no LWW needed).
  - **Settings** singleton merges by whole-object LWW on its `modifiedAt`.
  - Tombstones use a **`deletedAt` soft-delete column** (decision #3), filtered in all
    queries with app-level cascade. This changes the iOS "hard delete" invariant, so it's
    deliberately deferred to Phase 2.

---

## 10. Milestones

| ID | Deliverable | Repos |
|---|---|---|
| **S0** | This plan; resolve the open decisions in §13 | docs |
| **S1** | **Schema convergence** — both apps migrate to the canonical shape (§4) with data migrations; still standalone, no sync. Includes iOS notes UI (#4) and Android storing + applying synced settings (#5). Shared fixtures prove `getItemStatus`/`nextDueDate` match across days/months/years. | both |
| **S2** | **Phase 1 — E2EE manual backup** — encrypted `.scbk` export/import on both sides (§7), additive merge (§9), golden crypto vectors, round-trip test, manual Drive shuttle. **← delivers the teacher's privacy + cross-platform backup need.** | both |
| **S3** | **Phase 2 — auto-sync** — `modifiedAt` LWW + tombstones (§9) + Google Drive API auto push/pull (§8). | both |

S1 deliberately lands first and de-risks the hardest part (the schema contract) while
it's still just local migrations — before any crypto or network is involved.

---

## 11. Cross-repo working model

- **Branching**: cut feature branches from `main` in **both** repos (the local Android
  checkout is currently on the stale `tech-debt-fixes`, fully merged into `main`). Land
  coordinated PRs that bump the same `schemaVersion` and share crypto constants.
- **Shared spec**: mirror this doc into the Android repo's `docs/` when work starts.
- **Shared fixtures**: a canonical sample document + crypto vectors checked into both
  repos, consumed by both test suites.
- **Verification on this Mac**: iOS via `xcodebuild`; Android *logic* via `tsx` unit
  tests (Node). The Android **APK** still builds on the owner's Windows toolchain
  (`scripts/*.ps1`).

---

## 12. Risk summary

- Biggest risk is the **schema convergence + migrations** (data loss if a migration is
  wrong) — mitigated by landing S1 alone, with tests, and backups before migrating.
- Crypto interop bugs — mitigated by **golden vectors** tested both ways.
- Lost passphrase — mitigated by the **recovery key**.
- Drive OAuth/setup friction (Phase 2) — operational, isolated to S3.

---

## 13. Decisions (resolved)

1. **Crypto** — ✅ **libsodium** (Argon2id + XChaCha20-Poly1305) on both sides.
2. **Android never-expires** — ✅ **fully converge to `interval_value IS NULL`** (drop the
   `never_expires` bool; update `domain.ts`).
3. **Tombstones (Phase 2)** — ✅ **`deletedAt` soft-delete column**, filtered in all
   queries, app-level cascade. (Finalizable at S3.)
4. **iOS `notes`** — ✅ **add the editing UI now** (lands in S1).
5. **Settings sync** — ✅ **synced** as a singleton (§4 / §9). Android gains stored +
   applied settings; an Android settings editing UI may follow later.
6. **Storage / OAuth** — ✅ **Google Drive**, the teacher's own. Sign-in uses the official
   **`GoogleSignIn` SDK** via the system auth session (`ASWebAuthenticationSession` on iOS
   / Custom Tabs on Android); **embedded-webview / in-app password entry is rejected** —
   Google blocks it (`disallowed_useragent`, policy since 2016) and it's a phishing
   anti-pattern (§8.1). Scope = **`drive.file`** only (non-sensitive → Production with **no
   verification** + non-expiring refresh tokens; the backup is one app-created, user-visible
   Drive file, not a hidden `appDataFolder` blob); we never see the password. The Phase-2
   Google Cloud OAuth project is the **owner's task** (needs the teacher's Google account);
   a step-by-step will be provided at S3.
```
