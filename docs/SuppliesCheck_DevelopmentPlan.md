# SuppliesCheck — Development Plan & Technical Specification

**Companion to:** SuppliesCheck_PRD.md
**Target:** Native iOS app, SwiftUI + SwiftData + CloudKit
**Intended consumer:** Cowork / Claude Code session on macOS (Xcode project)

---

## 1. Tech Stack & Project Setup

| Concern | Choice | Rationale |
|---|---|---|
| Language / UI | Swift + SwiftUI | Native, modern, best dictation + notification integration |
| Persistence | SwiftData (`@Model`) | First-party, integrates directly with SwiftUI `@Query` |
| Sync | SwiftData + CloudKit **private** database | Zero backend, uses user's own iCloud, offline-first |
| Min deployment target | **iOS 17.0+** (prefer 18.0+ if acceptable) | SwiftData requires 17; 18 has fewer SwiftData bugs. Confirm the user's iPad iOS version. |
| Notifications | `UserNotifications` (local `UNCalendarNotificationTrigger`) | No server needed |
| Voice | System keyboard dictation (free) + optionally `Speech` framework for an in-app mic button | On-device, offline |
| Photos | `PhotosPicker` + store image as external-storage Data attribute | Single photo v1 |

### Capabilities / entitlements to enable in Xcode
- iCloud → CloudKit, with a container `iCloud.<bundleID>`
- Background Modes → Remote notifications (for CloudKit push-driven refresh) — optional but recommended
- Push Notifications
- The bundle ID lives under the developer's Apple Developer Program team

### CloudKit setup note
After enabling the CloudKit container, allow time for the container to provision before first sync test. Deploy the schema from Development to Production environment in the CloudKit dashboard before distributing via TestFlight, or synced records created by testers may not migrate cleanly.

### Development environment (recommended)
Build with **Xcode 26.3's built-in Claude Agent** rather than (or alongside) Cowork/Claude Code CLI. The Agent uses the same harness as Claude Code but adds **Preview visual verification** — it captures SwiftUI Previews, sees the rendered UI, and iterates against the §6 design spec. This closes the "can't see its own UI" gap that otherwise forces manual screenshot/log round-trips on native work.
- Authentication: OAuth via your existing Claude subscription (no manual API key); Xcode itself is free with your Apple Developer Program membership.
- CLI alternative: if you prefer the Claude Code/Cowork terminal flow, Xcode 26.3 also exposes Previews over MCP, so you can still get visual verification from the CLI. For raw build/test/simulator control from CLI, a community skill like `using-xcode-cli-skill` wraps `xcodebuild` / `xcrun simctl`.

---

## 2. SwiftData Model — CloudKit-Compatible

> **Hard CloudKit rules baked into this schema (verified against current SwiftData/CloudKit guidance):**
> 1. **No `@Attribute(.unique)`** anywhere — CloudKit cannot enforce uniqueness.
> 2. **Every stored property is optional OR has a default value.**
> 3. **Every relationship is optional and has an explicit inverse.**
> 4. **No `.deny` delete rules** — use `.cascade` or `.nullify`.
> 5. **Schema changes after sync goes live must be additive** (lightweight-migration-safe). Design generously now.
> 6. Use computed "unwrapped" accessors over optional relationship arrays to keep call sites clean.

