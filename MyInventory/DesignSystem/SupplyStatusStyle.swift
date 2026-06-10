//
//  SupplyStatusStyle.swift
//  MyInventory
//
//  Maps SupplyStatus → visual treatment (color, icon, label).
//  Never recomputes status — only consumes the existing enum.
//
//  `iconName` is the custom template asset (Assets.xcassets/Icons) used by
//  the app UI; `symbol` is the SF Symbol equivalent kept for surfaces that
//  require symbol names (widget snapshot UI, App Intents, notifications).
//

import SwiftUI

struct StatusStyle {
    let color: Color
    let iconName: String
    let symbol: String
    let label: String
}

extension SupplyStatus {
    var style: StatusStyle {
        switch self {
        case .overdue:
            StatusStyle(color: Theme.statusOverdue,
                        iconName: "icon-status-overdue",
                        symbol: "exclamationmark.circle.fill",
                        label: "Overdue")
        case .dueSoon:
            StatusStyle(color: Theme.statusDueSoon,
                        iconName: "icon-status-due-soon",
                        symbol: "clock.badge.exclamationmark",
                        label: "Due soon")
        case .needsAttention:
            StatusStyle(color: Theme.statusNeedsAttention,
                        iconName: "icon-status-attention",
                        symbol: "exclamationmark.triangle.fill",
                        label: "Needs attention")
        case .ok:
            StatusStyle(color: Theme.statusOK,
                        iconName: "icon-status-ok",
                        symbol: "checkmark.circle.fill",
                        label: "OK")
        case .neverChecked:
            StatusStyle(color: Theme.statusNeverChecked,
                        iconName: "icon-status-never-checked",
                        symbol: "questionmark.circle.fill",
                        label: "Needs first check")
        case .neverExpires:
            StatusStyle(color: Theme.statusNoExpiry,
                        iconName: "icon-status-no-expiry",
                        symbol: "infinity",
                        label: "No expiry")
        }
    }
}
