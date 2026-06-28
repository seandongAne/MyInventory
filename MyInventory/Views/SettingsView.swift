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
    /// Replays the first-run welcome guide. Defaults to a no-op so previews and
    /// any other call sites compile unchanged.
    var onReplayGuide: () -> Void = {}

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

    // Restore — read a previously exported JSON backup back in. The merge is
    // idempotent and never overwrites/deletes, so no destructive confirmation is
    // needed; a summary alert reports what was added.
    @State private var showingImporter = false
    @State private var restoreSummary: String?
    @State private var importError: String?

    // Encrypted backup (SCBK1) — the cross-platform, end-to-end-encrypted `.scbk`
    // file. Export runs through a passphrase + one-time recovery-key sheet; import
    // picks a `.scbk`, parses the envelope, then unlocks it in `pendingRestore`.
    @State private var showingEncryptedExport = false
    @State private var showingEncryptedImporter = false
    @State private var pendingRestore: PendingRestore?

    private var settingsSections: some View {
        @Bindable var settings = settings
        return Group {
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
                Button {
                    showingEncryptedExport = true
                } label: {
                    Label("Create Encrypted Backup…", systemImage: "lock.doc")
                }
                Button {
                    showingEncryptedImporter = true
                } label: {
                    Label("Restore Encrypted Backup…", systemImage: "lock.open")
                }
            } header: {
                Text("Encrypted Backup")
            } footer: {
                Text("Creates an encrypted .scbk file you can keep in any cloud drive and restore on your other device — it works across iPad and Android. Only your passphrase or recovery key can open it; the cloud never sees your data. Restoring adds anything missing and never overwrites or deletes what's already here.")
            }

            Section {
                LabeledContent("iCloud sync", value: "Local only")
                if let backupURL {
                    ShareLink(item: backupURL,
                              preview: SharePreview(backupURL.lastPathComponent,
                                                    image: Image(systemName: "doc.text"))) {
                        Label("Export Unencrypted Copy…", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("Preparing backup…", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
                Button {
                    showingImporter = true
                } label: {
                    Label("Restore Unencrypted Copy…", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Sync & Plain Export")
            } footer: {
                Text("Your data is stored privately on this device; iCloud sync is planned for a later version. This plain JSON copy is NOT encrypted — anyone who opens the file can read it, so keep it private. It includes every context, item, and check (photos aren't included). Prefer the encrypted backup above for anything you put in the cloud.")
            }

            Section {
                Button {
                    onReplayGuide()
                } label: {
                    Label("Show the Welcome Guide", systemImage: "questionmark.circle")
                }
            } header: {
                Text("Help")
            } footer: {
                Text("Replay the short intro that explains Needs Attention, adding supplies, and checking items off.")
            }

            Section("About") {
                LabeledContent("App", value: "MyInventory")
                LabeledContent("Version", value: appVersion)
            }
        }
    }

    var body: some View {
        Form { settingsSections }
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
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.json]) { result in
                restore(from: result)
            }
            .alert("Backup restored", isPresented: Binding(
                get: { restoreSummary != nil },
                set: { if !$0 { restoreSummary = nil } }
            )) {
                Button("OK", role: .cancel) { restoreSummary = nil }
            } message: {
                if let restoreSummary { Text(restoreSummary) }
            }
            .alert("Restore failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                if let importError { Text(importError) }
            }
            .sheet(isPresented: $showingEncryptedExport) {
                EncryptedBackupSheet(makePlaintext: {
                    String(decoding: try DataExporter.makeExport(from: modelContext), as: UTF8.self)
                })
            }
            .sheet(item: $pendingRestore) { pending in
                EncryptedRestoreSheet(envelope: pending.envelope, onDecrypted: mergeDecrypted)
            }
            .fileImporter(isPresented: $showingEncryptedImporter,
                          allowedContentTypes: [Self.scbkContentType]) { result in
                handlePickedEncryptedBackup(result)
            }
    }

    /// `.scbk` content type, resolved from the filename extension. SCBK1 files
    /// aren't a registered system type, so this dynamic type lets the picker show
    /// them without declaring an exported UTType in the (generated) Info.plist.
    private static let scbkContentType: UTType = UTType(filenameExtension: "scbk") ?? .data

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

    /// Reads a user-picked JSON backup and merges it into the store. The merge is
    /// non-destructive (adds only), so it's safe to run without a wipe warning.
    private func restore(from result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            // Files picked outside the app's sandbox come security-scoped.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let export = try DataImporter.decode(data)
                let summary = try DataImporter.merge(export, into: modelContext)
                restoreSummary = restoreMessage(for: summary)
                // New items may be due — refresh reminders + the freshly-exportable backup.
                rescheduleNotifications()
                prepareBackup()
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    /// Reads a user-picked `.scbk`, parses the envelope, and (on success) hands it
    /// to the unlock sheet. Decryption itself happens there; here we only validate
    /// the file is a backup so a wrong pick fails fast with a clear message.
    private func handlePickedEncryptedBackup(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let envelope = try BackupCrypto.parseEnvelope(data)
                pendingRestore = PendingRestore(envelope: envelope)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    /// Merges decrypted backup JSON (from the unlock sheet) into the store — same
    /// non-destructive additive merge as the plain restore, then refresh reminders
    /// and the exportable copy.
    private func mergeDecrypted(_ plaintext: String) {
        do {
            let export = try DataImporter.decode(Data(plaintext.utf8))
            let summary = try DataImporter.merge(export, into: modelContext)
            restoreSummary = restoreMessage(for: summary)
            rescheduleNotifications()
            prepareBackup()
            Haptics.success()
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Human-readable summary of a restore. Built in steps (no nested ternaries in
    /// one interpolation) so the type-checker stays fast.
    private func restoreMessage(for summary: DataImporter.Summary) -> String {
        guard !summary.isEmpty else {
            return "Everything in this backup is already here — nothing to add."
        }
        func phrase(_ count: Int, _ noun: String) -> String {
            "\(count) \(noun)\(count == 1 ? "" : "s")"
        }
        return "Added \(phrase(summary.contextsAdded, "place")), "
            + "\(phrase(summary.itemsAdded, "item")), and "
            + "\(phrase(summary.checksAdded, "check"))."
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .modelContainer(for: [SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self],
                        inMemory: true)
        .environment(SettingsStore())
        .environment(NotificationManager())
}
