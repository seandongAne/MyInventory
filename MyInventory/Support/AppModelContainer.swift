//
//  AppModelContainer.swift
//  MyInventory
//
//  Single shared ModelContainer used by the app scene AND by App Intents
//  (Shortcuts/Siri run in-process and must hit the same store instance).
//  Mirrors the original MyInventoryApp behavior: one retry for transient
//  failures, then a surfaced error — never a silent in-memory fallback that
//  would lose writes.
//

import Foundation
import SwiftData

@MainActor
enum AppModelContainer {

    static let schema = Schema([
        SupplyContext.self,
        SupplyCategory.self,
        SupplyItem.self,
        CheckRecord.self
    ])

    /// `.failure` is a recoverable dead-end surfaced as StorageErrorView at launch.
    static let shared: Result<ModelContainer, Error> = {
        // UI tests launch with `-uiTesting` → throwaway in-memory store so each
        // run starts clean and never touches the user's real on-disk data.
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isUITesting
            // M6: add `, cloudKitDatabase: .automatic` here (and the iCloud
            // entitlement) once the schema is stable. Keep local-only until then.
        )
        do {
            return .success(try ModelContainer(for: schema, configurations: [configuration]))
        } catch {
            // Retry once for transient conditions, then surface a recoverable error
            // screen rather than crashing (P3-a).
            if let retry = try? ModelContainer(for: schema, configurations: [configuration]) {
                return .success(retry)
            }
            return .failure(error)
        }
    }()
}