```swift
import Foundation
import SwiftData

// MARK: - Context (the three top-level tabs)
// Modeled as DATA (not a hardcoded enum) per PRD P2-2 insurance — cheap now, avoids migration later.
@Model
final class SupplyContext {
    var name: String = ""                 // "Vehicle" | "Bag" | "House"
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    // optional + inverse, cascade so deleting a context removes its categories
    @Relationship(deleteRule: .cascade, inverse: \SupplyCategory.context)
    var categories: [SupplyCategory]? = []

    init(name: String = "", sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = .now
    }

    var unwrappedCategories: [SupplyCategory] {
        (categories ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }
}

// MARK: - Category (within a context)
@Model
final class SupplyCategory {
    var name: String = ""                 // e.g. "Survival Essentials"
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    var context: SupplyContext?           // inverse of SupplyContext.categories

    // nullify (NOT deny/cascade): deleting a category should not silently destroy items.
    // App logic moves items to an "Uncategorized" category instead (see PRD Q3).
    @Relationship(deleteRule: .nullify, inverse: \SupplyItem.category)
    var items: [SupplyItem]? = []

    init(name: String = "", sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = .now
    }

    var unwrappedItems: [SupplyItem] { items ?? [] }
}

// MARK: - Item
@Model
final class SupplyItem {
    var name: String = ""

    // Re-check cadence. nil => "never expires": never flagged, never notified.
    // Stored in months as the canonical unit; UI can expose months/years.
    var checkIntervalMonths: Int? = nil

    // Optional advance-warning override (days). nil => use the global default from Settings.
    var leadTimeDaysOverride: Int? = nil

    var storageLocation: String? = nil     // optional free text, e.g. "Garage shelf 2"

    // Single optional photo (v1). External storage keeps the DB light.
    @Attribute(.externalStorage) var photo: Data? = nil

    var createdAt: Date = Date.now

    var category: SupplyCategory?          // inverse of SupplyCategory.items

    @Relationship(deleteRule: .cascade, inverse: \CheckRecord.item)
    var checks: [CheckRecord]? = []

    init(name: String = "", checkIntervalMonths: Int? = nil) {
        self.name = name
        self.checkIntervalMonths = checkIntervalMonths
        self.createdAt = .now
    }

    var unwrappedChecks: [CheckRecord] {
        (checks ?? []).sorted { $0.date > $1.date }   // newest first
    }

    var lastCheck: CheckRecord? { unwrappedChecks.first }
}

// MARK: - CheckRecord (one historical check event)
@Model
final class CheckRecord {
    var date: Date = Date.now
    var resultRaw: String = CheckResult.ok.rawValue   // store enum as String for CloudKit safety
    var comment: String? = nil                        // optional, may come from voice dictation

    var item: SupplyItem?                              // inverse of SupplyItem.checks

    init(date: Date = .now, result: CheckResult = .ok, comment: String? = nil) {
        self.date = date
        self.resultRaw = result.rawValue
        self.comment = comment
    }

    var result: CheckResult {
        get { CheckResult(rawValue: resultRaw) ?? .ok }
        set { resultRaw = newValue.rawValue }
    }
}

// Plain enum, persisted via resultRaw String (do NOT store enum directly w/ CloudKit edge cases)
enum CheckResult: String, CaseIterable, Identifiable {
    case ok = "OK"
    case replaced = "Replaced"
    case needsAttention = "Needs attention"
    var id: String { rawValue }
}
```

### 2.1 Derived status (NOT stored — computed on the fly)

```swift
enum SupplyStatus { case neverExpires, neverChecked, ok, dueSoon, overdue }

extension SupplyItem {
    func nextDueDate(calendar: Calendar = .current) -> Date? {
        guard let months = checkIntervalMonths else { return nil } // never expires
        guard let last = lastCheck?.date else { return nil }       // never checked → handled in status
        return calendar.date(byAdding: .month, value: months, to: last)
    }

    func status(leadTimeDays globalLead: Int,
                now: Date = .now,
                calendar: Calendar = .current) -> SupplyStatus {
        guard checkIntervalMonths != nil else { return .neverExpires }
        guard lastCheck != nil, let due = nextDueDate(calendar: calendar) else {
            return .neverChecked   // PRD Q1 default: treat as due immediately
        }
        let lead = leadTimeDaysOverride ?? globalLead
        guard let warnDate = calendar.date(byAdding: .day, value: -lead, to: due) else { return .ok }
        if now >= due { return .overdue }
        if now >= warnDate { return .dueSoon }
        return .ok
    }
}
```

