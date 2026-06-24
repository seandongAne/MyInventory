# MyInventory (SuppliesCheck) — Build Notes

Implementation of the SuppliesCheck PRD + Development Plan, built into the existing
`MyInventory` Xcode project. The app keeps the project/target/bundle name
**MyInventory** (`CharlieW.MyInventory`); the SuppliesCheck product label was
intentionally not used for the on-screen name.

**Status:** Milestones **M0–M5 implemented, local-only.** CloudKit sync (M6) and the
optional in-app speech recognizer are deliberately deferred — see below.

---

## How to open, build, run

1. Open `MyInventory.xcodeproj` in Xcode 26.5.
2. The new Swift files live in `MyInventory/` under `Models/`, `Views/`,
   `Services/`, `Support/`. The project uses **file-system-synchronized groups**,
   so these were picked up automatically — no "Add Files" step needed.
3. Select an **iPad** simulator (the primary target; iPhone also works) and Run.
4. First launch seeds the three contexts (Vehicle / Bag / House). Add a category,
   then add items.

No third-party dependencies. Nothing to `pod`/`spm`.

## Previews & debugging — the Xcode-MCP question

There is **no Xcode MCP in the Claude connector registry**, and the Cowork shell is a
Linux sandbox with no Swift toolchain, so it cannot build, run Previews, or read
build logs. That loop has to happen on your Mac. Two good options (both from Dev Plan §1):

- **Recommended: Xcode 26.5's built-in Claude coding assistant.** It has Preview
  visual verification — it renders SwiftUI Previews, sees the UI, and reads the build
  errors directly. Best fit for iterating against the §6 design spec.
- **CLI alternative: Claude Code on your Mac + a community Xcode MCP** such as
  `XcodeBuildMCP` (wraps `xcodebuild` / `xcrun simctl`: build, run on simulator,
  capture build errors). Install it into your local Claude Code config, not Cowork.

Every view has a `#Preview`-friendly structure; `StatusBadge` already ships a `#Preview`.
For model-backed previews, inject an in-memory container, e.g.
`.modelContainer(for: [SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self], inMemory: true)`
plus `.environment(SettingsStore())` and `.environment(NotificationManager())`.

## Open Questions — defaults applied

Per Dev Plan §10 the recommended defaults were used (change if the end user prefers otherwise):

- **Q1** Never-checked item with an interval → treated as **due immediately**
  (`SupplyStatus.neverChecked`, sorts near the top).
- **Q2** Lead time → **global default (7 days) + optional per-item override**.
- **Q3** Deleting a category → its items **move to an "Uncategorized" bucket** in the
  same context; never destroyed.
- **Q5** Check result → small enum **{OK, Replaced, Needs attention}** + free-text comment.

## What's in each milestone

- **M0** — `Models/` (SupplyContext, SupplyCategory, SupplyItem, CheckRecord, derived
  SupplyStatus), CloudKit-safe rules baked in. `MyInventoryApp` registers the schema
  **local-only**. `SeedData` seeds the three contexts.
- **M1** — `ContentView` 3-column `NavigationSplitView`; `ContextListView` grouped
  categories→items; `ItemEditView` create/edit; `CategoryManagerView` with the
  Uncategorized fallback. `ContentUnavailableView` empty/no-selection/no-results states.
- **M2** — `CheckSheet` logs a `CheckRecord`; `StatusBadge` (color + symbol + text);
  overdue/needs-attention pinned to top and row-tinted; per-item history in `ItemDetailView`.
- **M3** — comment field supports **on-device keyboard dictation** (the mic key),
  offline, saved on the record. (See deferred note.)
- **M4** — `NotificationManager`: authorization, due + lead reminders **batched by
  calendar day** (`due-day-`/`lead-day-`; a lone item keeps its `item-<uuid>-due/-lead`
  ID so its deep link + Mark-as-Checked survive). **No look-ahead window** — every
  FUTURE due is planned, sorted soonest-first, capped at 60 distinct days < the iOS 64
  limit (the cap scales with due-days, not item count, so far-future e.g. 2-year
  reminders stay armed across long gaps between app opens). Plus a single **attention
  digest** for overdue/flagged/never-checked items and a once-only **inactivity nudge**
  (~1 month out, pushed forward each reschedule). Reschedules on check/edit/delete and
  on app foreground; never-expires items schedule nothing.
- **M5** — debounced **fuzzy search** (`FuzzySearch`, Levenshtein/token scoring) over
  name/category/location; single **photo** via `PhotosPicker` (external storage);
  optional **storage location**. All optional, never block saving.

## Deferred on purpose

- **In-app SFSpeechRecognizer mic button.** Keyboard dictation already satisfies P0-4
  with zero permissions and zero concurrency risk. A custom `AVAudioEngine` +
  `SFSpeechRecognizer` button is sensitive to the project's `MainActor`-default
  isolation and can't be validated without the on-device build loop, so it was left
  out. Add it on the Mac (Previews/error logs will catch isolation issues). If you do,
  add `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` and
  `INFOPLIST_KEY_NSMicrophoneUsageDescription` to the target build settings
  (the project uses `GENERATE_INFOPLIST_FILE = YES`, no Info.plist file).

## M6 — turning on CloudKit (when the schema is stable)

The schema already obeys every CloudKit rule (no `.unique`, all attributes
optional/defaulted, all relationships optional with inverses, no `.deny`). To enable sync:

1. In `MyInventoryApp.swift`, add `cloudKitDatabase: .automatic` to the
   `ModelConfiguration` (there's a comment marking the exact spot).
2. Add the **iCloud → CloudKit** capability with container `iCloud.CharlieW.MyInventory`,
   plus **Push Notifications** and Background Modes → Remote notifications.
3. Re-verify the model against the CloudKit rules (violations surface as console errors
   on first sync), then **deploy the schema Development → Production** in the CloudKit
   dashboard before any TestFlight build.
4. Test convergence across two simulators/devices on one Apple ID, and confirm full
   offline operation in airplane mode.

## Worth verifying on device / simulator

- Notification permission prompt appears the first time you save an item that has an
  interval (or via Settings → Enable Notifications), and reminders fire at ~9:00 local
  on the due/lead dates.
- Overdue and never-checked items pin to the top of each category section and show the
  red tint.
- Deleting a category moves its items to "Uncategorized" rather than deleting them.
- SwiftData `@Query` live-updates the lists after add/check/delete (filtering is done
  in-memory specifically to guarantee this).
