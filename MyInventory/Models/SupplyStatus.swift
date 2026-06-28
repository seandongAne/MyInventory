//
//  SupplyStatus.swift
//  MyInventory
//
//  Derived status (NEVER stored) + its single source-of-truth UI mapping
//  (color + SF Symbol + label), per Dev Plan §2.1 and §6.4.
//

import Foundation

enum SupplyStatus: Hashable {
    case neverExpires
    case neverChecked
    case ok
    case dueSoon
    case needsAttention   // last check was flagged "Needs attention" (and item isn't overdue)
    case overdue
}

extension SupplyItem {

    /// nextDue = lastCheck.date + interval. nil if never-expires OR never-checked.
    func nextDueDate(calendar: Calendar = .current) -> Date? {
        guard let value = intervalValue else { return nil }          // never expires
        guard let last = lastCheck?.date else { return nil }         // never checked
        return calendar.date(byAdding: intervalUnitValue.calendarComponent, value: value, to: last)
    }

    /// The effective lead time (per-item override, else the global default).
    func effectiveLeadTimeDays(globalLead: Int) -> Int {
        leadTimeDaysOverride ?? globalLead
    }

    func status(leadTimeDays globalLead: Int,
                now: Date = .now,
                calendar: Calendar = .current) -> SupplyStatus {
        let lastResult = lastCheck?.result

        // 1) Time-based overdue always wins — a stale item needs a re-check regardless
        //    of what the last check said. (Decision: Overdue > needsAttention.)
        if let due = nextDueDate(calendar: calendar), now >= due {
            return .overdue
        }
        // 2) Explicit human flag from the most recent check pins the item above
        //    due-soon/OK — and even surfaces on never-expires items (P1-a: the
        //    recorded result must not be silently ignored).
        if lastResult == .needsAttention {
            return .needsAttention
        }
        // 3) No interval => never expires.
        guard intervalValue != nil else { return .neverExpires }
        // 4) Interval but never checked => due immediately (PRD Q1 default).
        guard let due = nextDueDate(calendar: calendar) else { return .neverChecked }
        // 5) Inside the lead-time window => due soon.
        let lead = effectiveLeadTimeDays(globalLead: globalLead)
        if let warnDate = calendar.date(byAdding: .day, value: -lead, to: due), now >= warnDate {
            return .dueSoon
        }
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
        case .needsAttention:
            return "Flagged at last check"
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
    /// Sort weight so overdue/attention/never-checked float to the top of any list.
    var sortPriority: Int {
        switch self {
        case .overdue: return 0
        case .needsAttention: return 1
        case .neverChecked: return 2
        case .dueSoon: return 3
        case .ok: return 4
        case .neverExpires: return 5
        }
    }

    // Visual mapping (color / symbol / label) lives in one place only:
    // `SupplyStatus.style` (DesignSystem/SupplyStatusStyle.swift). Don't reintroduce
    // a parallel palette here.

    /// Whether overdue/attention/never-checked rows get the highlighted treatment.
    var isAttention: Bool {
        self == .overdue || self == .needsAttention || self == .neverChecked
    }
}