> **Why status is never stored:** with CloudKit sync, a stored status would go stale the moment "today" advances on another device, and would create needless sync churn/conflicts. Deriving it is cheap and always correct.

---

## 3. App Settings (single-user, stored locally)

A small settings store (can be `@AppStorage` / a single SwiftData settings record):
- `globalLeadTimeDays: Int` (default e.g. 7)
- `defaultIntervalMonths: Int?` (optional convenience default for new items)
- iCloud sync status (read-only display: on/off, derived from account availability)

---

## 4. Search (fuzzy) — implementation note

SwiftData `#Predicate` only supports substring `contains`, **not** true fuzzy matching. Approach:
1. Use a `#Predicate` `contains` filter for cheap server-side narrowing when the query is long enough.
2. For genuine fuzzy/typo tolerance, fetch the (bounded, ≤ few hundred) candidate set and rank in memory with a lightweight algorithm (e.g. Levenshtein distance or token-based scoring) over `name`, `category.name`, and `storageLocation`.
3. Given the dataset is at most a few hundred items, in-memory fuzzy ranking on every keystroke (debounced) is perfectly performant. No external dependency required; a ~30-line Levenshtein/`fuzzyScore` helper suffices.

---

## 5. Notifications — scheduling logic

- On item create/edit and on each logged check, **reschedule** that item's notifications:
  1. Cancel existing pending requests for the item (use a stable identifier prefix, e.g. `item-<uuid>-due` and `item-<uuid>-lead`).
  2. If `checkIntervalMonths == nil` → schedule nothing (never expires).
  3. Else compute `nextDueDate`; schedule a `UNCalendarNotificationTrigger` on that date.
  4. If a lead time applies, schedule a second notification at `nextDueDate - leadDays`.
- Request authorization on first relevant action (not at cold launch — ask in context the first time the user sets an interval).
- Because a single user may have hundreds of items, stay well under the iOS **64 pending local notification** limit: schedule notifications only for items whose next due date is within a rolling window (e.g. the next 60–90 days), and refresh the schedule on app foreground. This is the standard workaround for the 64-notification cap and must be implemented — do not naïvely schedule all items.

> **Identifier note:** SwiftData's CloudKit mode forbids `.unique`, but you still need a stable per-item key for notification IDs. Use SwiftData's built-in `persistentModelID` or add a non-unique `var uuid: UUID = UUID()` default property and treat it as a logical (not DB-enforced) identifier.

---

## 6. SwiftUI / HIG Design Specification

This section is the design contract for the UI. The goal is a clean, native, "feels like an Apple app" result — not a custom-skinned look. When using Xcode 26.3's Agent with Preview visual verification, treat this section as the acceptance reference the Agent iterates against.

### 6.1 Design principles
- **Native first.** Use stock SwiftUI components (`List`, `Form`, `NavigationSplitView`, `Toggle`, `DatePicker`, `Picker`, `Stepper`, `Label`, `searchable`). Do not reinvent controls or pull in third-party UI libraries. Stock components give free Dark Mode, Dynamic Type, accessibility, and platform consistency.
- **Defer to the system for color.** Use semantic colors (`Color.primary`, `.secondary`, `Color(.systemBackground)`, `Color(.secondarySystemBackground)`) so light/dark mode are automatic. Reserve explicit colors only for the status semantics in §6.4.
- **Content over chrome.** Minimal custom backgrounds; let grouped `List`/`Form` provide structure. No gradients or shadows unless they carry meaning.
- **One accent color.** Set a single app accent (a calm, outdoorsy tone fits the survival-supplies theme, e.g. a deep green or slate teal). Everything interactive inherits it. Do not scatter multiple brand colors.

### 6.2 Spacing & layout metrics
Follow the 8-point grid. Concrete values for this app:

