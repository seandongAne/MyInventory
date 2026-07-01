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
  tap opens detail sheet); **add/rename/delete context** (rename + delete via the
  row's long-press menu — swipe on a split-view sidebar is unreliable; orphan-safe
  `deleteContext`, keeps ≥1 context, duplicate names rejected; rename reschedules
  notifications since bodies embed the context name); first-launch seeding +
  notification refresh on appear/foreground; **notification deep links**
  (`NotificationManager.pendingDeepLink` → item sheet or attention view). Deleting an
  item from the search sheet also clears a matching `selectedItem` (zombie-model
  crash guard). **Launch landing** (`applyInitialSidebarSelection`): iPad opens the
  first context; iPhone lands on Needs Attention when something is due, else stays
  on the sidebar (never hide search/overview behind a Back button); UI tests always
  stay on the sidebar.

Models (`Models/`, all `@Model`, CloudKit-safe — see invariants)
- `SupplyContext.swift` — top-level place. `categories` → `.cascade`.
- `SupplyCategory.swift` — group within a context. `items` → **`.nullify`** (deleting a
  category must not destroy items; app logic moves them to an "Uncategorized" bucket).
  "Uncategorized" is a reserved name (creation/rename-to blocked in UI);
  `SupplyCategory.uncategorizedBucket(in:modelContext:)` is the shared find-or-create
  used by both the delete-category flow and saving an item without a category.
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
  - Pure, testable static planner `plannedNotifications(...)`: due + lead for FUTURE
    dues only, **batched by calendar day** (same-day dues collapse into one
    `due-day-<date>` / `lead-day-<date>` reminder; a lone item keeps its
    `item-<uuid>-due/-lead` id so its deep link + Mark-as-Checked survive), sorted
    soonest-fire-first, capped at 60 < iOS's 64. Batching makes the cap scale with
    distinct due-days, not item count — the key to keeping a large inventory's
    far-future (e.g. 2-year) reminders armed across long gaps between app opens.
  - **Inactivity nudge** (`inactivity-nudge`): one generic "review your supplies"
    reminder armed ~1 month out and pushed forward on every reschedule. An active
    user never sees it; if the app goes untouched for a month it fires once, pulling
    the user back so reminders + the digest stay fresh. Cleared when there are no items.
  - **Attention digest**: overdue / flagged / never-checked items are batched into ONE
    `attention-digest` notification at the next fire hour (pure static
    `attentionSummary(...)`), re-armed each pass — never one nag per item, and it
    covers items that slip overdue between reschedules. App badge = attention count.
  - `resolvedFireDate(...)` (pure static) clamps a target day to `fireHour`, bumping
    past instants to the next day. Fire hour comes from `SettingsStore.notificationFireHour`.
  - Delegate adapter: foreground banners (`willPresent`), tap → `pendingDeepLink`
    (`.item(uuid)` from `item-<uuid>-due/-lead`, `.attention` from the digest or a
    `due-day-`/`lead-day-` batch; parser `deepLink(forNotificationIdentifier:)` is
    pure/testable), and a background
    **"Mark as Checked" action** (`SUPPLY_ITEM` category) that logs an OK check
    without opening the app (save failure → surfaced as an immediate notification).
  - `rescheduleAll` is fetch-failure-safe (skips, never wipes existing reminders) and
    also refreshes the widget snapshot (independent of notification permission).

Support
- `Support/AppModelContainer.swift` — shared `Result<ModelContainer, Error>` used by
  the app scene AND App Intents.
- `Support/Haptics.swift` — `Haptics.success()` for actions that complete without a
  visible UI change (quick check, bulk check, template apply, check save).
- `Support/SettingsStore.swift` — `@Observable`, UserDefaults-backed: `globalLeadTimeDays`,
  `defaultIntervalMonths`, `notificationsRequested`, `notificationFireHour`.
- `Support/FuzzySearch.swift` — dependency-free typo-tolerant ranking over
  name/category/context/location/check-comments (exact > prefix > substring > Levenshtein).
