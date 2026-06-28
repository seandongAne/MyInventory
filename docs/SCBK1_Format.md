# SCBK1 — Supplies-Check Encrypted Backup container (v1)

Status: **STABLE contract** (S2). Shared by iOS `MyInventory` and Android `supplies-check`.
The `.scbk` file is the cross-platform, end-to-end-encrypted backup. The cloud (Google
Drive) only ever holds this ciphertext — it never sees the inventory.

This is the byte-level interop contract. Golden vectors that pin every crypto output live
in `docs/fixtures/scbk1-vectors.json`; a real encrypted sample is
`docs/fixtures/scbk1-sample.scbk`. Both test suites assert against these (kept
byte-identical in both repos).

---

## 1. Primitives (libsodium)

| Role | Primitive | libsodium |
|---|---|---|
| Password KDF | Argon2id v1.3 | `crypto_pwhash` with `crypto_pwhash_ALG_ARGON2ID13` |
| AEAD (payload + key-wrap) | XChaCha20-Poly1305-IETF | `crypto_aead_xchacha20poly1305_ietf_encrypt/decrypt` |

One audited implementation on both sides: **swift-sodium** (iOS) and
**react-native-libsodium** (Android). Node tests use **libsodium-wrappers-sumo**.

Fixed sizes: salt **16** bytes (`crypto_pwhash_SALTBYTES`), every nonce **24** bytes
(`..._NPUBBYTES`), every symmetric key **32** bytes (`..._KEYBYTES`). AEAD output is
`ciphertext ‖ 16-byte tag`.

## 2. KDF parameters — FIXED, not device-tuned

```
algorithm = argon2id13
opslimit  = 3
memlimit  = 67108864   (64 MiB)
```

These are baked into every file (and re-stated in the envelope) so **any** device can
decrypt — including the low-RAM Galaxy Tab A7 Lite. Do NOT derive them from
`*_OPSLIMIT_INTERACTIVE`-style device tuning. 64 MiB keeps Argon2 affordable on an 8.7"
tablet while staying well above PBKDF2-class cost.

## 3. Envelope encryption (two ways to unlock)

```
DK  = 32 random bytes                         # the data key — encrypts the inventory
KEK = crypto_pwhash(32, passphrase, salt, opslimit, memlimit, ARGON2ID13)
RK  = 32 random bytes                          # recovery key (shown to the user as base32)

payload   = AEAD(plaintextJSON, payloadNonce, DK)
wrap.pass = AEAD(DK,            wrapPassNonce, KEK)   # passphrase unlocks DK
wrap.rec  = AEAD(DK,            wrapRecNonce,  RK)    # recovery key also unlocks DK
```

Either the passphrase **or** the recovery key recovers `DK`, then `DK` decrypts the
payload. **AAD is `null`** for all three AEAD operations.

⚠️ E2EE means a lost passphrase = unrecoverable data. The recovery key is mandatory UX:
show it **once** at export, tell the user to write it down / store it in a password
manager.

### Recovery-key text encoding
`RK` (32 bytes) is shown as **RFC 4648 base32, uppercase, no padding (`=`)**, then grouped
into 4-char blocks joined by `-` for legibility, e.g.
`UCQ2-FI5E-…-X27Q` (52 base32 chars → 13 groups). On input: uppercase, strip every
character outside `[A-Z2-7]` (dashes/spaces/lowercase tolerated), base32-decode back to the
32 bytes, use directly as the AEAD key for `wrap.rec`. (RK is full-entropy, so no Argon2 —
it is used as raw key material.)

## 4. File format — JSON envelope

A `.scbk` file is UTF-8 JSON. A JSON envelope (not packed binary) is deliberate: trivial
to parse identically in Swift `Codable` and TypeScript, self-describing, and versioned.
All binary fields are **standard base64 (RFC 4648, with `=` padding)**.

```jsonc
{
  "format": "SCBK1",
  "kdf": {
    "algorithm": "argon2id13",
    "opslimit": 3,
    "memlimit": 67108864,
    "salt": "<base64, 16 bytes>"
  },
  "aead": "xchacha20poly1305-ietf",
  "wrap": {
    "passphrase": { "nonce": "<base64, 24 bytes>", "ciphertext": "<base64, 48 bytes = 32B DK + 16B tag>" },
    "recovery":   { "nonce": "<base64, 24 bytes>", "ciphertext": "<base64, 48 bytes>" }
  },
  "payload": { "nonce": "<base64, 24 bytes>", "ciphertext": "<base64, AEAD(plaintext)>" }
}
```

Key order is **not** significant — readers must parse by name, not offset (Swift `Codable`
and JS emit different orders, and that is fine). A reader MUST reject a file whose `format`
≠ `"SCBK1"`.

## 5. Plaintext payload — the canonical wire format

The decrypted payload is the canonical inventory JSON: `schemaVersion: 2`, then
`contexts → categories → items → checks` (see
`docs/SuppliesCheck_CrossPlatformSync_Plan.md` §4). The two apps need not emit
byte-identical JSON (key order may differ), but every **value format below is mandatory**
so each app can parse the other's. (S1 converged the *fields* and due-date math; S2 pins
the *serialization*. These four rules are where the two apps previously diverged.)

| Field | Wire format | Notes |
|---|---|---|
| every `uuid` | **hyphenated RFC-4122 UUID**, compared **case-insensitively** | iOS `UUID` is strict (rejects `"vehicle"`-style ids) and Foundation emits UPPERCASE; Android emits lowercase and lowercase-normalizes on import. Default `Vehicle`/`Bag`/`House` + their `Uncategorized` use **shared fixed UUIDs** on both platforms so they merge, not duplicate |
| `exportedAt`, `createdAt`, `modifiedAt` | **ISO-8601 UTC, second precision, `Z`, NO fractional seconds** (`"2026-06-10T00:00:00Z"`) | iOS `JSONDecoder.iso8601` rejects `.000` fractional; Android must strip ms |
| check `date` | **calendar date `YYYY-MM-DD`** (`"2026-06-10"`), no time | a check is a day, not an instant |
| check `result` | **`"ok"` \| `"replaced"` \| `"needsAttention"`** (lowercase) | iOS stores `"OK"`/`"Replaced"`/`"Needs attention"` internally and maps to/from these canonical wire values |

Nullable fields are present with explicit `null`. Photos and local-only fields
(notifications, per-device settings) are never in the payload.

Readers SHOULD also accept legacy same-app values for back-compat (iOS: a full-ISO check
`date` and `"OK"`-cased result from pre-S2 `.json` exports).

## 6. Merge on import — additive (Phase 1)

Decrypt → parse → **additive uuid-keyed merge** (idempotent, non-destructive: only ADDS
missing contexts/categories/items/checks; never overwrites or deletes). iOS
`DataImporter` already does this; Android mirrors it. Edits/deletes propagate only in
Phase 2 (S3: `modifiedAt` LWW + `deletedAt` tombstones).

## 7. Conformance

A conforming implementation MUST:
1. Reproduce every value in `expected` from the `inputs` in `scbk1-vectors.json`
   (KEK, recovery-key string, all three ciphertexts).
2. Parse `scbk1-sample.scbk` and decrypt it to `inputs.plaintextUtf8` using **either** the
   passphrase **or** the recovery-key string.
3. Reject a payload whose AEAD tag fails (tamper) and a wrong passphrase/recovery key.
