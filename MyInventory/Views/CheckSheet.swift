//
//  CheckSheet.swift
//  MyInventory
//
//  Log a check (P0-3, P0-4). Creates a CheckRecord and reschedules the item's
//  notifications off the new last-check date. The comment field supports
//  on-device keyboard dictation (the mic key) — offline, no permissions,
//  saved straight onto the record.
//

import SwiftUI
import SwiftData

struct CheckSheet: View {
    let item: SupplyItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    @State private var date = Date.now
    @State private var result: CheckResult = .ok
    @State private var comment = ""
    @State private var quantity: Int
    @FocusState private var commentFocused: Bool
    @State private var saveError: String?

    init(item: SupplyItem) {
        self.item = item
        _quantity = State(initialValue: item.quantity ?? 0)
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
            } header: {
                Text("When")
            } footer: {
                // Warn when the backdated check won't move the due date (F6).
                if let latest = item.lastCheck?.date, date < latest {
                    Label("Earlier than the most recent check — the due date won't change.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            Section("Result") {
                Picker("Result", selection: $result) {
                    ForEach(CheckResult.allCases) { result in
                        Label {
                            Text(result.rawValue)
                        } icon: {
                            Image(result.iconName).iconSized(20)
                        }
                        .tag(result)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if item.quantity != nil {
                Section {
                    Stepper(value: $quantity, in: 0...9999) {
                        LabeledContent("On hand", value: "\(quantity)")
                            .monospacedDigit()
                    }
                } header: {
                    Text("Quantity")
                } footer: {
                    Text("Update the count while you're at it (e.g. you used two and restocked one).")
                }
            }

            Section {
                TextField("Add a note…", text: $comment, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($commentFocused)
            } header: {
                Text("Comment (optional)")
            } footer: {
                Label("Tap the mic key on the keyboard to dictate hands-free.",
                      systemImage: "mic.fill")
            }
        }
        .navigationTitle("Check \(item.name.isEmpty ? "Item" : item.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .alert("Could not save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            if let msg = saveError { Text(msg) }
        }
    }

    private func save() {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = CheckRecord(date: date,
                                 result: result,
                                 comment: trimmed.isEmpty ? nil : trimmed)
        record.item = item
        modelContext.insert(record)
        if item.quantity != nil {
            item.quantity = quantity   // same save; rolled back together on failure
        }
        do {
            try modelContext.save()
        } catch {
            // Roll back the pending insert so a retry doesn't create a duplicate (B2).
            modelContext.rollback()
            saveError = error.localizedDescription
            return
        }

        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
        Haptics.success()
        dismiss()
    }
}

// MARK: - Preview

#Preview("CheckSheet – backdate warning") {
    let container = try! ModelContainer(
        for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let ctx = container.mainContext
    let supplyCtx = SupplyContext(name: "Vehicle", sortOrder: 0)
    ctx.insert(supplyCtx)
    let cat = SupplyCategory(name: "Emergency Kit", sortOrder: 0)
    cat.context = supplyCtx
    ctx.insert(cat)
    let item = SupplyItem(name: "First Aid Kit", checkIntervalMonths: 6)
    item.category = cat
    ctx.insert(item)
    // Recent check so the backdate warning will fire
    let recentCheck = CheckRecord(date: .now, result: .ok)
    recentCheck.item = item
    ctx.insert(recentCheck)
    try? ctx.save()

    return NavigationStack {
        CheckSheet(item: item)
    }
    .modelContainer(container)
    .environment(SettingsStore())
    .environment(NotificationManager())
}