- `Support/SeedData.swift` — seeds the default contexts on first launch; brand colors
  per context (context ICONS live in `Iconography`); `seedUITestSampleIfNeeded`.
- `Support/Templates.swift` — starter checklists (Car Emergency Kit, Home Emergency,
  72-Hour Go Bag, Camping Box). `Templates.apply` reuses same-name categories and
  skips existing items (idempotent).
- `Support/DataExporter.swift` — JSON export of the full hierarchy (photos excluded);
  written to a temp file and shared via `ShareLink` (Settings → "Export All Data…":
  email / Files / cloud / AirDrop, so it can reach a PC).
- `Support/DataImporter.swift` — restores an exported JSON backup (Settings →
  "Restore from Backup…", `.fileImporter`). Merge is keyed on each entity's `uuid`,
  so it's **idempotent** (re-import = no-op) and **non-destructive** (only ADDS
  what's missing — never overwrites a field or deletes anything; also fills in
  missing checks on an existing item). Photos aren't in the export, so aren't
  restored. The real recovery story remains CloudKit sync (M6).
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
  most-urgent-first, with context›category breadcrumbs. Items are actionable in
  place: leading swipe / long-press = quick check, trailing swipe = delete (confirmed).
- `ContextListView.swift` — content column: a context's categories → items (overdue
  pinned), **per-context** search, add item (toolbar `Menu(primaryAction:)` — tap goes
  straight to Add Item, long-press offers templates) / manage categories, **quick
  check** (leading swipe with full-swipe, or long-press "Mark as Checked" — mirrors
  the notification action), move item, delete (trailing swipe or long-press, always
  confirmed), **"Mark All as Checked"** bulk action per category section.
- `ItemDetailView.swift` — detail column: status card, "Check now", details (incl.
  quantity), check history; Edit + a More menu (Move to Category / Delete Item).
  **Check records are deletable** (long-press a history row, confirmed) — a mistaken
  check pushes the due date out a full interval and must be correctable; deletion
  reschedules notifications. (`CheckHistoryCard` lives here.)
- `ItemEditView.swift` — create/edit item form (name + context required; category
  OPTIONAL — "None" files the item under the Uncategorized bucket so the first item
  is never blocked on taxonomy; interval/lead/quantity/location/photo optional).
  Interval uses `PresetValuePicker` (1/3/6/12/24 months + custom). Photo via
  PhotosPicker or camera; unchanged photos are not rewritten on save.
- `CheckSheet.swift` — log a `CheckRecord` with result/date/comment; backdate
  warning; optional quantity update in the same save; reschedules notifications.
  (The quick-check affordances cover the common "all good" case; this sheet is for
  everything else.)