| Use | Value |
|---|---|
| Base grid unit | 8 pt (use multiples: 4, 8, 16, 24, 32) |
| Screen edge margins | system default for `List`/`Form` (don't override); 16 pt for custom content views |
| Vertical gap between unrelated blocks | 24 pt |
| Vertical gap between related rows / within a card | 8–12 pt |
| Inside a status badge (h-padding / v-padding) | 8 / 4 pt |
| Min tap target | **44 × 44 pt** (HIG hard minimum — applies to badges-as-buttons, icon buttons) |
| Item thumbnail (photo) in a row | 44 × 44 pt, `clipShape(.rect(cornerRadius: 8))` |
| Corner radius (cards / thumbnails) | 8–12 pt, consistent throughout |
| Section header → first row | rely on `List` section spacing; don't hand-tune |

- Prefer `.listStyle(.insetGrouped)` on the item/category screens for the familiar grouped look.
- Use `LabeledContent` for read-only key/value rows in the detail view (e.g. "Next due — 10 Sept 2026").
- Respect Dynamic Type: never hardcode font sizes; use text styles (`.headline`, `.subheadline`, `.body`, `.caption`). Test at the largest accessibility size — badges must wrap or truncate gracefully.

### 6.3 SF Symbols usage
Use SF Symbols throughout for visual consistency and free Dynamic Type / dark-mode behavior. Render with `Label(_, systemImage:)` so text+icon pair correctly, and use `.symbolRenderingMode(.hierarchical)` or `.palette` where it adds clarity. Suggested symbol vocabulary:

| Meaning | SF Symbol | Notes |
|---|---|---|
| Vehicle context | `car.fill` | Tab + section icon |
| Bag context | `backpack.fill` | Tab + section icon |
| House context | `house.fill` | Tab + section icon |
| Due dashboard (P1) | `exclamationmark.triangle.fill` | Only if the P1 Home tab is built |
| Settings | `gearshape.fill` | Standard |
| Add item / category | `plus` (in a toolbar `Button`) | Use `.plus.circle.fill` for prominent inline add |
| Check now | `checkmark.circle.fill` | Primary action in detail |
| Overdue status | `exclamationmark.circle.fill` | Paired with red (§6.4) |
| Due soon status | `clock.badge.exclamationmark` | Paired with orange/yellow |
| OK / up to date | `checkmark.circle` | Paired with green |
| Never expires | `infinity` | Paired with gray |
| Never checked | `questionmark.circle` | Treated as due; paired with red/orange |
| Storage location present | `mappin.and.ellipse` | Small secondary indicator on the row |
| Photo present | `photo` | Small secondary indicator on the row |
| Voice dictation | `mic.fill` | On the comment field / in-app mic button |
| History | `clock.arrow.circlepath` | Section header for the check log |
| Delete (swipe) | `trash` | Standard destructive swipe action |
| Search | `magnifyingglass` | Provided automatically by `.searchable` |

Guidance: keep symbol weight matching the adjacent text weight; use `.imageScale(.medium)` for row indicators; never mix filled and outline variants for the same concept.

### 6.4 Status badge color system
Status is derived (§2.1), and each status maps to exactly one symbol + color pairing. Keep it consistent everywhere a status appears (rows, detail header, dashboard).

| Status | Color (semantic) | SF Symbol | Label text |
|---|---|---|---|
| Overdue | `.red` | `exclamationmark.circle.fill` | "Overdue" (+ "by N days" if useful) |
| Due soon | `.orange` | `clock.badge.exclamationmark` | "Due in N days" |
| OK / up to date | `.green` | `checkmark.circle` | "OK" (or next-due date) |
| Never checked | `.red` (or `.orange`) | `questionmark.circle` | "Needs first check" |
| Never expires | `.secondary` / `.gray` | `infinity` | "No expiry" |

Badge construction guidance:
- Build a reusable `StatusBadge` view: a capsule with `.padding(.horizontal, 8).padding(.vertical, 4)`, `background(color.opacity(0.15))`, `foregroundStyle(color)`, an SF Symbol + short label, `clipShape(.capsule)`.
- **Do not rely on color alone** — always pair color with the symbol and text, so the status is legible for color-blind users and in grayscale (accessibility requirement).
- Use the system's semantic `.red/.orange/.green` (not custom hex) so they adapt in Dark Mode and Increase Contrast.
- Overdue rows: additionally apply a subtle leading accent (e.g. a thin red capsule/edge or a tinted row background `red.opacity(0.06)`) and **pin to the top** of each section, so overdue items are unmissable at a glance.

### 6.5 iPad split-view layout
The iPad is the primary device, so design for `NavigationSplitView` first; iPhone collapses it automatically.

- **Three-column on iPad** (recommended):
  - **Sidebar (column 1):** the three contexts (Vehicle / Bag / House) + Settings, optionally the P1 "Due" dashboard at top. Each row a `Label` with its context SF Symbol.
  - **Content (column 2):** for the selected context, the grouped list of categories → items, with overdue pinned & badged. The `.searchable` field lives here.
  - **Detail (column 3):** the selected item's `ItemDetailView` (fields, "Check now", history).
- Use `NavigationSplitView(columnVisibility:)` and let the system manage collapse. Provide `.navigationSplitViewStyle(.balanced)`.
- **Selection state:** drive columns with `@State` selection bindings (selected context → selected item) so the split view stays in sync and restores on relaunch.
- **Adaptivity:** on iPhone (or iPad in Slide Over / narrow split-screen multitasking) the same code collapses to a single navigation stack — verify both. Never assume a fixed width.
- **Empty states:** the detail column needs a graceful empty state when nothing is selected (e.g. a centered SF Symbol + "Select an item" `ContentUnavailableView`). Use `ContentUnavailableView` for empty lists too ("No items yet", "No results" for search).
- **Orientation & size classes:** support both portrait and landscape; rely on size classes rather than device checks.
- **Toolbar placement:** put "Add" in the content column's toolbar (`.topBarTrailing`); put item-level actions (Check now, delete) in the detail toolbar.

### 6.6 Quick acceptance checklist for UI work
- [ ] All interactive elements ≥ 44×44 pt.
- [ ] No hardcoded font sizes; everything uses text styles and survives the largest Dynamic Type size.
- [ ] Status is conveyed by symbol + text, not color alone; legible in Dark Mode and grayscale.
- [ ] Overdue items pinned to top and visually distinct in every list.
- [ ] `NavigationSplitView` works on iPad (3-column) and collapses cleanly on iPhone.
- [ ] `ContentUnavailableView` used for all empty/no-selection/no-results states.
- [ ] Only stock SwiftUI components; single accent color; semantic colors elsewhere.
- [ ] VoiceOver: every status badge, icon button, and row has a sensible accessibility label.

---

## 7. Screen / Navigation Map

```
TabView (or sidebar on iPad)
├── [Optional P1] Home / "Due" dashboard — overdue + due-soon across all contexts
├── Vehicle   ─┐
├── Bag        ├─ ContextView: list of Categories → Items, overdue pinned & highlighted
├── House     ─┘
└── Settings  — lead time, default interval, iCloud status, about

ContextView
└── CategorySection(s)
    └── ItemRow (name, status badge, next-due, location/photo indicators)
        └── ItemDetailView
            ├── edit fields (name, context, category, interval, lead override, location, photo)
            ├── "Check now" button → CheckSheet (date, result picker, comment + dictation)
            └── History list (CheckRecord rows)

Global: search field filtering items (fuzzy) — scoped to current context or all.
```

On iPad, prefer `NavigationSplitView` (sidebar = contexts/categories, detail = items) for a native iPad feel; on iPhone it collapses to a stack automatically.

---

## 8. Milestones / Phased Build

Each milestone is independently demoable.

### M0 — Project scaffold & schema (foundation)
- Xcode project, bundle ID under the dev account, iOS target set.
- SwiftData models exactly as §2; **local-only first** (no CloudKit yet — easier to iterate on schema before sync locks it in).
- Seed the three default contexts on first launch.
- *Exit:* app builds, models persist locally, three tabs appear.

### M1 — Core CRUD + grouping (P0-1, P0-2)
- Add/edit/remove items and categories; two-level grouping renders.
- "Uncategorized" fallback bucket for orphaned items.
- *Exit:* can fully manage the structure from the paper note (tuna, knife, water, bear spray, stove) by hand.

### M2 — Checks + history + derived status (P0-3, P0-5, P0-9)
- "Check now" sheet creating `CheckRecord`; recompute next-due.
- Status badges (OK / due soon / overdue / never expires / never checked).
- Overdue pinned & highlighted; per-item history list.
- *Exit:* logging a check moves the next-due date and writes history; overdue items rise to the top.

### M3 — Voice dictation comment (P0-4)
- Comment field with system dictation; optionally an in-app `Speech`-framework mic button for a nicer flow.
- *Exit:* user can dictate a note offline and it saves on the check.

### M4 — Notifications + lead time (P0-6, P0-7)
- Authorization flow, scheduling/rescheduling logic, rolling-window scheduler (≤64 cap workaround), global lead-time setting + per-item override.
- *Exit:* due-date and lead-time notifications fire correctly; never-expires items schedule nothing; rescheduling on check works.

### M5 — Search + photos + location (P0-8, plus item photo/location from P0-1)
- Debounced fuzzy search across name/category/location.
- `PhotosPicker` single photo (external storage); optional location text.
- *Exit:* typo-tolerant search works on a few-hundred-item set; photo + location are fully optional and never block saving.

### M6 — iCloud sync (P0-11, P0-10 verified)
- Enable CloudKit container; flip SwiftData `ModelConfiguration` to use CloudKit.
- **Re-verify schema obeys all CloudKit rules** (this is where violations surface as console errors).
- Graceful degradation when iCloud is off/unavailable.
- Test convergence across two devices/simulators on one Apple ID; test airplane-mode full functionality.
- Deploy CloudKit schema to Production before TestFlight.
- *Exit:* two iPads converge; offline still fully works; toggling iCloud off doesn't lose data or crash.

### M7 — Polish + TestFlight delivery
- iPad layout pass (`NavigationSplitView`), empty states, accessibility (Dynamic Type, VoiceOver labels on status badges).
- Archive, upload, internal TestFlight, invite the end user.
- *Exit:* user installs via TestFlight and runs the real workflow.

### Post-v1 (P1 backlog, optional fast-follows)
Manual check dates, edit/delete individual check records, sort/filter controls, the unified Due dashboard, snooze, CSV export.

---

## 9. Key Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Schema locked by CloudKit after sync goes live | Build & iterate **local-only through M5**; enable CloudKit only at M6 once the model is stable; design additively. |
| 64 pending-notification iOS cap with hundreds of items | Rolling-window scheduler (§5); never schedule all items at once. |
| `@Query` not refreshing on silent CloudKit push | Use dynamic `@Query`; if rows don't update on remote push, apply the known dynamic-query refresh pattern. |
| Stored status going stale across devices | Status is always derived, never stored (§2.1). |
| TestFlight builds expiring (~90 days) | Calendar reminder to re-upload; trivial once pipeline exists. |
| User's iPad on iOS < 17 | Confirm iOS version early (blocks SwiftData entirely). |

---

## 10. Immediate Next Actions for the Cowork/Xcode session

1. Confirm the end user's iPad iOS version (must be 17+; prefer 18+).
2. Resolve PRD Open Questions Q1–Q3 (defaults already recommended; can proceed on defaults if user is unavailable).
3. Create the Xcode project under the developer-account team; set bundle ID + CloudKit container name now (even if CloudKit is toggled on later at M6).
4. Implement M0 schema verbatim from §2 and seed the three contexts.
5. Proceed milestone by milestone, keeping CloudKit OFF until M6.
