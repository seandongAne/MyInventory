# SuppliesCheck — Product Requirements Document (PRD)

**Version:** 1.0 (Draft for development)
**Platform:** Native iOS (iPadOS-first)
**Date:** 10 June 2026
**Author:** Sean (on behalf of end user / "the instructor")
**Intended audience:** Cowork / Claude Code development session

---

## 1. Background & Context

The end user is an individual who maintains physical emergency / survival / camping supplies across several contexts (vehicle, go-bag, house). Items need to be periodically **re-checked** — not because they have a fixed shelf life that the app tracks, but because the user defines a **personal re-check interval** per item (e.g. "inspect the camping knife for functionality every 48 months", "rotate the canned tuna every 12 months").

The user currently tracks this on paper (see source note). They want a small, private, offline-capable iPad app that tells them what is due for a check, lets them log each check with a note, and keeps a history.

This is a **single-user, personal-use** application. It is being built and gifted by the developer; the end user will receive it via TestFlight. There is no commercial distribution, no multi-tenant requirement, and no login/account system beyond the device's own iCloud identity.

---

## 2. Problem Statement

The user has supplies spread across multiple locations and no reliable system to know **which items are overdue for inspection or rotation**. Paper checklists do not proactively flag overdue items, do not retain a check history, and are not searchable. The cost of not solving this is real: expired water, a non-functional stove, or out-of-date bear spray discovered at the worst possible moment.

---

## 3. Goals

1. **Surface overdue items automatically** — the user can open the app and immediately see everything that is due or overdue for a check, with no manual scanning.
2. **Make logging a check effortless** — recording a completed check (with an optional note) takes seconds, including hands-free voice entry.
3. **Preserve a complete check history** — every check is retained with its timestamp, result, and any comment, so the user can review the full record per item.
4. **Organize supplies by context** — items are grouped into three top-level contexts (Vehicle / Bag / House), each with its own categories.
5. **Work offline, sync optionally** — the app is fully functional with no network; iCloud sync across the user's own iPads is available but not required.

---

## 4. Non-Goals (v1)

1. **No Windows / cross-platform support.** Dropped deliberately in favor of a clean native iOS/SwiftUI implementation. (A Windows or web client is not planned.)
2. **No multi-user / sharing / accounts.** Single user only. No login screen, no roles, no shared lists. iCloud identity is the only "account."
3. **No shelf-life / expiry-date database.** The app does not know product expiry dates. The re-check interval is **user-defined per item**, full stop. (See §7 — this is the single most important modeling decision.)
4. **No barcode scanning / product lookup.** Items are entered manually. Could be a future consideration.
5. **No purchasing, shopping lists, or inventory quantity tracking.** This is a *check* tool, not a stock-management tool. (Quantity may be a future P2.)
6. **No high-accuracy / cloud transcription.** Voice input uses on-device iOS dictation only, to preserve the offline requirement.
7. **No multi-photo galleries per item (v1).** One photo per item; multi-photo is a future consideration.

---

## 5. Target User & Personas

**Primary (and only) persona — "The Owner":**
A single individual managing personal survival/camping/household supplies. Moderately tech-comfortable, uses an iPad and previously a Windows PC. Values privacy ("private use"), reliability, and not having to think about the system until it tells them something is due.

---

## 6. User Stories

Ordered by priority.

1. As the owner, I want to **see all overdue and due-soon items the moment I open the app**, so that I know what needs attention without searching.
2. As the owner, I want to **add an item with a name, a context (Vehicle/Bag/House), a category, and a re-check interval**, so that the app can track when it is next due.
3. As the owner, I want to **mark an item as checked today and optionally add a note**, so that its next due date is recalculated and the check is recorded.
4. As the owner, I want to **dictate the note by voice**, so that I can log a check hands-free while handling the item.
5. As the owner, I want to **receive a system notification when an item becomes due**, so that I am reminded even when the app is closed.
6. As the owner, I want to **optionally set a "warn me N days early" lead time**, so that I get advance notice before something is overdue.
7. As the owner, I want to **mark some items as "never expires"** (no interval), so that they are tracked and checkable but never flagged or notified.
8. As the owner, I want to **search items by keyword (fuzzy)**, so that I can find an item quickly among hundreds.
9. As the owner, I want to **view the full check history for an item**, so that I can see when it was last inspected and read past notes.
10. As the owner, I want to **optionally attach one photo and a storage-location note to an item**, so that I remember what it looks like and where it is kept. (Both optional; absence must not block normal use.)
11. As the owner, I want my data to **sync across my own iPads via iCloud**, so that I see the same list on each device — but the app must still work fully if iCloud is off.
12. As the owner, I want to **add and remove items and categories freely**, so that the lists stay current.

