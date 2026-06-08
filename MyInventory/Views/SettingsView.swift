//
//  SettingsView.swift
//  MyInventory
//
//  Single-user settings (Dev Plan §3): lead time, default interval, notification
//  authorization, and a read-only sync status. CloudKit sync is deferred to M6,
//  so sync currently reads "Local only".
//

import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    // Remembers the last non-zero interval so toggling off then on restores it (M2).
    @State private var lastIntervalMonths: Int = 12

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Stepper(value: $settings.globalLeadTimeDays, in: 0...90) {
                    LabeledContent("Advance warning",
                                   value: "\(settings.globalLeadTimeDays) day\(settings.globalLeadTimeDays == 1 ? "" : "s")")
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("How many days before an item's due date it counts as “due soon” and triggers an early reminder. Items can override this individually.")
            }

            Section {
                Toggle("Default interval for new items", isOn: defaultIntervalEnabled)
                if settings.defaultIntervalMonths > 0 {
                    Stepper(value: defaultIntervalMonths, in: 1...240) {
                        LabeledContent("Every", value: monthsText(settings.defaultIntervalMonths))
                    }
                }
            } header: {
                Text("New item defaults")
            } footer: {
                Text("Pre-fills the re-check interval when you add an item. You can still change or clear it per item.")
            }

            Section {
                LabeledContent("Permission", value: authStatusText)
                if notifications.authorizationStatus == .notDetermined {
                    Button("Enable Notifications") { enableNotifications() }
                } else if notifications.authorizationStatus == .denied {
                    Text("Notifications are turned off. Enable them for MyInventory in the Settings app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if notifications.lastSchedulingFailureCount > 0 {
                    let n = notifications.lastSchedulingFailureCount
                    Label("\(n) reminder\(n == 1 ? "" : "s") couldn't be scheduled.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Try Again") { rescheduleNotifications() }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Reminders fire on the due date and, if set, a few days early. Never-expires items are never notified.")
            }

            Section {
                LabeledContent("iCloud sync", value: "Local only")
            } header: {
                Text("Sync")
            } footer: {
                Text("Your data is stored privately on this device. Cross-device iCloud sync is planned for a later version.")
            }

            Section("About") {
                LabeledContent("App", value: "MyInventory")
                LabeledContent("Version", value: appVersion)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            await notifications.refreshAuthorizationStatus()
            if settings.defaultIntervalMonths > 0 {
                lastIntervalMonths = settings.defaultIntervalMonths
            }
        }
        .onChange(of: settings.globalLeadTimeDays) { _, _ in
            rescheduleNotifications()
        }
    }

    // MARK: Bindings / derived

    private var defaultIntervalEnabled: Binding<Bool> {
        Binding(
            get: { settings.defaultIntervalMonths > 0 },
            set: { enabled in
                if enabled {
                    settings.defaultIntervalMonths = lastIntervalMonths
                } else {
                    lastIntervalMonths = settings.defaultIntervalMonths
                    settings.defaultIntervalMonths = 0
                }
            }
        )
    }

    private var defaultIntervalMonths: Binding<Int> {
        Binding(
            get: { settings.defaultIntervalMonths },
            set: { settings.defaultIntervalMonths = $0 }
        )
    }

    private func monthsText(_ months: Int) -> String {
        if months % 12 == 0 {
            let years = months / 12
            return "\(years) year\(years == 1 ? "" : "s")"
        }
        return "\(months) month\(months == 1 ? "" : "s")"
    }

    private var authStatusText: String {
        switch notifications.authorizationStatus {
        case .authorized: return "Allowed"
        case .provisional: return "Allowed (quiet)"
        case .denied: return "Off"
        case .notDetermined: return "Not set"
        case .ephemeral: return "Temporary"
        @unknown default: return "Unknown"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: Actions

    private func enableNotifications() {
        settings.notificationsRequested = true
        Task {
            _ = await notifications.requestAuthorization()
            notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
        }
    }

    private func rescheduleNotifications() {
        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .modelContainer(for: [SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self],
                        inMemory: true)
        .environment(SettingsStore())
        .environment(NotificationManager())
}
