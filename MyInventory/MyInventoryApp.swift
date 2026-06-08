//
//  MyInventoryApp.swift
//  MyInventory
//
//  App entry point. SwiftData is configured LOCAL-ONLY for now — CloudKit sync
//  is deliberately deferred to M6 so the schema can keep changing freely
//  (Dev Plan §M0, §9 risk table). Flip `cloudKitDatabase` on at M6.
//

import SwiftUI
import SwiftData

@main
struct MyInventoryApp: App {

    @State private var settings = SettingsStore()
    @State private var notifications = NotificationManager()

    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SupplyContext.self,
            SupplyCategory.self,
            SupplyItem.self,
            CheckRecord.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
            // M6: add `, cloudKitDatabase: .automatic` here (and the iCloud entitlement)
            // once the schema is stable. Keep local-only until then.
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(notifications)
                .tint(Theme.accent)
        }
        .modelContainer(sharedModelContainer)
    }
}
