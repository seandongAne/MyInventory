Use Chinese as major chat and interaction language.
Keep professional wording, path and code in English.

# MyInventory

A SwiftUI + SwiftData iOS app for tracking physical emergency/survival/camping
supplies across several places and reminding the owner to re-check each item on a
**personal, per-item interval** (not a fixed shelf life). Single-user, local-only
(iCloud/CloudKit sync is deliberately deferred to a later milestone; a JSON export
in Settings is the interim backup). Originally written on Windows without Xcode;
now builds/tests/runs on Xcode.

- Bundle id `CharlieW.MyInventory`, scheme `MyInventory` (plus a `MyInventoryWidgets`
  widget-extension target embedded in the app), deployment target iOS 26.5, Swift 5
  language mode. Xcode project uses file-system synchronized groups
  (`PBXFileSystemSynchronizedRootGroup`) → source files are auto-discovered from disk;
  **no per-file editing of `project.pbxproj` is needed** to add/remove files (just
  create/delete on disk). Targets/build-settings changes still require pbxproj edits.
- App + widget share the app group `group.CharlieW.MyInventory` (entitlements files in
  each target folder). On the simulator this works unsigned; on device it needs real
  provisioning.
- Product docs live in `docs/` (PRD, development plan, UI redesign spec).

## Commands

Build / test / run on the simulator (see also memory `ios-build-test-run`):

```
# Build
xcodebuild build -project MyInventory.xcodeproj -scheme MyInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/MyInv_DD CODE_SIGNING_ALLOWED=NO

# Unit tests (fast)        add: -only-testing:MyInventoryTests
# UI tests (slow)          add: -only-testing:MyInventoryUITests -parallel-testing-enabled NO
#   (parallel simulator clones intermittently fail to launch the unsigned test
#    runner with "Application failed preflight checks" — run UI tests serially)
xcodebuild test  ...same flags...

# Run: install /tmp/MyInv_DD/Build/Products/Debug-iphonesimulator/MyInventory.app,
# then  xcrun simctl install/launch "iPhone 17" CharlieW.MyInventory
```

## Architecture

Root is a three-column `NavigationSplitView` (collapses to a stack on iPhone):

```
Sidebar (attention + contexts + search)  →  Content (attention list / a context's items)  →  Detail (one item)
            ContentView.swift                 AttentionListView / ContextListView                ItemDetailView.swift
```

Sidebar selection is `SidebarSelection` (`.attention` | `.context(SupplyContext)`):
a cross-context **"Needs Attention" dashboard** sits above the context list.

Domain hierarchy: **Context → Category → Item → CheckRecord**
(`Context (Vehicle | Bag | House | …)` → `Category` → `Item` → check history).

### File map

App shell
- `MyInventoryApp.swift` — `@main`. Pulls the shared container from
  `AppModelContainer` (one retry + recoverable `StorageErrorView` fallback, never an
  in-memory fallback that would silently lose writes), wires
  `NotificationManager.shared.configure(container:settings:)`.
- `ContentView.swift` — root `NavigationSplitView`; sidebar = Needs Attention row +
  context list; **app-wide search** (`.searchable` → `FuzzySearch` over all items →
  tap opens detail sheet); **add/delete context** (orphan-safe `deleteContext`, keeps
  ≥1 context, duplicate names rejected); first-launch seeding + notification refresh
  on appear/foreground; **notification deep links** (`NotificationManager.pendingDeepLink`
  → item sheet or attention view). Deleting an item from the search sheet also clears
  a matching `selectedItem` (zombie-model crash guard).

Models (`Models/`, all `@Model`, CloudKit-safe — see invariants)
- `SupplyContext.swift` — top-level place. `categories` → `.cascade`.
- `SupplyCategory.swift` — group within a context. `items` → **`.nullify`** (deleting a
  category must not destroy items; app logic moves them to an "Uncategorized" bucket).
  "Uncategorized" is a reserved name (creation blocked in UI).
