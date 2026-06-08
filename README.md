<div align="center">

# MyInventory

### ✨ Special thanks to **Charlie** ✨
*This app was built for you — so that keeping your supplies in check is never a worry again.*

</div>

---

**MyInventory** is an iOS app for tracking physical emergency, survival, and camping
supplies across the different places you keep them — your vehicle, your go-bag, your
house — and reminding you to **re-check** each item on a schedule *you* define.

The idea is simple: supplies don't expire on a fixed date so much as they need
**periodic inspection or rotation** — water gets stale, a stove stops working, bear
spray goes out of date. Paper checklists don't flag what's overdue, don't keep a
history, and aren't searchable. MyInventory does all three.

## Features

- 🚗 **Organize by context** — group supplies under top-level places (Vehicle, Bag,
  House), and add or remove your own. Each context has its own categories.
- ⏰ **Personal re-check intervals** — set a per-item cadence in months ("inspect the
  stove every 6 months", "rotate the canned tuna every 12"). Items can also *never
  expire*.
- 🚦 **At-a-glance status** — every item shows a derived status: **OK**, **Due soon**,
  **Overdue**, **Needs attention**, **Needs first check**, or **No expiry**. Overdue
  and flagged items float to the top of every list.
- 🔔 **Smart reminders** — local notifications fire on the due date and, optionally, a
  few days early. The schedule respects iOS limits and refreshes automatically.
- 📝 **Check history** — log each check with a result (OK / Replaced / Needs attention)
  and an optional note (hands-free voice dictation supported). Full history per item.
- 🔍 **Fast fuzzy search** — typo-tolerant search across name, category, and location,
  both within a context and **app-wide** from the sidebar.
- 📷 **Photos & locations** — attach a photo and a storage-location note to any item.
- 🛟 **Safe by design** — deleting a category moves its items to *Uncategorized* instead
  of destroying them; a recoverable error screen replaces crashes if the data store
  can't open.

## Tech stack

- **Swift** · **SwiftUI** · **SwiftData** (local-only persistence)
- **UserNotifications** · **PhotosUI** · **UIKit** (camera)
- **XCTest** / **XCUITest** for unit and UI tests
- Targets **iOS 26.5**; built with **Xcode**

Status is **never stored** — it's always derived from each item's most recent check and
its interval, so it can never go stale. iCloud/CloudKit sync is intentionally deferred to
a later milestone while the schema settles; the data model is already CloudKit-safe.

## Getting started

**Requirements:** Xcode with the iOS 26.5 SDK and an iOS 26.5 simulator (or a device).

```bash
# Open in Xcode and press Run, or build from the command line:
xcodebuild build -project MyInventory.xcodeproj -scheme MyInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/MyInv_DD CODE_SIGNING_ALLOWED=NO
```

On first launch the app seeds the three default contexts (Vehicle / Bag / House);
add a category, then start adding the supplies you keep there.

## Testing

```bash
# Unit tests (status logic, notification planner, fuzzy search, orphan-safe deletion)
xcodebuild test -project MyInventory.xcodeproj -scheme MyInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:MyInventoryTests CODE_SIGNING_ALLOWED=NO

# UI tests (launch, app-wide search, context drill-down, add context)
#   swap in: -only-testing:MyInventoryUITests
```

25 unit tests and 4 UI tests cover the logic that's easy to get silently wrong.

## Project structure

```
MyInventory/
├── MyInventoryApp.swift      # App entry, ModelContainer + storage-error fallback
├── ContentView.swift         # Root NavigationSplitView, global search, add/delete context
├── Models/                   # SupplyContext · SupplyCategory · SupplyItem · CheckRecord · SupplyStatus
├── Views/                    # Context list, item detail/edit, check sheet, categories, settings, camera
├── Services/                 # NotificationManager (re-check reminders)
├── Support/                  # SettingsStore · FuzzySearch · SeedData
└── DesignSystem/             # Theme tokens, status styling, cards, backgrounds
```

For a full architecture map — the data model, delete rules, derived-status logic, and the
conventions to preserve — see [`CLAUDE.md`](CLAUDE.md). Product docs live in [`docs/`](docs/).

## Acknowledgments

Once more — **thank you, Charlie.** 🙏 This project exists for you.
