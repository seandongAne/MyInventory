# SuppliesCheck — UI Redesign Specification

**For:** Claude (Sonnet 4.6) running as the Xcode 26.x coding agent
**Goal:** Replace the default "iOS Settings page" look with a distinctive, polished, cohesive visual design — **without changing the app's architecture, data model, CloudKit sync, notifications, or business logic.**
**Scope:** Presentation layer only. Do not touch SwiftData models, the sync configuration, notification scheduling, or the derived-status logic. Only change views, styling, and view-local animation state.

---

## 0. How to use this document

You are upgrading an existing, working SwiftUI app whose UI currently relies on default `List` / `.insetGrouped` styling, which makes every screen look like the system Settings app. Work **incrementally and verifiably**:

1. Implement the design system files in §2 first (Theme, reusable components).
2. Migrate ONE screen (the item list inside a context) to the new look using §5, build it, and capture the Xcode Preview to verify it matches the intent in §1 before proceeding.
3. Roll the same patterns out to the remaining screens.
4. Add motion (§6) last, once layout and color read correctly.

After each screen migration, **capture the Preview and self-check against the §8 acceptance checklist.** Do not batch all screens in one pass — verify visually as you go.

Hard rule: **only stock SwiftUI + system frameworks. No third-party UI packages, no Swift Package dependencies.** The "designed" feel comes from custom styling of native components, not from a component library.

---

## 1. Aesthetic Direction (commit to this)

**Concept: "Field-ready / refined outdoor utility."** This is a personal survival-and-camping supplies tracker. The feel should be **calm, grounded, and trustworthy** — like a well-made piece of outdoor gear, not a flashy consumer app and *definitely* not a system settings screen. Refined minimalism with depth, not maximalist decoration.

The one memorable thing: **status is communicated through the entire card's visual treatment** (a colored edge, a tinted surface, a badge) so the user feels the state of their supplies at a glance, not by reading a row of plain text.

Principles:
- **Depth over flatness.** Cards float on a quiet background with soft shadows and system materials. The eye perceives a hierarchy of surfaces.
- **One dominant accent, sharp status accents.** A single calm brand accent for interactive elements; saturated status colors used sparingly and only for meaning.
- **Generous, consistent spacing.** Breathing room is what separates "designed" from "dense settings list."
- **Quiet typography hierarchy** with one slightly characterful display treatment for screen titles, refined system text for everything else.
- **Motion that confirms, never distracts.** Smooth state transitions and a tactile check action; no gratuitous animation.

---

## 2. Design System (build these files first)

Create a `DesignSystem/` group. These are the single source of truth — every view references these, no hardcoded values anywhere else.

### 2.1 `Theme.swift` — design tokens

```swift
import SwiftUI

enum Theme {

    // MARK: Brand
    /// Single dominant accent — a calm, grounded slate-teal/deep green.
    /// Define in the asset catalog as a Color Set with light + dark variants for best results,
    /// then reference as Color("BrandAccent"). Fallback literal shown here.
    static let accent = Color(red: 0.16, green: 0.42, blue: 0.40)        // slate teal
    static let accentSoft = Color(red: 0.16, green: 0.42, blue: 0.40).opacity(0.12)

    // MARK: Status (semantic — keep meaning consistent everywhere)
    static let statusOverdue   = Color(red: 0.83, green: 0.24, blue: 0.22) // grounded red
    static let statusDueSoon   = Color(red: 0.90, green: 0.55, blue: 0.13) // amber
    static let statusOK        = Color(red: 0.20, green: 0.55, blue: 0.36) // green
    static let statusNeverChecked = Color(red: 0.83, green: 0.24, blue: 0.22)
    static let statusNoExpiry  = Color.secondary

    // MARK: Surfaces & text (prefer semantic system colors so dark mode is automatic)
    static let screenBackground = Color(.systemGroupedBackground)
    static let cardSurface      = Color(.secondarySystemGroupedBackground)
    static let textPrimary      = Color.primary
    static let textSecondary    = Color.secondary

    // MARK: Geometry
    static let cardCornerRadius: CGFloat = 16
    static let controlCornerRadius: CGFloat = 12
    static let badgeCornerRadius: CGFloat = 8

    // MARK: Spacing (8-pt grid)
    static let spacing2: CGFloat = 4
    static let spacing4: CGFloat = 8
    static let spacing6: CGFloat = 12
    static let spacing8: CGFloat = 16
    static let spacing12: CGFloat = 24
    static let spacing16: CGFloat = 32

    // MARK: Shadow (soft, single direction, low opacity — the key to "float")
    static let cardShadowColor = Color.black.opacity(0.08)
    static let cardShadowRadius: CGFloat = 10
    static let cardShadowY: CGFloat = 4

    // MARK: Animation
    static let springQuick = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let springGentle = Animation.spring(response: 0.45, dampingFraction: 0.85)
}
```

