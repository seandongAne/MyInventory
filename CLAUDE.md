Use Chinese as major chat and interaction language.
Keep professional wording, path and code in English.

# MyInventory

A SwiftUI + SwiftData iOS app for tracking physical emergency/survival/camping
supplies across several places and reminding the owner to re-check each item on a
**personal, per-item interval** (not a fixed shelf life). Single-user, local-only
(iCloud/CloudKit sync is deliberately deferred to a later milestone). Originally
written on Windows without Xcode; now builds/tests/runs on Xcode.

- Bundle id `CharlieW.MyInventory`, single scheme `MyInventory`, deployment target
  iOS 26.5, Swift 5 language mode. Xcode project uses file-system synchronized
  groups (`PBXFileSystemSynchronizedRootGroup`) → source files are auto-discovered
  from disk; **no per-file editing of `project.pbxproj` is needed** to add/remove
  files (just create/delete on disk).
- Product docs live in `docs/` (PRD, development plan, UI redesign spec).

## Commands

Build / test / run on the simulator (see also memory `ios-build-test-run`):

```
# Build
xcodebuild build -project MyInventory.xcodeproj -scheme MyInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/MyInv_DD CODE_SIGNING_ALLOWED=NO

# Unit tests (fast)        add: -only-testing:MyInventoryTests
# UI tests (slow)          add: -only-testing:MyInventoryUITests
xcodebuild test  ...same flags...

# Run: install /tmp/MyInv_DD/Build/Products/Debug-iphonesimulator/MyInventory.app,
# then  xcrun simctl install/launch "iPhone 17" CharlieW.MyInventory
```

## Architecture

Root is a three-column `NavigationSplitView` (collapses to a stack on iPhone):

```
Sidebar (contexts + global search)  →  Content (a context's items)  →  Detail (one item)
        ContentView.swift                  ContextListView.swift          ItemDetailView.swift
```

Domain hierarchy: **Context → Category → Item → CheckRecord**
(`Context (Vehicle | Bag | House | …)` → `Category` → `Item` → check history).

### File map

App shell
- `MyInventoryApp.swift` — `@main`. Builds the `ModelContainer` (with a one-retry +
  recoverable `StorageErrorView` fallback, never an in-memory fallback that would
  silently lose writes). `-uiTesting` launch arg → in-memory store.
- `ContentView.swift` — root `NavigationSplitView`; sidebar context list; **app-wide
  search** (`.searchable` → `FuzzySearch` over all items → tap opens detail sheet);
  **add/delete context** (orphan-safe `deleteContext`, keeps ≥1 context); first-launch
  seeding + notification refresh on appear/foreground.

Models (`Models/`, all `@Model`, CloudKit-safe — see invariants)
- `SupplyContext.swift` — top-level place. `categories` → `.cascade`.
- `SupplyCategory.swift` — group within a context. `items` → **`.nullify`** (deleting a
  category must not destroy items; app logic moves them to an "Uncategorized" bucket).
- `SupplyItem.swift` — a tracked supply. `checkIntervalMonths: Int?` (nil = never
  expires), `leadTimeDaysOverride: Int?` (nil = use global), `photo` (external storage),
  `checks` → `.cascade`. `lastCheck` = most recent by date.
- `CheckRecord.swift` — one check event + `CheckResult` enum (`ok` / `replaced` /
  `needsAttention`), persisted as a String.
- `SupplyStatus.swift` — **the core derived-status logic** (extension on `SupplyItem`):
  `status(leadTimeDays:now:calendar:)`, `nextDueDate`, `daysUntilDue`,
  `statusDetailLabel`. Status enum + `sortPriority`. **Status is NEVER stored.**

Services
- `Services/NotificationManager.swift` — `@MainActor @Observable`. Local re-check
  reminders. Pure, testable static planner `plannedNotifications(...)` (due + lead per
  item, sorted soonest-fire-first, capped at 60 < iOS's 64; never-expires → none;
  never-checked → a first-check reminder; overdue-with-history → none). `rescheduleAll`
  is fetch-failure-safe (skips, never wipes existing reminders).

