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

    @Environment(\.scenePhase) private var scenePhase

    @State private var settings: SettingsStore
    @State private var notifications: NotificationManager
    /// The Part-C sync engine. C-0 backs it with the in-memory fake over the shared
    /// main context (so it exports/merges the same data the UI shows); C-1 swaps in
    /// `DriveTransport` + `SCBK1SyncCipher`. Nil only if the store failed to open.
    @State private var syncEngine: SyncEngine?

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
        var engine: SyncEngine?
        if let container {
            // Lets background notification actions ("Mark as Checked") reach the
            // store, and scheduling read the configured fire hour.
            notifications.configure(container: container, settings: settings)
            engine = SyncEngine.localPreview(modelContext: container.mainContext, settings: settings)
        }
        _settings = State(initialValue: settings)
        _notifications = State(initialValue: notifications)
        _syncEngine = State(initialValue: engine)
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                ContentView()
                    .environment(settings)
                    .environment(notifications)
                    .environment(syncEngine)
                    .tint(Theme.accent)
                    .modelContainer(container)
                    // Foreground trigger (design §7): re-opening the app pulls the other
                    // device's changes, throttled so quick app switches don't hammer sync.
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        Task { await syncEngine?.syncOnForegroundIfStale() }
                    }
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
