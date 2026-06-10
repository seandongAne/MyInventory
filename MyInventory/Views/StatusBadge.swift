//
//  StatusBadge.swift
//  MyInventory
//
//  Reusable status capsule. Status is conveyed by symbol + color + text (or symbol-only
//  in compact mode with a full accessibility label) — never color alone.
//

import SwiftUI

struct StatusBadge: View {
    let status: SupplyStatus
    var compact: Bool = false

    /// System "Increase Contrast" (Settings → Accessibility → Display & Text
    /// Size) switches the badge from tinted to a SOLID fill — no app-private
    /// toggle; users who need it have already opted in device-wide.
    @Environment(\.colorSchemeContrast) private var contrast

    /// `.neverExpires` always stays tinted: its neutral gray fill can't carry
    /// 4:1 ink in light mode, and it's informational, not a signal state.
    private var filled: Bool {
        contrast == .increased && status != .neverExpires
    }

    var body: some View {
        let s = status.style
        HStack(spacing: Theme.spacing2) {
            Image(s.iconName)
                .iconSized(11)
            if !compact {
                Text(s.label)
                    .font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(filled ? Theme.badgeInkOnFill : s.color)
        .padding(.horizontal, Theme.spacing4)
        .padding(.vertical, Theme.spacing2)
        .background(filled ? s.color : s.color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(s.label))
    }
}

#Preview("StatusBadge – all states") {
    VStack(alignment: .leading, spacing: 12) {
        StatusBadge(status: .overdue)
        StatusBadge(status: .dueSoon)
        StatusBadge(status: .ok)
        StatusBadge(status: .neverChecked)
        StatusBadge(status: .neverExpires)
        Divider()
        HStack(spacing: 8) {
            StatusBadge(status: .overdue, compact: true)
            StatusBadge(status: .dueSoon, compact: true)
            StatusBadge(status: .ok, compact: true)
        }
    }
    .padding()
}
