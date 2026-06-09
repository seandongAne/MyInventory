//
//  MyInventoryApp.swift
//  MyInventory
//
//  App entry point. SwiftData is configured LOCAL-ONLY for now — CloudKit sync
//  is deliberately deferred to M6 so the schema can keep changing freely
//  (Dev Plan §M0, §9 risk table). Container creation/retry lives in
//  AppModelContainer so App Intents share the same instance.
//

import SwiftUI
import SwiftData

@main
struct MyInventoryApp: App {

    @State private var settings: SettingsStore
    @State private var notifications: NotificationManager

    private let container: ModelContainer?
    private let containerErrorMessage: String?

    init() {
        switch AppModelContainer.shared {
        case .success(let made):
            container = made
            containerErrorMessage = nil
        case .failure(let error):
            container = nil
            containerErrorMessage = error.localizedDescription
        }

        let settings = SettingsStore()
        let notifications = NotificationManager.shared
        if let container {
            // Lets background notification actions ("Mark as Checked") reach the
            // store, and scheduling read the configured fire hour.
            notifications.configure(container: container, settings: settings)
        }
        _settings = State(initialValue: settings)
        _notifications = State(initialValue: notifications)
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
