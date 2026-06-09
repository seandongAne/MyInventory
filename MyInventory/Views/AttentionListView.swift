//
//  AttentionListView.swift
//  MyInventory
//
//  Cross-context "Needs Attention" dashboard: every overdue / flagged /
//  never-checked item in one list, sorted most-urgent-first. This is the
//  "open the app and see what needs doing" view — so items can be checked
//  off right here (swipe / long-press), without a detour through detail.
//

import SwiftUI
import SwiftData

struct AttentionListView: View {
    @Binding var selectedItem: SupplyItem?

    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    @Query(sort: \SupplyItem.name) private var allItems: [SupplyItem]

    @State private var itemPendingDeletion: SupplyItem?
    @State private var actionError: String?

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
                    Label("All caught up", systemImage: "checkmark.seal.fill")
                } description: {
                    Text("Nothing is overdue, flagged, or waiting on a first check.")
                }
            } else {
                List(selection: $selectedItem) {
                    Section {
                        ForEach(rows) { item in
                            itemRow(item)
                        }
                    } header: {
                        HStack(spacing: Theme.spacing4) {
                            Text("Across all contexts")
                                .font(.title3.weight(.semibold))
                                .fontDesign(.rounded)
                                .foregroundStyle(Theme.textPrimary)
                            Text("\(rows.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.textSecondary.opacity(0.15), in: Capsule())
                            Spacer()
                        }
                        .textCase(nil)
                        .padding(.vertical, Theme.spacing2)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(ScreenBackground())
            }
        }
        .navigationTitle("Needs Attention")
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

    @ViewBuilder
    private func itemRow(_ item: SupplyItem) -> some View {
        let lead = settings.globalLeadTimeDays
        let isSelected = selectedItem?.persistentModelID == item.persistentModelID
        ItemCard(
            item: item,
            status: item.status(leadTimeDays: lead),
            nextDueText: item.statusDetailLabel(globalLead: lead),
            breadcrumb: breadcrumb(for: item)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        )
        .tag(item)
        .listRowInsets(EdgeInsets(top: Theme.spacing2, leading: Theme.spacing8,
                                  bottom: Theme.spacing2, trailing: Theme.spacing8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // The whole point of this list is working through it — checking off an
        // item is one swipe, same as in the context lists.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                quickCheck(item)
            } label: {
                Label("Checked", systemImage: "checkmark.circle.fill")
            }
            .tint(Theme.statusOK)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                itemPendingDeletion = item
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                quickCheck(item)
            } label: {
                Label("Mark as Checked", systemImage: "checkmark.circle")
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
        let wasSelected = selectedItem?.persistentModelID == item.persistentModelID
        modelContext.delete(item)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            actionError = error.localizedDescription
            return
        }
        if wasSelected { selectedItem = nil }
        notifications.cancelNotifications(forItemUUID: uuid)
        notifications.rescheduleAll(in: modelContext, globalLeadTimeDays: settings.globalLeadTimeDays)
    }
}
