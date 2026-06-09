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
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    // Remembers the last non-zero interval so toggling off then on restores it (M2).
    @State private var lastIntervalMonths: Int = 12

    // Export
    @State private var exportDocument: JSONExportDocument?
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Stepper(value: $settings.globalLeadTimeDays, in: 0...90) {
                    LabeledContent("Advance warning",
                                   value: "\(settings.globalLeadTimeDays) day\(settings.globalLeadTimeDays == 1 ? "" : "s")")
                }
                Picker("Reminder time", selection: $settings.notificationFireHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hourLabel(hour)).tag(hour)
                    }
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("How many days before an item's due date it counts as “due soon” and triggers an early reminder, and the time of day reminders arrive. Items can override the warning individually.")
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
                Button {
                    exportData()
                } label: {
                    Label("Export All Data…", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Sync & Backup")
            } footer: {
                Text("Your data is stored privately on this device; iCloud sync is planned for a later version. Export saves a JSON backup of every context, item, and check (photos aren't included).")
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
        .onChange(of: settings.notificationFireHour) { _, _ in
            rescheduleNotifications()   // re-add every pending request at the new hour
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: DataExporter.defaultFilename()
        ) { result in
            if case .failure(let error) = result {
                exportError = error.localizedDescription
            }
        }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            if let exportError { Text(exportError) }
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

    /// "9:00 AM" / "21:00" matching the user's locale.
    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour)) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
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

    private func exportData() {
        do {
            exportDocument = JSONExportDocument(data: try DataExporter.makeExport(from: modelContext))
            isExporting = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .modelContainer(for: [SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self],
                        inMemory: true)
        .environment(SettingsStore())
        .environment(NotificationManager())
}