- `SupplyItem.swift` — a tracked supply. `checkIntervalMonths: Int?` (nil = never
  expires), `leadTimeDaysOverride: Int?` (nil = use global), `quantity: Int?` (nil =
  untracked; editable in CheckSheet too), `photo` (external storage), `checks` →
  `.cascade`. `lastCheck` = most recent by date.
- `CheckRecord.swift` — one check event + `CheckResult` enum (`ok` / `replaced` /
  `needsAttention`), persisted as a String.
- `SupplyStatus.swift` — **the core derived-status logic** (extension on `SupplyItem`):
  `status(leadTimeDays:now:calendar:)`, `nextDueDate`, `daysUntilDue`,
  `statusDetailLabel`. Status enum + `sortPriority` + `isAttention`.
  **Status is NEVER stored.**

Services
- `Services/NotificationManager.swift` — `@MainActor @Observable`, singleton
  `NotificationManager.shared` (shared with App Intents). Local re-check reminders:
  - Pure, testable static planner `plannedNotifications(...)`: per-item due + lead for
    FUTURE dues only, sorted soonest-fire-first, capped at 60 < iOS's 64.
  - **Attention digest**: overdue / flagged / never-checked items are batched into ONE
    `attention-digest` notification at the next fire hour (pure static
    `attentionSummary(...)`), re-armed each pass — never one nag per item, and it
    covers items that slip overdue between reschedules. App badge = attention count.
  - `resolvedFireDate(...)` (pure static) clamps a target day to `fireHour`, bumping
    past instants to the next day. Fire hour comes from `SettingsStore.notificationFireHour`.
  - Delegate adapter: foreground banners (`willPresent`), tap → `pendingDeepLink`
    (`.item(uuid)` from `item-<uuid>-due/-lead`, `.attention` from the digest;
    parser `deepLink(forNotificationIdentifier:)` is pure/testable), and a background
    **"Mark as Checked" action** (`SUPPLY_ITEM` category) that logs an OK check
    without opening the app (save failure → surfaced as an immediate notification).
  - `rescheduleAll` is fetch-failure-safe (skips, never wipes existing reminders) and
    also refreshes the widget snapshot (independent of notification permission).

Support
- `Support/AppModelContainer.swift` — shared `Result<ModelContainer, Error>` used by
  the app scene AND App Intents.
- `Support/SettingsStore.swift` — `@Observable`, UserDefaults-backed: `globalLeadTimeDays`,
  `defaultIntervalMonths`, `notificationsRequested`, `notificationFireHour`.
- `Support/FuzzySearch.swift` — dependency-free typo-tolerant ranking over
  name/category/context/location/check-comments (exact > prefix > substring > Levenshtein).
- `Support/SeedData.swift` — seeds the default contexts on first launch; symbols AND
  brand colors per context (both used by the sidebar); `seedUITestSampleIfNeeded`.
- `Support/Templates.swift` — starter checklists (Car Emergency Kit, Home Emergency,
  72-Hour Go Bag, Camping Box). `Templates.apply` reuses same-name categories and
  skips existing items (idempotent).
- `Support/DataExporter.swift` — JSON export of the full hierarchy (photos excluded)
  + `JSONExportDocument` for `.fileExporter`. Settings → "Export All Data…".
- `Support/Thumbnailer.swift` — ImageIO downsampling + NSCache for list-row photos
  (never decode the full stored image per row).
- `Support/WidgetBridge.swift` — writes a JSON snapshot (attention counts + next dues)
  to the app-group container and pokes WidgetKit; called from every reschedule. No-op
  when the app group is unavailable.
- `Support/SupplyIntents.swift` — App Intents: `MarkSupplyCheckedIntent`
  ("Mark a supply as checked in MyInventory"), `SupplyItemEntity` with fuzzy
  string query, `MyInventoryAppShortcuts`.

Views (`Views/`)
- `AttentionListView.swift` — cross-context dashboard of every `isAttention` item,
  most-urgent-first, with context›category breadcrumbs.