- `CategoryManagerView.swift` — add/rename/remove categories (duplicate + reserved
  names rejected; rename/delete also on the row's long-press menu; the Uncategorized
  bucket can't be renamed); delete-with-move flow to an Uncategorized bucket; move
  single items; an EMPTY Uncategorized bucket may be deleted (recreated on demand).
- `TemplatePickerView.swift` — applies a `SupplyTemplate` to the current context;
  success = haptic + immediate dismiss (the new items appearing IS the confirmation).
- `PresetValuePicker.swift` — menu Picker over preset values + Custom stepper mode;
  use it instead of a bare Stepper for any value users would tap dozens of times.
- `SettingsView.swift` — lead time, reminder hour, default interval, notification
  permission + failure surface, JSON export, sync status (Local only).
- `CameraCapture.swift` — `UIImagePickerController` wrapper (camera). Needs
  `NSCameraUsageDescription` (set via `INFOPLIST_KEY_…` in build settings).
- `StatusBadge.swift` — reusable status capsule. Tinted by default; the system
  **Increase Contrast** setting (`colorSchemeContrast == .increased`) switches it
  to a solid status-color fill with `Theme.badgeInkOnFill` ink (no app-private
  toggle). `.neverExpires` always stays tinted — its neutral gray fill can't
  carry 4:1 ink in light mode and it isn't a signal state.

Design system (`DesignSystem/`)
- `Theme.swift` — all design tokens (colors, spacing, geometry, shadow, animation).
  Tints are adaptive light/dark PAIRS (`adaptive(light:dark:)`); every tint must
  clear **≥4:1 contrast vs the card surface in BOTH modes** (enforced by
  `ThemeContrastTests`; dark variants brighter + desaturated, light ambers kept
  deep — yellow/orange fails on white, not black). Dark `accentSoft` is OPAQUE
  (a translucent wash would erode icon contrast on the tile). The asset-catalog
  `AccentColor` carries the same dark variant. `statusNeverChecked` is violet —
  visually distinct from overdue red.
- `SupplyStatusStyle.swift` — **single source of truth** mapping `SupplyStatus` →
  color/icon/label (`status.style`). `iconName` = custom template asset used in-app;
  `symbol` = SF equivalent kept for surfaces that need symbol NAMES (widget, intents).
- `Iconography.swift` — custom identity icons (`Assets.xcassets/Icons`, 34 template
  SVGs, one 24-grid stroke family): context name → icon, item name → default artwork
  for photo-less rows (EN+CN keyword table — ORDER MATTERS, see the ordering-trap
  tests), `CheckResult.iconName`, and `Image.iconSized(_:)` (custom assets don't
  respond to `.font`/`.imageScale`). SF Symbols remain correct for generic chrome
  (plus/trash/folder/chevron…) and the widget (no app-asset dependency).
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
- **Deletes are SOFT (Phase-2 tombstones), not hard** — user-facing deletion never calls
  `modelContext.delete`; it stamps `deletedAt` (+ bumps `modifiedAt`) via the model
  `markDeleted(now:)` helpers so the deletion propagates on cross-platform merge instead of
  a peer re-adding the row. `markDeleted` cascades by walking RAW relationships:
  context → categories → items → checks; item → checks; **category is self-only** (the
  delete-category UX moves items to Uncategorized first). A tombstoned row is hidden
  everywhere via the `deletedAt == nil` predicate on every `@Query`/`FetchDescriptor` AND
  the `unwrappedCategories`/`unwrappedItems`/`unwrappedChecks`/`allItems`/`lastCheck`
  accessors (which now filter) — but **export walks the RAW relationships so tombstones ship
  in the backup**. Any new query/accessor/fetch over models MUST exclude tombstones; any new
  mutation MUST `touch()` (bump `modifiedAt`) for LWW. Always keep ≥1 *live* context.
  (Underlying SwiftData delete rules are unchanged — context→categories `.cascade`,
  category→items `.nullify`, item→checks `.cascade` — but the soft-delete path never
  triggers them.)
- **Merge is last-write-wins + tombstones** (`DataImporter.merge`, Phase 2): uuid-keyed,
  newer `modifiedAt` wins, newer `deletedAt` removes; checks are append-only union with a
  monotonic tombstone. An OLDER backup never clobbers newer local data; a NEWER one can
  update/remove. Wire format adds optional `deletedAt` to every entity (`docs/SCBK1_Format.md`
  §5/§6). Android's importer is still Phase-1 additive until its matching update lands
  (forward-compatible — it just skips `deletedAt`).
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
- **Destructive actions always confirm** — items, contexts, categories-with-items, and
  check records all route through a confirmationDialog before deletion, from every
  entry point (toolbar, swipe, long-press menu). Never wire a long-press menu Delete
  straight to the mutation.
- **Quick check is the primary check flow** — leading swipe / long-press "Mark as
  Checked" logs an OK check (with `Haptics.success()`); the CheckSheet is for
  non-OK results, backdating, notes, and quantity updates. New list surfaces showing
  items should offer the same affordances.
- Debounce pattern: `task(id:)` + `guard (try? await Task.sleep(...)) != nil else { return }`
  — a bare `try?` would fall through on cancellation and defeat the debounce.
- Design values come from `Theme`; cards via `.cardStyle()`; status via `StatusBadge` /
  `SupplyStatus.style`.

## Testing

- `MyInventoryTests/` — XCTest unit tests (`@MainActor`, in-memory `ModelContainer`):
  derived status & precedence (incl. the exact-due-instant boundary), status labels,
  fuzzy search (incl. context-name + check-comment fields), the notification planner
  (incl. same-day batching + cap-counts-days-not-items), the attention digest,
  fire-date clamping, deep-link parsing (incl. batch ids), JSON export round-trip,
  template idempotency, the Uncategorized move, orphan-safe context deletion, and the
  Iconography lookups (context/status/check-result icons + keyword-table ordering traps).
- `MyInventoryUITests/` — XCUITest. Launch with `-uiTesting` (in-memory store + seeded
  sample data + stays on the sidebar). Covers: launch state, app-wide search across
  contexts, context drill-down, adding a context. Run with
  `-parallel-testing-enabled NO` (see Commands). (Swipe-to-delete is intentionally not
  UI-tested — unreliable on a split-view sidebar; the delete logic is unit-tested.)

## CI & PR review

- **CI** (`.github/workflows/ci.yml`): on push / PR to `main` (doc-only `docs/**` changes
  skip), a `macos-latest` runner (a standard runner → **free on this public repo**) runs
  `xcodebuild test` against an iPad Pro 11" simulator whose id is resolved at runtime from
  `xcodebuild -showdestinations` (scheme-valid destinations only — never a hardcoded device
  name, which breaks when the runner's Xcode ships a different chip suffix). Separate
  `unit-tests` + `ui-tests` jobs; **both run serially** (`-parallel-testing-enabled NO`) —
  parallel simulator clones intermittently fail to launch the unsigned test runner
  ("crashed while preparing to run tests").

- **Merge discipline — clear codex's findings, then merge (NOT just CI)** (shared convention
  with the `Brief-CC` repo). CI green is necessary but **not sufficient**: the async codex
  review (`chatgpt-codex-connector[bot]`) never APPROVEs and is not a status check — **it
  signals with an emoji REACTION on the PR itself**: 👀 (`eyes`) = still reviewing, 👍 (`+1`)
  = reviewed with **no findings**. A clean pass leaves ZERO comment threads — **the 👍
  reaction is the only signal**; findings instead arrive as P-badge review-comment threads.
  So checking review threads ALONE is a trap (a not-yet-reviewed PR and a clean-reviewed PR
  both show 0 threads) — **always also check the reaction**. Reactions are event-driven;
  don't chase whether codex re-reviewed the exact HEAD.
  1. **Wait for codex to actually finish** — it must have reacted 👍 *or* posted findings.
     **Never merge while it's still 👀, or before it has reacted at all** (that's the miss we
     keep making). After you fix + push findings, wait for the re-review to settle again.
  2. **Resolve every codex P-badge thread**: fix + push, or reply why it's a false positive
     — either way **resolve the thread** (a reply alone doesn't clear it; the resolve is the
     single "handled" signal).
  3. **Merge when:** CI green · codex has reacted (👍, or all its threads resolved) · **0
     unresolved codex threads** — then merge directly (squash, delete the branch). **No human
     sign-off is required** (don't wait to be told to merge). The two checks:
     ```bash
     # codex reaction: eyes = still reviewing (wait) · +1 = clean · empty = hasn't reviewed yet (wait)
     gh api repos/seandongAne/MyInventory/issues/N/reactions \
       --jq '.[]|select(.user.login|startswith("chatgpt-codex"))|.content'
     # unresolved codex threads — must be 0
     gh api graphql -f query='{repository(owner:"seandongAne",name:"MyInventory"){pullRequest(number:N){reviewThreads(first:100){nodes{isResolved comments(first:1){nodes{author{login}}}}}}}}' \
       --jq '[.data.repository.pullRequest.reviewThreads.nodes[]|select((.comments.nodes[0].author.login|startswith("chatgpt-codex")) and (.isResolved==false))]|length'
     ```
- ⚠️ **Never write a literal `@`+`codex` mention** in a PR comment or committed doc — codex
  parses it and replies with a config notice (pure noise).
