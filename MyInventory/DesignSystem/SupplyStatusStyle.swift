//
//  SupplyStatusStyle.swift
//  MyInventory
//
//  Maps SupplyStatus → visual treatment (color, symbol, label).
//  Never recomputes status — only consumes the existing enum.
//

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
            StatusStyle(color: Theme.statusOverdue,      symbol: "exclamationmark.circle.fill",   label: "Overdue")
        case .dueSoon:
            StatusStyle(color: Theme.statusDueSoon,      symbol: "clock.badge.exclamationmark",   label: "Due soon")
        case .ok:
            StatusStyle(color: Theme.statusOK,           symbol: "checkmark.circle.fill",         label: "OK")
        case .neverChecked:
            StatusStyle(color: Theme.statusNeverChecked, symbol: "questionmark.circle.fill",      label: "Needs first check")
        case .neverExpires:
            StatusStyle(color: Theme.statusNoExpiry,     symbol: "infinity",                      label: "No expiry")
        }
    }
}
