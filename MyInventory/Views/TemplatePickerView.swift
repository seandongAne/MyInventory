//
//  TemplatePickerView.swift
//  MyInventory
//
//  Lets the user populate a context from a ready-made checklist (Templates.swift).
//  Existing categories are reused by name; items that already exist are skipped,
//  so re-applying a template never duplicates anything.
//

import SwiftUI
import SwiftData

struct TemplatePickerView: View {
    let context: SupplyContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    @State private var applyError: String?
    @State private var nothingToAddMessage: String?

    var body: some View {
        List {
            ForEach(Templates.all) { template in
                Section {
                    VStack(alignment: .leading, spacing: Theme.spacing4) {
                        Text(template.summary)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Text(itemPreview(for: template))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                    }
                    Button {
                        apply(template)
                    } label: {
                        Label("Add \(template.itemCount) Items", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Label(template.name, systemImage: template.symbol)
                        .font(.headline)
                        .textCase(nil)
                }
            }
        }
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .alert("Couldn't apply template", isPresented: Binding(
            get: { applyError != nil },
            set: { if !$0 { applyError = nil } }
        )) {
            Button("OK", role: .cancel) { applyError = nil }
        } message: {
            if let applyError { Text(applyError) }
        }
        .alert("Nothing to add", isPresented: Binding(
            get: { nothingToAddMessage != nil },
            set: { if !$0 { nothingToAddMessage = nil } }
        )) {
            Button("OK", role: .cancel) { nothingToAddMessage = nil }
        } message: {
            if let nothingToAddMessage { Text(nothingToAddMessage) }
        }
    }

    private func itemPreview(for template: SupplyTemplate) -> String {
        template.categories
            .flatMap { $0.items.map(\.name) }
            .joined(separator: ", ")
    }

    private func apply(_ template: SupplyTemplate) {
        let added: Int
        do {
            added = try Templates.apply(template, to: context, in: modelContext)
        } catch {
            modelContext.rollback()
            applyError = error.localizedDescription
            return
        }
        guard added > 0 else {
            // Nothing visibly changes in this rare case, so it needs saying.
            nothingToAddMessage = "Everything in this template already exists in \(context.name)."
            return
        }
        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
        Haptics.success()
        // The added items appearing in the list behind IS the confirmation —
        // no extra "Done" tap.
        dismiss()
    }
}