> **Asset catalog note:** For the best result, define `BrandAccent`, and the four status colors, as **Color Sets in `Assets.xcassets`** with explicit Any/Dark appearances, then reference via `Color("BrandAccent")`. The literals above are fallbacks so the code compiles immediately. Set the app's global accent in the asset catalog's `AccentColor` to BrandAccent too.

### 2.2 `SupplyStatusStyle.swift` — map derived status → visual treatment

Do **not** recompute status here; consume the existing `SupplyStatus` enum from the logic layer. This only maps a status value to its color, symbol, and label.

```swift
import SwiftUI

struct StatusStyle {
    let color: Color
    let symbol: String
    let label: String
}

extension SupplyStatus {
    var style: StatusStyle {
        switch self {
        case .overdue:
            StatusStyle(color: Theme.statusOverdue, symbol: "exclamationmark.circle.fill", label: "Overdue")
        case .dueSoon:
            StatusStyle(color: Theme.statusDueSoon, symbol: "clock.badge.exclamationmark", label: "Due soon")
        case .ok:
            StatusStyle(color: Theme.statusOK, symbol: "checkmark.circle.fill", label: "OK")
        case .neverChecked:
            StatusStyle(color: Theme.statusNeverChecked, symbol: "questionmark.circle.fill", label: "Needs first check")
        case .neverExpires:
            StatusStyle(color: Theme.statusNoExpiry, symbol: "infinity", label: "No expiry")
        }
    }
}
```

### 2.3 `StatusBadge.swift` — reusable badge

```swift
import SwiftUI

struct StatusBadge: View {
    let status: SupplyStatus
    var compact: Bool = false

    var body: some View {
        let s = status.style
        HStack(spacing: Theme.spacing2) {
            Image(systemName: s.symbol)
                .imageScale(.small)
            if !compact {
                Text(s.label)
                    .font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(s.color)
        .padding(.horizontal, Theme.spacing4)
        .padding(.vertical, Theme.spacing2)
        .background(s.color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(s.label))
    }
}
```

> Color is always paired with a symbol + text (or symbol-only in compact mode with an accessibility label). Never status-by-color-alone.

### 2.4 `Card.swift` — the surface primitive

A reusable container giving the "floating surface" look. Everything that was a `List` row becomes a card (or lives inside one).

```swift
import SwiftUI

struct Card<Content: View>: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .shadow(color: Theme.cardShadowColor, radius: Theme.cardShadowRadius, y: Theme.cardShadowY)
    }
}

extension View {
    func cardStyle() -> some View { modifier(Card()) }
}
```

### 2.5 `PressableButtonStyle.swift` — tactile feedback

```swift
import SwiftUI

struct PressableButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, Theme.spacing6)
            .padding(.horizontal, Theme.spacing8)
            .background(tint, in: RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.springQuick, value: configuration.isPressed)
    }
}
```

---

## 3. Typography

Use the system font but build a clear hierarchy via text styles and weight — never hardcode point sizes (Dynamic Type must keep working).

| Role | Style | Weight | Notes |
|---|---|---|---|
| Screen title | `.largeTitle` | `.bold` | Optionally `.rounded` design for warmth: `.font(.largeTitle.weight(.bold))` + `.fontDesign(.rounded)` |
| Section / category header | `.title3` | `.semibold` | Use `.fontDesign(.rounded)` to match title |
| Card primary (item name) | `.headline` | default | |
| Card secondary (location, next-due) | `.subheadline` | `.regular` | `Theme.textSecondary` |
| Metadata / captions | `.caption` | `.medium` | badges, timestamps |

