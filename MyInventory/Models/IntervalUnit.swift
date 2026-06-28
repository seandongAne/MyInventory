//
//  IntervalUnit.swift
//  MyInventory
//
//  The unit of a re-check interval. Shared concept with the Android app's
//  canonical sync schema — the raw values ("days"/"months"/"years") MUST match
//  across platforms, so don't rename them without updating the Android side.
//

import Foundation

enum IntervalUnit: String, CaseIterable, Identifiable {
    case days
    case months
    case years

    var id: String { rawValue }

    /// Singular noun ("day" / "month" / "year").
    var singularNoun: String {
        switch self {
        case .days: return "day"
        case .months: return "month"
        case .years: return "year"
        }
    }

    /// Correctly pluralized noun for a count ("1 month", "6 months").
    func noun(for value: Int) -> String {
        value == 1 ? singularNoun : singularNoun + "s"
    }

    /// Compact form for tight list rows ("d" / "mo" / "yr").
    var abbreviation: String {
        switch self {
        case .days: return "d"
        case .months: return "mo"
        case .years: return "yr"
        }
    }

    /// Title-cased label for pickers ("Days" / "Months" / "Years").
    var displayName: String {
        switch self {
        case .days: return "Days"
        case .months: return "Months"
        case .years: return "Years"
        }
    }

    /// The matching `Calendar` component for due-date math. `Calendar.date(byAdding:)`
    /// clamps overflow days (Jan 31 + 1 month -> Feb 28/29, Feb 29 + 1 year -> Feb 28),
    /// which matches the Android `addInterval` clamping — keeping due dates identical.
    var calendarComponent: Calendar.Component {
        switch self {
        case .days: return .day
        case .months: return .month
        case .years: return .year
        }
    }
}
