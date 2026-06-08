//
//  ContentView.swift
//  MyInventory
//
//  Root three-column NavigationSplitView (Dev Plan §6.5):
//   • Sidebar  — the three contexts (+ Settings)
//   • Content  — selected context's categories → items (overdue pinned)
//   • Detail   — the selected item
//
//  On iPhone / narrow multitasking this collapses to a single nav stack for free.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationManager.self) private var notifications

    @Query(sort: \SupplyContext.sortOrder) private var contexts: [SupplyContext]

    @State private var selectedContext: SupplyContext?
    @State private var selectedItem: SupplyItem?
    @State private var showingSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            content
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .task {
            SeedData.seedDefaultContextsIfNeeded(in: modelContext)
            if selectedContext == nil { selectedContext = contexts.first }
            await refreshNotifications()
        }
        .onChange(of: contexts) { _, newValue in
            if selectedContext == nil { selectedContext = newValue.first }
        }
        .onChange(of: selectedContext) { _, _ in
            selectedItem = nil   // item from another context no longer applies
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refreshNotifications() }
            }
        }
    }

    // MARK: Columns

    private var sidebar: some View {
        List(selection: $selectedContext) {
            Section("Supplies") {
                ForEach(contexts) { context in
                    ContextSidebarRow(context: context)
                        .tag(context)
                }
            }
        }
        .navigationTitle("MyInventory")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let selectedContext {
            ContextListView(context: selectedContext, selectedItem: $selectedItem)
                .id(selectedContext.persistentModelID)
        } else {
            ContentUnavailableView(
                "Select a context",
                systemImage: "square.grid.2x2",
                description: Text("Choose Vehicle, Bag, or House to see its supplies.")
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedItem {
            ItemDetailView(item: selectedItem, onDelete: { self.selectedItem = nil })
                .id(selectedItem.persistentModelID)
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "shippingbox",
                description: Text("Pick an item to see its details and check history.")
            )
        }
    }

    // MARK: Notifications

    private func refreshNotifications() async {
        await notifications.refreshAuthorizationStatus()
        let items = (try? modelContext.fetch(FetchDescriptor<SupplyItem>())) ?? []
        await notifications.reschedule(items: items,
                                       globalLeadTimeDays: settings.globalLeadTimeDays)
    }
}

// MARK: - Sidebar row

private struct ContextSidebarRow: View {
    let context: SupplyContext
    @Environment(SettingsStore.self) private var settings

    private var attentionCount: Int {
        context.allItems.filter {
            $0.status(leadTimeDays: settings.globalLeadTimeDays).isAttention
        }.count
    }

    var body: some View {
        HStack(spacing: Theme.spacing6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: SeedData.symbol(forContextNamed: context.name))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            Text(context.name)

            Spacer()

            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.statusOverdue, in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview("iPad Landscape", traits: .landscapeLeft) {
    ContentView()
        .modelContainer(for: [SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self],
                        inMemory: true)
        .environment(SettingsStore())
        .environment(NotificationManager())
}
