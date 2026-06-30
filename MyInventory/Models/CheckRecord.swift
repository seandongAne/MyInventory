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

    // Last-modified timestamp for cross-platform sync (Phase 2). Checks are
    // append-only, so this mainly future-proofs the schema alongside the others.
    var modifiedAt: Date = Date.now

    // Phase-2 soft-delete tombstone (nil = live). A non-nil value hides the row
    // from all queries/UI yet keeps it in the store + export so the deletion
    // propagates across devices instead of being silently re-added on merge.
    var deletedAt: Date? = nil

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

    /// Soft-delete this check (Phase-2 tombstone). Stamps `modifiedAt` so the
    /// deletion wins last-write-wins on merge.
    func markDeleted(now: Date = .now) {
        deletedAt = now
        modifiedAt = now
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

extension CheckResult {
    /// Canonical cross-platform wire value (see docs/SCBK1_Format.md §5). The
    /// stored `rawValue` ("OK"/"Replaced"/"Needs attention") is iOS-internal;
    /// backups use these lowercase values so Android (which uses them natively)
    /// round-trips with iOS.
    var wireValue: String {
        switch self {
        case .ok: return "ok"
        case .replaced: return "replaced"
        case .needsAttention: return "needsAttention"
        }
    }

    /// Decode a wire result, tolerating legacy iOS raw values ("OK"/"Replaced"/
    /// "Needs attention") from pre-S2 `.json` backups. Unknown → `.ok`.
    init(wireValue: String) {
        switch wireValue {
        case "ok", "OK": self = .ok
        case "replaced", "Replaced": self = .replaced
        case "needsAttention", "Needs attention": self = .needsAttention
        default: self = .ok
        }
    }
}