> Decision: applying `.fontDesign(.rounded)` to titles and headers (not body) gives a friendly, gear-catalog warmth that reads as "designed" while staying native. Apply it once at a high level where practical, or per-text. Keep body text in the default design for legibility.

---

## 4. Screen background

Replace the flat system grouped background with a subtle vertical gradient so cards have something to float on. Keep it quiet — this is atmosphere, not decoration.

```swift
struct ScreenBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Theme.screenBackground,
                Theme.screenBackground.opacity(0.6)
            ],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
```

Apply by placing content in a `ZStack` over `ScreenBackground`, and on any `List`/`ScrollView` set `.scrollContentBackground(.hidden)` so the system gray does not cover it.

---

## 5. Core migration: item list → ScrollView of cards

This is the heart of the redesign. The current screen is almost certainly a `List` of plain rows. Replace it with a `ScrollView { LazyVStack { ... } }` of `ItemCard`s. This is correct for this app's data scale (hundreds of items, not tens of thousands) and is what frees the design from the Settings-list look.

### 5.1 `ItemCard.swift`

```swift
import SwiftUI

struct ItemCard: View {
    let item: SupplyItem
    let status: SupplyStatus      // pass in the already-derived status; do not recompute here
    let nextDueText: String?      // formatted by caller, e.g. "Due 10 Sep 2026"

    var body: some View {
        HStack(spacing: Theme.spacing6) {

            // Leading status accent bar — the at-a-glance signal
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(status.style.color)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            // Optional thumbnail
            thumbnail

            // Text block
            VStack(alignment: .leading, spacing: Theme.spacing2) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                if let nextDueText {
                    Text(nextDueText)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: Theme.spacing4) {
                    StatusBadge(status: status)
                    if let loc = item.storageLocation, !loc.isEmpty {
                        Label(loc, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, Theme.spacing2)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
        }
        .padding(Theme.spacing6)
        .background(
            // subtle status tint on the surface for overdue/dueSoon only
            surfaceTint, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(status.style.color.opacity(status == .overdue ? 0.35 : 0), lineWidth: 1)
        )
        .shadow(color: Theme.cardShadowColor, radius: Theme.cardShadowRadius, y: Theme.cardShadowY)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var thumbnail: some View {
        if let data = item.photo, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable().scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accentSoft)
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: "shippingbox").foregroundStyle(Theme.accent))
        }
    }

    private var surfaceTint: Color {
        switch status {
        case .overdue:  Theme.statusOverdue.opacity(0.06)
        case .dueSoon:  Theme.statusDueSoon.opacity(0.05)
        default:        Theme.cardSurface
        }
    }
}
```

### 5.2 The list screen

```swift
ScrollView {
    LazyVStack(spacing: Theme.spacing6) {
        ForEach(sortedItems) { item in           // overdue first — preserve existing sort
            NavigationLink(value: item) {
                ItemCard(item: item,
                         status: item.status(leadTimeDays: globalLead),
                         nextDueText: formattedNextDue(item))
            }
            .buttonStyle(.plain)                  // keep card visuals, not blue link text
        }
    }
    .padding(.horizontal, Theme.spacing8)
    .padding(.top, Theme.spacing6)
}
.scrollContentBackground(.hidden)
.background(ScreenBackground())
```

> Keep the existing data flow (`@Query`, derived status, overdue-first sort). Only the presentation changes. If the screen previously used swipe-to-delete from `List`, reintroduce delete via a context menu (`.contextMenu`) or a trailing action button on the card, since `ScrollView` has no built-in swipe actions.

### 5.3 Category grouping

Render categories as section headers above each group of cards:

```swift
ForEach(categories) { category in
    VStack(alignment: .leading, spacing: Theme.spacing4) {
        Text(category.name)
            .font(.title3.weight(.semibold))
            .fontDesign(.rounded)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.spacing2)
        ForEach(category.unwrappedItems) { item in /* ItemCard as above */ }
    }
    .padding(.bottom, Theme.spacing8)
}
```

---

## 6. Motion (add last)

Add only after layout and color read correctly. Each item below is high-impact and restrained.

