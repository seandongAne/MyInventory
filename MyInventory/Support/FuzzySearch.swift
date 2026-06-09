//
//  FuzzySearch.swift
//  MyInventory
//
//  Lightweight, dependency-free fuzzy ranking (Dev Plan §4). SwiftData
//  #Predicate only does substring `contains`, so true typo tolerance is done
//  in memory over the (few-hundred-item) candidate set. Plenty fast per keystroke.
//

import Foundation

enum FuzzySearch {

    /// Filters & ranks items against a query across name / category / location.
    /// Returns best matches first. Empty query returns the input unchanged.
    static func rank(_ items: [SupplyItem], query rawQuery: String) -> [SupplyItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }

        let scored: [(item: SupplyItem, score: Double)] = items.compactMap { item in
            var fields = [
                item.name,
                item.category?.name ?? "",
                item.context?.name ?? "",
                item.storageLocation ?? ""
            ]
            // Check comments are searchable too ("replaced the AA batteries" should
            // surface the item even when its name doesn't match).
            fields.append(contentsOf: (item.checks ?? []).compactMap(\.comment))
            let best = fields
                .map { score(query: query, candidate: $0.lowercased()) }
                .max() ?? 0
            return best > 0 ? (item, best) : nil
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.item.name.localizedCaseInsensitiveCompare(rhs.item.name) == .orderedAscending
            }
            .map(\.item)
    }

    /// Score in 0...1. Substring hits score high; otherwise fall back to a
    /// token-level edit-distance similarity so small typos still match.
    static func score(query: String, candidate: String) -> Double {
        guard !candidate.isEmpty else { return 0 }
        if candidate == query { return 1.0 }
        if candidate.hasPrefix(query) { return 0.95 }
        if candidate.contains(query) { return 0.85 }

        // Token-by-token best similarity (handles "tuna" vs "canned tuna" typos).
        let tokens = candidate.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        var best = similarity(query, candidate)   // whole-string similarity baseline
        for token in tokens {
            best = max(best, similarity(query, token))
        }
        // Only treat reasonably-close matches as hits.
        return best >= 0.6 ? best * 0.8 : 0
    }

    /// 1 - normalized Levenshtein distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let distance = levenshtein(Array(a), Array(b))
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1 }
        return 1.0 - (Double(distance) / Double(maxLen))
    }

    /// Classic Levenshtein edit distance with two rolling rows.
    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
