//
//  AttentionListView.swift
//  MyInventory
//
//  Cross-context "Needs Attention" dashboard: every overdue / flagged /
//  never-checked item in one list, sorted most-urgent-first. This is the
//  "open the app and see what needs doing" view — the sidebar badge counts
//  point here.
//

import SwiftUI
import SwiftData

struct AttentionListView: View {
    @Binding var selectedItem: SupplyItem?

    @Environment(SettingsStore.self) private var settings

    @Query(sort: \SupplyItem.name) private var allItems: [SupplyItem]

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
    }

    private func breadcrumb(for item: SupplyItem) -> String {
        let ctx = item.context?.name ?? "—"
        let cat = item.category?.name ?? SupplyCategory.uncategorizedName
        return "\(ctx) › \(cat)"
    }
}