Support
- `Support/SettingsStore.swift` — `@Observable`, UserDefaults-backed: `globalLeadTimeDays`,
  `defaultIntervalMonths`, `notificationsRequested`.
- `Support/FuzzySearch.swift` — dependency-free typo-tolerant ranking over
  name/category/location (exact > prefix > substring > Levenshtein).
- `Support/SeedData.swift` — seeds the default contexts on first launch; symbols/colors
  per context; `seedUITestSampleIfNeeded` (UI-test sample data).

Views (`Views/`)
- `ContextListView.swift` — content column: a context's categories → items (overdue
  pinned), **per-context** search, add item / manage categories, move/delete item.
- `ItemDetailView.swift` — detail column: status card, "Check now", details, check
  history; edit/delete. (`CheckHistoryCard` lives here.)
- `ItemEditView.swift` — create/edit item form (name + context + category required;
  interval/lead/location/photo optional). Photo via PhotosPicker or camera.
- `CheckSheet.swift` — log a `CheckRecord`; backdate warning; reschedules notifications.
- `CategoryManagerView.swift` — add/remove categories; delete-with-move flow to an
  Uncategorized bucket; move single items.
- `SettingsView.swift` — lead time, default interval, notification permission + failure
  surface, sync status (Local only).
- `CameraCapture.swift` — `UIImagePickerController` wrapper (camera). Needs
  `NSCameraUsageDescription` (set via `INFOPLIST_KEY_…` in build settings).
- `StatusBadge.swift` — reusable status capsule.

Design system (`DesignSystem/`)
- `Theme.swift` — all design tokens (colors, spacing, geometry, shadow, animation).
- `SupplyStatusStyle.swift` — **single source of truth** mapping `SupplyStatus` →
  color/symbol/label (`status.style`).
- `ItemCard.swift` — primary list-row card. `Card.swift` (`.cardStyle()`),
  `PressableButtonStyle.swift`, `ScreenBackground.swift` — visual primitives.

## Invariants & conventions (preserve these)

- **Status is derived, never stored** — always go through `SupplyItem.status(...)`.
  Precedence: overdue > needsAttention > neverExpires(no interval) > neverChecked >
  dueSoon > ok.
- **CloudKit-safe models** — no `@Attribute(.unique)`; every stored property optional or
  defaulted; every relationship optional with an explicit inverse; no `.deny` delete
  rules. Stable IDs use a plain `uuid` property (not `.unique`).
- **Delete rules**: context→categories `.cascade`, category→items **`.nullify`**,
  item→checks `.cascade`. Because category→items is `.nullify`, **deleting a context must
  delete its items explicitly first** (see `ContentView.deleteContext`) or they become
  orphaned (reachable from no context). Always keep ≥1 context.
- **Single source of truth for status visuals**: `SupplyStatus.style` — don't add a
  parallel color/symbol palette.
- **Every `modelContext.save()` is paired with `rollback()` + a user-visible error** on
  failure; never swallow.
- **Notifications run on `@MainActor`**; keep the planner pure/static and testable.
- Design values come from `Theme`; cards via `.cardStyle()`; status via `StatusBadge` /
  `SupplyStatus.style`.

## Testing

- `MyInventoryTests/` — XCTest unit tests (`@MainActor`, in-memory `ModelContainer`):
  derived status & precedence, status labels, fuzzy search, the notification planner,
  the Uncategorized move, and orphan-safe context deletion.
- `MyInventoryUITests/` — XCUITest. Launch with `-uiTesting` (in-memory store + seeded
  sample data + stays on the sidebar). Covers: launch state, app-wide search across
  contexts, context drill-down, adding a context. (Swipe-to-delete is intentionally not
  UI-tested — unreliable on a split-view sidebar; the delete logic is unit-tested.)