---

## 7. Core Domain Model & Semantics (READ FIRST)

This section defines the meaning of the data. Misreading this is the most likely source of bugs.

### 7.1 The "Time Interval" is a user-defined re-check cadence
- Each item has an optional **`checkIntervalMonths`** (user picks the number and unit; months is the natural unit but the model should store a normalized duration — see Development Plan).
- The **next due date** is computed as: `lastCheckDate + interval`.
- If the item has **no interval** (nil), it is a **"never expires" item**: it is never flagged, never generates a notification, but can still be manually checked and will still record history.

### 7.2 A "check" is a historical event, not a boolean
- The paper form's "Checked ✓" column is **not** a persistent flag. It represents the act of performing a check.
- Each check creates a **`CheckRecord`**: `{ date, result, comment? }`.
- The item's status (OK / due / overdue) is **derived** from `mostRecentCheck.date + interval` vs. today. It is never stored as a mutable flag (storing it would create sync conflicts and staleness).

### 7.3 Status is always derived
- **OK / Up to date:** `today < nextDueDate - leadTime`
- **Due soon:** `nextDueDate - leadTime <= today < nextDueDate`
- **Overdue:** `today >= nextDueDate`
- **Never expires:** interval is nil → no status, never flagged.
- **Never checked:** an item with an interval but zero `CheckRecord`s should be treated as **due immediately** (it needs a first check) — confirm this rule with the user, but it is the sensible default.

### 7.4 Two-level grouping
`Context (Vehicle | Bag | House)` → `Category (e.g. "Survival Essentials", "Camping Essentials")` → `Item`.
- The three contexts are fixed top-level tabs in v1.
- Categories are user-created within each context.

---

## 8. Requirements

### 8.1 Must-Have (P0)

**P0-1 — Item CRUD**
Add, edit, and remove items. Each item: name (required), context (required), category (required), re-check interval (optional → "never expires"), storage location (optional text), photo (optional, single).
- *Acceptance:* An item can be created with only name + context + category. Interval, location, and photo can all be left empty and the item still saves and functions.

**P0-2 — Category CRUD within a context**
Create and remove categories under each of the three contexts.
- *Acceptance:* A new category appears under the correct context tab and can hold items. Removing a category prompts about its items (move/delete — see Open Questions).

**P0-3 — Log a check**
Mark an item checked "today" (or a chosen date), which creates a `CheckRecord` and recomputes the next due date.
- *Acceptance:* After logging a check, the item's status updates immediately and a history entry exists with the correct timestamp.

**P0-4 — Optional comment with voice dictation**
The check-logging flow includes an optional free-text comment field that supports the standard iOS dictation (microphone key / `SFSpeechRecognizer`-backed system input).
- *Acceptance:* The user can dictate a comment using on-device dictation with no network; the transcribed text is saved on the `CheckRecord`.

**P0-5 — Derived status + overdue highlighting**
The app computes OK / due-soon / overdue / never-expires status and visually highlights and pins overdue (and due-soon) items to the top within each view.
- *Acceptance:* Opening any list shows overdue items first, visually distinct; never-expires items are never flagged.

**P0-6 — Local notifications**
Schedule a system notification when an item reaches its due date, plus an optional user-configurable "N days early" advance notification.
- *Acceptance:* With notifications authorized, the user receives a notification on the due date; if a lead time is set, an additional earlier notification fires. Changing an item's interval or logging a check reschedules its notifications correctly. Never-expires items schedule nothing.

**P0-7 — Notification lead-time setting**
The user can configure the advance-warning lead time. (Decision needed: global default vs. per-item override — see Open Questions; recommend a global default with optional per-item override.)
- *Acceptance:* The configured lead time is reflected in both the scheduled notification and the "due soon" status threshold.

**P0-8 — Fuzzy keyword search**
Search across items by name (and ideally category/location) with tolerance for typos/partial matches.
- *Acceptance:* Typing a partial or slightly misspelled term surfaces the relevant item. (Implementation note in Dev Plan — true fuzzy matching needs in-memory filtering, since SwiftData `#Predicate` only does substring `contains`.)

