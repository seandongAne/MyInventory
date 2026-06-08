//
//  SupplyStatus.swift
//  MyInventory
//
//  Derived status (NEVER stored) + its single source-of-truth UI mapping
//  (color + SF Symbol + label), per Dev Plan §2.1 and §6.4.
//

import Foundation
import SwiftUI

enum SupplyStatus: Hashable {
    case neverExpires
    case neverChecked
    case ok
    case dueSoon
    case overdue
}

extension SupplyItem {

    /// nextDue = lastCheck.date + interval. nil if never-expires OR never-checked.
    func nextDueDate(calendar: Calendar = .current) -> Date? {
        guard let months = checkIntervalMonths else { return nil }   // never expires
        guard let last = lastCheck?.date else { return nil }         // never checked
        return calendar.date(byAdding: .month, value: months, to: last)
    }

    /// The effective lead time (per-item override, else the global default).
    func effectiveLeadTimeDays(globalLead: Int) -> Int {
        leadTimeDaysOverride ?? globalLead
    }

    func status(leadTimeDays globalLead: Int,
                now: Date = .now,
                calendar: Calendar = .current) -> SupplyStatus {
        guard checkIntervalMonths != nil else { return .neverExpires }
        guard lastCheck != nil, let due = nextDueDate(calendar: calendar) else {
            return .neverChecked   // PRD Q1 default: treat as due immediately
        }
        let lead = effectiveLeadTimeDays(globalLead: globalLead)
        guard let warnDate = calendar.date(byAdding: .day, value: -lead, to: due) else { return .ok }
        if now >= due { return .overdue }
        if now >= warnDate { return .dueSoon }
        return .ok
    }

    /// Whole-day difference between now and the next due date (negative = overdue by N).
    func daysUntilDue(now: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let due = nextDueDate(calendar: calendar) else { return nil }
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: due)
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    /// Human-readable status detail used on badges/rows
    /// (e.g. "Overdue by 3 days", "Due in 2 days", "Due 10 Sept 2026").
    func statusDetailLabel(globalLead: Int,
                           now: Date = .now,
                           calendar: Calendar = .current) -> String {
        switch status(leadTimeDays: globalLead, now: now, calendar: calendar) {
        case .neverExpires:
            return "No expiry"
        case .neverChecked:
            return "Needs first check"
        case .ok:
            if let due = nextDueDate(calendar: calendar) {
                return "Due " + due.formatted(date: .abbreviated, time: .omitted)
            }
            return "OK"
        case .dueSoon:
            if let d = daysUntilDue(now: now, calendar: calendar) {
                return d <= 0 ? "Due today" : "Due in \(d) day\(d == 1 ? "" : "s")"
            }
            return "Due soon"
        case .overdue:
            if let d = daysUntilDue(now: now, calendar: calendar) {
                let by = -d
                return by <= 0 ? "Due today" : "Overdue by \(by) day\(by == 1 ? "" : "s")"
            }
            return "Overdue"
        }
    }
}

extension SupplyStatus {
    /// Sort weight so overdue/never-checked float to the top of any list.
    var sortPriority: Int {
        switch self {
        case .overdue: return 0
        case .neverChecked: return 1
        case .dueSoon: return 2
        case .ok: return 3
        case .neverExpires: return 4
        }
    }

    var color: Color {
        switch self {
        case .overdue: return .red
        case .neverChecked: return .red
        case .dueSoon: return .orange
        case .ok: return .green
        case .neverExpires: return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .overdue: return "exclamationmark.circle.fill"
        case .neverChecked: return "questionmark.circle"
        case .dueSoon: return "clock.badge.exclamationmark"
        case .ok: return "checkmark.circle"
        case .neverExpires: return "infinity"
        }
    }

    /// Short label for badges (date-aware variants are built in StatusBadge).
    var shortLabel: String {
        switch self {
        case .overdue: return "Overdue"
        case .neverChecked: return "Needs first check"
        case .dueSoon: return "Due soon"
        case .ok: return "OK"
        case .neverExpires: return "No expiry"
        }
    }

    /// Whether overdue/needs-attention rows get the highlighted treatment.
    var isAttention: Bool {
        self == .overdue || self == .neverChecked
    }
}
