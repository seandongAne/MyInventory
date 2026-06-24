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

    // Export — a JSON backup written to a temp file and offered through the system
    // share sheet (Mail / Save to Files / cloud drives / AirDrop), so it can leave
    // the iPad to a computer in one tap. Photos are not included.
    @State private var backupURL: URL?
    @State private var exportError: String?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                PresetValuePicker("Advance warning", value: $settings.globalLeadTimeDays,
                                  presets: [0, 1, 3, 7, 14, 30], range: 0...90,
                                  format: daysLabel)
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
                    PresetValuePicker("Every", value: defaultIntervalMonths,
                                      presets: [1, 3, 6, 12, 24], range: 1...240,
                                      format: monthsText)
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
                if let backupURL {
                    ShareLink(item: backupURL,
                              preview: SharePreview(backupURL.lastPathComponent,
                                                    image: Image(systemName: "doc.text"))) {
                        Label("Export All Data…", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("Preparing backup…", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Sync & Backup")
            } footer: {
                Text("Your data is stored privately on this device; iCloud sync is planned for a later version. Export shares a JSON backup of every context, item, and check (photos aren't included) — email it to yourself, save it to Files, or send it to a computer.")
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
            prepareBackup()
        }
        .onChange(of: settings.globalLeadTimeDays) { _, _ in
            rescheduleNotifications()
        }
        .onChange(of: settings.notificationFireHour) { _, _ in
            rescheduleNotifications()   // re-add every pending request at the new hour
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

    private func daysLabel(_ days: Int) -> String {
        days == 0 ? "None" : "\(days) day\(days == 1 ? "" : "s")"
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

    /// Writes the JSON backup to a temp file so the system share sheet can offer it
    /// as a real file — emailed as an attachment, saved to Files, dropped into a
    /// cloud drive, or AirDropped. Regenerated each time Settings opens.
    private func prepareBackup() {
        do {
            let data = try DataExporter.makeExport(from: modelContext)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(DataExporter.defaultFilename())
                .appendingPathExtension("json")
            try data.write(to: url, options: .atomic)
            backupURL = url
            exportError = nil
        } catch {
            backupURL = nil
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