1. **List entrance stagger** — when a context screen appears, cards fade+slide in with a small per-index delay. Cap the delay (e.g. `min(index, 8) * 0.04`) so long lists don't lag.
   ```swift
   .opacity(appeared ? 1 : 0)
   .offset(y: appeared ? 0 : 12)
   .animation(Theme.springGentle.delay(min(Double(index), 8) * 0.04), value: appeared)
   ```
   Set `appeared = true` in `.onAppear`.

2. **Card → detail transition** — use `matchedGeometryEffect` (or the zoom `NavigationTransition` on iOS 18+) so tapping a card expands it into the detail view. On iOS 18+, the simplest path is `.navigationTransition(.zoom(sourceID: item.id, in: namespace))` on the destination and `.matchedTransitionSource(id: item.id, in: namespace)` on the card. Prefer this native zoom transition if the deployment target allows.

3. **Check action feedback** — when the user logs a check, animate the status change with `withAnimation(Theme.springQuick)` so the badge + accent bar recolor smoothly, and trigger a SF Symbol effect on the confirm button: `.symbolEffect(.bounce, value: checkCount)`. Optionally a light haptic via `.sensoryFeedback(.success, trigger: checkCount)`.

4. **Status change** — wrap any model update that changes derived status in `withAnimation` so the card's color treatment cross-fades rather than snapping.

Do **not** add: parallax, continuous looping animations, decorative motion on every element, or anything that fires on scroll. Motion must mean something.

---

## 7. Apply across remaining screens

Once the item-list screen is verified, propagate the same language:

- **Detail screen:** wrap field groups in `cardStyle()` blocks separated by `Theme.spacing12`; a prominent "Check now" button using `PressableButtonStyle`; the history list as a vertical stack of compact cards (date + result badge + comment), not a `List`.
- **Sidebar / context tabs (iPad `NavigationSplitView`):** keep the native sidebar, but give each context row its SF Symbol in the brand accent; the selected row uses `Theme.accentSoft` highlight.
- **Settings:** this screen *may* legitimately keep a grouped `Form` look (settings genuinely are settings) — but unify the accent color and section header typography so it feels part of the same app.
- **Empty / no-selection / no-results states:** use `ContentUnavailableView` with a relevant SF Symbol in the brand accent and a one-line message.
- **Add/Edit sheets:** native `Form` is fine here; apply the brand accent and `PressableButtonStyle` to the primary save action so it doesn't look stock.

---

## 8. Acceptance checklist (self-verify via Preview after each screen)

- [ ] No screen except possibly Settings still reads as the iOS Settings app.
- [ ] Item lists are cards on a gradient background, not default `List` rows.
- [ ] Every card shows status via accent bar + badge (symbol + color), legible in **Dark Mode** and **grayscale** (color is never the only signal).
- [ ] Overdue items are visually unmistakable (tinted surface + edge) and still sorted to the top.
- [ ] Single brand accent used for all interactive/selected elements; status colors used only for status.
- [ ] All spacing/corner/shadow values come from `Theme`; no hardcoded magic numbers in views.
- [ ] Dynamic Type still works at the largest accessibility size (text wraps/truncates gracefully; no clipping).
- [ ] Tap targets ≥ 44×44 pt.
- [ ] `NavigationSplitView` still works on iPad and collapses cleanly on iPhone.
- [ ] VoiceOver: cards read item name + status; badges have labels.
- [ ] Motion is limited to: entrance stagger, card→detail zoom, check-action feedback, status cross-fade. Nothing decorative or scroll-triggered.
- [ ] No third-party packages added; only stock SwiftUI + system frameworks.
- [ ] **No changes** to SwiftData models, CloudKit config, notification scheduling, or status-derivation logic.

---

## 9. Order of operations (do in this sequence)

1. Add `DesignSystem/` with `Theme`, `StatusStyle`, `StatusBadge`, `Card`, `PressableButtonStyle`. Build.
2. Define `BrandAccent` + status Color Sets in `Assets.xcassets` (Any/Dark). Set `AccentColor`. Build.
3. Add `ScreenBackground` and `ItemCard`. Build.
4. Migrate ONE context's item-list screen (§5). Build, capture Preview, check §8. Stop and verify.
5. Propagate to detail, history, sidebar, empty states, sheets (§7). Build after each.
6. Add motion (§6). Build, capture Preview, final §8 pass.

At every build, if a Preview can be captured, capture it and compare against §1's intent before continuing.
