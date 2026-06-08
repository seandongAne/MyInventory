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

    private let container: ModelContainer?
    private let containerErrorMessage: String?

    init() {
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
            container = try ModelContainer(for: schema, configurations: [configuration])
            containerErrorMessage = nil
        } catch {
            // Retry once for transient conditions, then surface a recoverable error
            // screen rather than crashing (P3-a). We deliberately do NOT fall back to
            // an in-memory store — that would look fine while silently losing every write.
            if let retry = try? ModelContainer(for: schema, configurations: [configuration]) {
                container = retry
                containerErrorMessage = nil
            } else {
                container = nil
                containerErrorMessage = error.localizedDescription
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                ContentView()
                    .environment(settings)
                    .environment(notifications)
                    .tint(Theme.accent)
                    .modelContainer(container)
            } else {
                StorageErrorView(message: containerErrorMessage ?? "The data store could not be opened.")
                    .tint(Theme.accent)
            }
        }
    }
}

/// Shown when the persistent store can't be opened at launch — a recoverable
/// dead-end instead of a crash. Relaunching re-attempts container creation.
private struct StorageErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Storage unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("MyInventory couldn't open its local data store, so it can't run safely. Your saved data has not been deleted.\n\nTry restarting the app or your device, and make sure the device has free storage space.")
        } actions: {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
