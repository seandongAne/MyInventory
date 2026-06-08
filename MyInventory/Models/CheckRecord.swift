//
//  CheckRecord.swift
//  MyInventory
//
//  One historical "check" event. A check is an event, NOT a boolean flag
//  (PRD §7.2). Item status is derived from the most recent record.
//

import Foundation
import SwiftData

@Model
final class CheckRecord {
    var date: Date = Date.now

    // Enum persisted as a String for CloudKit safety (Dev Plan §2).
    var resultRaw: String = CheckResult.ok.rawValue

    // Optional free text; may be entered by voice dictation.
    var comment: String? = nil

    var uuid: UUID = UUID()

    // Inverse of SupplyItem.checks.
    var item: SupplyItem?

    init(date: Date = .now, result: CheckResult = .ok, comment: String? = nil) {
        self.date = date
        self.resultRaw = result.rawValue
        self.comment = comment
        self.uuid = UUID()
    }

    var result: CheckResult {
        get { CheckResult(rawValue: resultRaw) ?? .ok }
        set { resultRaw = newValue.rawValue }
    }

    var hasComment: Bool {
        guard let comment else { return false }
        return !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The outcome of a check. Persisted via `CheckRecord.resultRaw`.
enum CheckResult: String, CaseIterable, Identifiable {
    case ok = "OK"
    case replaced = "Replaced"
    case needsAttention = "Needs attention"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .ok: return "checkmark.circle"
        case .replaced: return "arrow.triangle.2.circlepath"
        case .needsAttention: return "exclamationmark.triangle"
        }
    }
}
