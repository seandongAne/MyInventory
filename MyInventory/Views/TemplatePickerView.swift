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
    @State private var appliedSummary: String?

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
        .alert("Template added", isPresented: Binding(
            get: { appliedSummary != nil },
            set: { if !$0 { appliedSummary = nil; dismiss() } }
        )) {
            Button("Done") { appliedSummary = nil; dismiss() }
        } message: {
            if let appliedSummary { Text(appliedSummary) }
        }
    }

    private func itemPreview(for template: SupplyTemplate) -> String {
        template.categories
            .flatMap { $0.items.map(\.name) }
            .joined(separator: ", ")
    }

    private func apply(_ template: SupplyTemplate) {
        do {
            let added = try Templates.apply(template, to: context, in: modelContext)
            appliedSummary = added == 0
                ? "Everything in this template already exists in \(context.name)."
                : "Added \(added) item\(added == 1 ? "" : "s") to \(context.name)."
        } catch {
            modelContext.rollback()
            applyError = error.localizedDescription
            return
        }
        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
    }
}
