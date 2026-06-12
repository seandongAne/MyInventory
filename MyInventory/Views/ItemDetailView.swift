//
//  ItemDetailView.swift
//  MyInventory
//
//  Detail column: card sections, prominent "Check now" button, full check history.
//

import SwiftUI
import SwiftData
import UIKit

struct ItemDetailView: View {
    let item: SupplyItem
    var onDelete: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    @State private var showingCheckSheet = false
    @State private var showingEdit = false
    @State private var showingDeleteConfirm = false
    @State private var checkPendingDeletion: CheckRecord?
    @State private var actionError: String?

    private var status: SupplyStatus {
        item.status(leadTimeDays: settings.globalLeadTimeDays)
    }

    var body: some View {
        ZStack {
            ScreenBackground()
            ScrollView {
                VStack(spacing: Theme.spacing12) {
                    photoCard
                    statusCard
                    detailsCard
                    historyCard
                }
                .padding(.horizontal, Theme.spacing8)
                .padding(.top, Theme.spacing6)
                .padding(.bottom, Theme.spacing16)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(item.name.isEmpty ? "Item" : item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingEdit = true } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    moveToCategoryMenu
                    Divider()
                    Button(role: .destructive) { showingDeleteConfirm = true } label: {
                        Label("Delete Item", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingCheckSheet) {
            NavigationStack { CheckSheet(item: item) }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack { ItemEditView(mode: .edit(item)) }
        }
        .confirmationDialog("Delete this item?",
                            isPresented: $showingDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteItem() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the item and its full check history.")
        }
        .confirmationDialog("Delete this check?",
                            isPresented: Binding(
                                get: { checkPendingDeletion != nil },
                                set: { if !$0 { checkPendingDeletion = nil } }
                            ),
                            titleVisibility: .visible) {
            Button("Delete Check", role: .destructive) {
                if let check = checkPendingDeletion {
                    checkPendingDeletion = nil
                    deleteCheck(check)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removing a check can change this item's status and next due date.")
        }
        .alert("Action failed", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            if let msg = actionError { Text(msg) }
        }
    }

    /// Moving an item used to be reachable only from the list's long-press menu;
    /// the natural place to look is the item itself.
    @ViewBuilder
    private var moveToCategoryMenu: some View {
        let destinations = (item.context?.unwrappedCategories ?? []).filter {
            $0.persistentModelID != item.category?.persistentModelID
        }
        if !destinations.isEmpty {
            Menu {
                ForEach(destinations) { cat in
                    Button {
                        move(to: cat)
                    } label: {
                        Label(cat.name, systemImage: cat.isUncategorized ? "tray" : "folder")
                    }
                }
            } label: {
                Label("Move to Category", systemImage: "arrow.up.arrow.down")
            }
        }
    }

    // MARK: Cards

    @ViewBuilder
    private var photoCard: some View {
        if let data = item.photo, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                .elevation(.card)
        }
    }

    private var statusCard: some View {
        VStack(spacing: Theme.spacing8) {
            HStack {
                StatusBadge(status: status)
                Text(item.statusDetailLabel(globalLead: settings.globalLeadTimeDays))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }

            Button {
                showingCheckSheet = true
            } label: {
                Label("Check now", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PressableButtonStyle(tint: status.isAttention ? Theme.statusOverdue : Theme.accent))
        }
        .cardStyle()
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing6) {
            Text("Details")
                .font(.title3.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(Theme.textPrimary)

            Divider()

            detailRow("Context",  value: item.context?.name ?? "—")
            detailRow("Category", value: item.category?.name ?? "Uncategorized")
            if let quantity = item.quantity {
                detailRow("Quantity", value: "\(quantity)")
            }
            detailRow("Re-check interval", value: intervalText)
            if item.checkIntervalMonths != nil {
                detailRow("Next due", value: nextDueText)
                detailRow("Advance warning", value: leadText)
            }
            detailRow("Last checked", value: lastCheckedText)
            if item.hasLocation {
                detailRow("Location", value: item.storageLocation ?? "")
            }
        }
        .cardStyle()
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 120, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
            Spacer(minLength: 0)
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing6) {
            Label("Check history", systemImage: "clock.arrow.circlepath")
                .font(.title3.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(Theme.textPrimary)

            Divider()

            if item.unwrappedChecks.isEmpty {
                Text("No checks yet")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, Theme.spacing4)
            } else {
                VStack(spacing: Theme.spacing4) {
                    ForEach(item.unwrappedChecks) { check in
                        CheckHistoryCard(check: check)
                            // A mistaken check silently pushes the due date out a
                            // full interval — it must be correctable.
                            .contextMenu {
                                Button(role: .destructive) {
                                    checkPendingDeletion = check
                                } label: {
                                    Label("Delete Check", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: Derived text

    private var intervalText: String {
        guard let months = item.checkIntervalMonths else { return "Never expires" }
        if months % 12 == 0 {
            let years = months / 12
            return "Every \(years) year\(years == 1 ? "" : "s")"
        }
        return "Every \(months) month\(months == 1 ? "" : "s")"
    }

    private var nextDueText: String {
        guard let due = item.nextDueDate() else { return "After first check" }
        return due.formatted(date: .abbreviated, time: .omitted)
    }

    private var leadText: String {
        let days = item.effectiveLeadTimeDays(globalLead: settings.globalLeadTimeDays)
        let suffix = item.leadTimeDaysOverride == nil ? " (default)" : ""
        return "\(days) day\(days == 1 ? "" : "s") early\(suffix)"
    }

    private var lastCheckedText: String {
        guard let last = item.lastCheck else { return "Never" }
        return last.date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Actions

    private func deleteItem() {
        let uuid = item.uuid   // capture before the object is invalidated
        modelContext.delete(item)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionError = error.localizedDescription
            return   // notifications untouched — item still exists with its reminders
        }
        // Only after the delete is durably saved do we cancel/reschedule (P2-a).
        notifications.cancelNotifications(forItemUUID: uuid)
        onDelete()
        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
    }

    private func deleteCheck(_ check: CheckRecord) {
        modelContext.delete(check)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionError = error.localizedDescription
            return
        }
        // lastCheck (and so status/due date) may have changed.
        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
    }

    private func move(to category: SupplyCategory) {
        item.category = category
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionError = error.localizedDescription
        }
    }
}

// MARK: - Check history card

struct CheckHistoryCard: View {
    let check: CheckRecord

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacing6) {
            // Status icon column
            Image(check.result.iconName)
                .iconSized(20)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: Theme.spacing2) {
                HStack {
                    Text(check.result.rawValue)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(check.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                if check.hasComment, let comment = check.comment {
                    Text(comment)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, Theme.spacing2)
    }

    private var iconColor: Color {
        switch check.result {
        case .ok:             Theme.statusOK
        case .replaced:       Theme.accent
        case .needsAttention: Theme.statusNeedsAttention
        }
    }
}

// MARK: - Preview

#Preview("Overdue item with history") {
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
    let item = SupplyItem(name: "First Aid Kit", checkIntervalMonths: 6, storageLocation: "Trunk")
    item.category = cat
    ctx.insert(item)
    let r1 = CheckRecord(date: Calendar.current.date(byAdding: .month, value: -7, to: .now)!, result: .ok, comment: "All items present and in date.")
    r1.item = item; ctx.insert(r1)
    let r2 = CheckRecord(date: Calendar.current.date(byAdding: .month, value: -13, to: .now)!, result: .replaced, comment: "Replaced bandages and antiseptic.")
    r2.item = item; ctx.insert(r2)
    try? ctx.save()

    return NavigationStack {
        ItemDetailView(item: item)
    }
    .modelContainer(container)
    .environment(SettingsStore())
    .environment(NotificationManager())
}