- `ContextListView.swift` — content column: a context's categories → items (overdue
  pinned), **per-context** search, add item / add-from-template / manage categories,
  move/delete item, **"Mark All as Checked"** bulk action per category section.
- `ItemDetailView.swift` — detail column: status card, "Check now", details (incl.
  quantity), check history; edit/delete. (`CheckHistoryCard` lives here.)
- `ItemEditView.swift` — create/edit item form (name + context + category required;
  interval/lead/quantity/location/photo optional). Photo via PhotosPicker or camera;
  unchanged photos are not rewritten on save.
- `CheckSheet.swift` — log a `CheckRecord`; backdate warning; optional quantity
  update in the same save; reschedules notifications.
- `CategoryManagerView.swift` — add/remove categories (duplicate + reserved names
  rejected); delete-with-move flow to an Uncategorized bucket; move single items;
  an EMPTY Uncategorized bucket may be deleted (recreated on demand).
- `TemplatePickerView.swift` — applies a `SupplyTemplate` to the current context.
- `SettingsView.swift` — lead time, reminder hour, default interval, notification
  permission + failure surface, JSON export, sync status (Local only).
- `CameraCapture.swift` — `UIImagePickerController` wrapper (camera). Needs
  `NSCameraUsageDescription` (set via `INFOPLIST_KEY_…` in build settings).
- `StatusBadge.swift` — reusable status capsule.

Design system (`DesignSystem/`)
- `Theme.swift` — all design tokens (colors, spacing, geometry, shadow, animation).
  `statusNeverChecked` is violet — visually distinct from overdue red.
- `SupplyStatusStyle.swift` — **single source of truth** mapping `SupplyStatus` →
  color/symbol/label (`status.style`).
- `ItemCard.swift` — primary list-row card (thumbnail via `Thumbnailer`, optional
  breadcrumb + quantity). `Card.swift` (`.cardStyle()`), `PressableButtonStyle.swift`,
  `ScreenBackground.swift` — visual primitives.

Widget (`MyInventoryWidgets/`, separate appex target)
- `MyInventoryWidgets.swift` — `WidgetBundle` with the "Supplies Status" widget
  (systemSmall + accessoryCircular + accessoryRectangular). Renders ONLY the
  `WidgetBridge` JSON snapshot from the app group — it deliberately has no SwiftData
  or model-code dependency. `WidgetSnapshot` must stay in sync with
  `WidgetBridge.Snapshot`.

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
  failure; never swallow. (Background contexts — notification action, intents — surface
  failures as notifications/intent errors instead of alerts.)
- **Notifications run on `@MainActor`**; keep the planner, digest, fire-date clamp, and
  deep-link parser pure/static and testable. Per-item nags are forbidden for
  needs-action-now states — they go through the single attention digest.
- **Selection must never outlive a deleted model** — when deleting an item/context from
  any path, clear every `@State` that may reference it (see ContentView's search-sheet
  `onDelete`).
- Debounce pattern: `task(id:)` + `guard (try? await Task.sleep(...)) != nil else { return }`
  — a bare `try?` would fall through on cancellation and defeat the debounce.
- Design values come from `Theme`; cards via `.cardStyle()`; status via `StatusBadge` /
  `SupplyStatus.style`.

## Testing

- `MyInventoryTests/` — XCTest unit tests (`@MainActor`, in-memory `ModelContainer`):
  derived status & precedence (incl. the exact-due-instant boundary), status labels,
  fuzzy search (incl. context-name + check-comment fields), the notification planner,
  the attention digest, fire-date clamping, deep-link parsing, JSON export round-trip,
  template idempotency, the Uncategorized move, and orphan-safe context deletion.
- `MyInventoryUITests/` — XCUITest. Launch with `-uiTesting` (in-memory store + seeded
  sample data + stays on the sidebar). Covers: launch state, app-wide search across
  contexts, context drill-down, adding a context. Run with
  `-parallel-testing-enabled NO` (see Commands). (Swipe-to-delete is intentionally not
  UI-tested — unreliable on a split-view sidebar; the delete logic is unit-tested.)