**P0-9 — Check history view**
Per item, display a reverse-chronological list of all `CheckRecord`s with date, result, and comment.
- *Acceptance:* Every logged check appears; history persists across launches and syncs.

**P0-10 — Offline-first persistence**
All functionality works with no network connection. Data persists locally via SwiftData.
- *Acceptance:* In airplane mode, all CRUD, checks, notifications, search, and history work fully.

**P0-11 — Optional iCloud sync**
SwiftData + CloudKit private database sync across the user's own devices, gated so the app degrades gracefully to local-only if iCloud is unavailable or disabled.
- *Acceptance:* Two iPads on the same Apple ID converge to the same data; disabling iCloud does not crash or lose local data.

### 8.2 Nice-to-Have (P1)

- **P1-1** — Manual check date (log a check for a past date, not just "today").
- **P1-2** — Edit/delete an individual `CheckRecord` (correct a mistaken entry).
- **P1-3** — Sort/filter controls (by due date, by status, by category).
- **P1-4** — A unified "Due / Overdue" dashboard across all three contexts (a fourth "Home" tab), in addition to per-context views.
- **P1-5** — Snooze an overdue item ("remind me in 7 days") without logging a real check.
- **P1-6** — Export / backup (e.g. CSV or a shareable file) for the user's own records.

### 8.3 Future Considerations (P2) — design so as not to preclude

- **P2-1** — Multiple photos per item.
- **P2-2** — User-defined contexts beyond the fixed three (make the "context" a data entity, not a hardcoded enum, if cheap to do).
- **P2-3** — Quantity / stock tracking.
- **P2-4** — Barcode scanning for entry.
- **P2-5** — Windows or web companion (explicitly out of scope; CloudKit choice makes this harder, which is an accepted tradeoff).

---

## 9. Constraints & Technical Direction

- **Native iOS, SwiftUI, SwiftData.** iPadOS-first; should run on iPhone too for free if layout is adaptive (no extra requirement, just don't break it).
- **iCloud / CloudKit private database** for sync. This imposes hard schema rules (see Dev Plan §SwiftData Model): no unique constraints, all attributes optional or defaulted, all relationships optional with inverses, no `.deny` delete rules, additive-only schema migrations once sync is live.
- **On-device dictation only** — no third-party or cloud transcription, preserving offline + privacy.
- **Distribution via the developer's Apple Developer Program account → TestFlight.** End user installs free via TestFlight invite. TestFlight builds expire ~90 days; plan periodic rebuilds. CloudKit requires the paid developer account (already in hand), so sync is available.
- **Privacy:** all data lives in the user's local store and their own private iCloud database. The developer has no access to it.

---

## 10. Success Criteria (personal-use, qualitative)

Since this is a single-user gift, "success metrics" are practical rather than analytical:
- The user stops maintaining the paper list.
- Overdue items are caught by the app before the user notices manually.
- Logging a check feels fast enough that the user actually does it.
- Data is identical across the user's iPads without manual effort.
- The user never sees a crash, data loss, or a spurious "overdue" on a never-expires item.

---

## 11. Open Questions

Blocking (resolve before/early in build):
- **Q1 (user):** For an item that has an interval but has *never* been checked, should it show as "due immediately"? (Recommended default: yes.)
- **Q2 (user):** Lead-time setting — single global default, per-item override, or both? (Recommended: global default + optional per-item override.)
- **Q3 (user):** When a category is deleted, what happens to its items — block deletion, move to an "Uncategorized" bucket, or cascade-delete? (Recommended: move to "Uncategorized" within the same context; never silently destroy data.)

Non-blocking (resolve during build):
- **Q4 (user):** Interval unit — is months always sufficient, or are days/weeks/years also wanted? (Recommended: store a normalized component-based duration; expose months + years in UI, easy to extend.)
- **Q5 (user):** Should "result" on a check be free-text only, or a small set like {OK, Replaced, Needs attention}? (Recommended: a simple enum + the free-text comment.)
- **Q6 (dev):** Confirm the fixed three contexts won't need user-added contexts soon; if uncertain, model context as data now (cheap insurance, see P2-2).

---

## 12. Source Reference

This PRD is derived from a handwritten planning note ("Supplies Check"), interview clarifications captured during scoping, and current SwiftData + CloudKit platform constraints verified at time of writing.
