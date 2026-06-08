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
