//
//  AttentionListView.swift
//  MyInventory
//
//  Cross-context "Needs Attention" dashboard: every overdue / flagged /
//  never-checked item in one vertical grid, sorted most-urgent-first. This is
//  the "open the app and see what needs doing" view — items can be checked off
//  in place via the card's inline Check button, without a detour through detail.
//

import SwiftUI
import SwiftData

struct AttentionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    @Query(sort: \SupplyItem.name) private var allItems: [SupplyItem]

    @State private var editingItem: SupplyItem?
    @State private var itemPendingDeletion: SupplyItem?
    @State private var actionError: String?

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300), spacing: Theme.spacing6, alignment: .top)]
    }

    private var rows: [SupplyItem] {
        let lead = settings.globalLeadTimeDays
        return allItems
            .filter { $0.status(leadTimeDays: lead).isAttention }
            .sorted { a, b in
                let pa = a.status(leadTimeDays: lead).sortPriority
                let pb = b.status(leadTimeDays: lead).sortPriority
                if pa != pb { return pa < pb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("All caught up", image: "icon-status-ok")
                } description: {
                    Text("Nothing is overdue, flagged, or waiting on a first check.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.spacing6) {
                        header
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Theme.spacing6) {
                            ForEach(rows) { item in
                                itemCard(item)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.spacing8)
                    .padding(.top, Theme.spacing6)
                    .padding(.bottom, Theme.spacing16)
                }
                .scrollContentBackground(.hidden)
                .background(ScreenBackground())
            }
        }
        .sheet(item: $editingItem) { item in
            NavigationStack {
                ItemEditView(mode: .edit(item))
            }
        }
        .confirmationDialog(
            "Delete “\(itemPendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { if !$0 { itemPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = itemPendingDeletion {
                    itemPendingDeletion = nil
                    deleteItem(item)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the item and its full check history.")
        }
        .alert("Action failed", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            if let actionError { Text(actionError) }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.spacing4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NEEDS ATTENTION")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("Across all contexts")
                    .font(.largeTitle.weight(.bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(Theme.textPrimary)
            }
            Text("\(rows.count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.textSecondary.opacity(0.15), in: Capsule())
            Spacer()
        }
    }

    @ViewBuilder
    private func itemCard(_ item: SupplyItem) -> some View {
        ItemCard(
            item: item,
            status: item.status(leadTimeDays: settings.globalLeadTimeDays),
            breadcrumb: breadcrumb(for: item),
            onCheck: { quickCheck(item) },
            onEdit: { editingItem = item },
            onDelete: { itemPendingDeletion = item }
        )
        .contextMenu {
            Button {
                quickCheck(item)
            } label: {
                Label("Mark as Checked", systemImage: "checkmark.circle")
            }
            Button {
                editingItem = item
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                itemPendingDeletion = item
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func breadcrumb(for item: SupplyItem) -> String {
        let ctx = item.context?.name ?? "—"
        let cat = item.category?.name ?? SupplyCategory.uncategorizedName
        return "\(ctx) › \(cat)"
    }

    // MARK: Mutations

    private func quickCheck(_ item: SupplyItem) {
        let record = CheckRecord(date: .now, result: .ok)
        record.item = item
        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionError = error.localizedDescription
            return
        }
        Haptics.success()
        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
    }

    private func deleteItem(_ item: SupplyItem) {
        let uuid = item.uuid
        if editingItem?.persistentModelID == item.persistentModelID { editingItem = nil }
        modelContext.delete(item)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionError = error.localizedDescription
            return
        }
        notifications.cancelNotifications(forItemUUID: uuid)
        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
    }
}
